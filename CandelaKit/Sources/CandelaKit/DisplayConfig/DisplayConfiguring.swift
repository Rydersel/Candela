import CoreGraphics
import Foundation

/// How long an applied configuration should last.
///
/// `Equatable` is declared here rather than added by a test-side extension:
/// it is our own type in our own module, so a `@retroactive` conformance
/// would be both unnecessary and wrong.
public enum DisplayConfigScope: Sendable, Equatable {
  /// `kCGConfigureForAppOnly` — reverts when this process exits, including on
  /// a crash. The safe way to show someone a mode before committing to it.
  case preview
  /// `kCGConfigureForSession` — outlives the process, and is dropped at logout.
  case session
  /// `kCGConfigurePermanently` — written to the user's stored configuration, so
  /// it survives logout.
  ///
  /// Arrangement commits with this (drag-canvas §6.1): the layout is what macOS
  /// itself persists per display-set, and a session-scoped commit would be lost
  /// at logout and read as the feature not working.
  ///
  /// **A permanent change the macOS UI cannot represent silently degrades to
  /// session scope** (`CGDisplayConfiguration.h`), with no error — one more
  /// reason every apply re-reads what it achieved instead of trusting its own
  /// return code.
  case permanent
}

extension DisplayConfigScope {
  /// An exhaustive switch, and deliberately the ONLY place this mapping is
  /// written. It replaced a `scope == .preview ? .forAppOnly : .forSession`
  /// ternary at each of the three `CGCompleteDisplayConfiguration` call sites —
  /// which would have silently mapped `.permanent` to `.forSession`, losing the
  /// layout at logout while reporting success. A switch here makes the compiler
  /// demand a row for every future case at every call site at once.
  var configureOption: CGConfigureOption {
    switch self {
    case .preview: .forAppOnly
    case .session: .forSession
    case .permanent: .permanently
    }
  }
}

/// A display that can be reconfigured. Unlike `ExternalDisplay` this includes
/// the built-in panel and any virtual displays, because mode switching applies
/// to all of them.
public struct ConfiguredDisplay: Sendable, Equatable, Identifiable {
  public let id: CGDirectDisplayID
  public let identity: DisplayConfigIdentity
  public let name: String
  public let isBuiltIn: Bool
  /// The display whose content this one is SHOWING, or `kCGNullDirectDisplay`
  /// when it is showing its own — `CGDisplayMirrorsDisplay`, sampled at the same
  /// instant as the list itself so a caller cannot ask about a topology that has
  /// moved on.
  ///
  /// Carried because `displays()` enumerates ONLINE displays, and "online" means
  /// active, asleep, **or mirrored**: a hardware-mirrored secondary appears here
  /// while appearing in no active list at all. Reapply reads absence from this
  /// list as a departure, so it necessarily sees mirror slaves as arrivals too,
  /// and something has to be able to tell them apart.
  ///
  /// The MASTER of a mirror set reports null here and is a perfectly ordinary
  /// display: it owns the framebuffer everyone in the set is showing, and its
  /// resolution is the set's resolution.
  public let mirrorsDisplay: CGDirectDisplayID

  /// This display belongs to a mirror set — as MASTER or as slave. Sampled in
  /// the same `displays()` loop as everything else here, so it describes the
  /// same instant as the list.
  ///
  /// The DISJUNCTION of `CGDisplayIsInHWMirrorSet` and `CGDisplayIsInMirrorSet`.
  /// The header says the general call is the superset, so the hardware call is
  /// redundant on a conforming driver — but both shipped Candela paths already
  /// tested the disjunction, it costs one branch, and it survives a driver that
  /// reports one and not the other. Preserved deliberately, not incidentally.
  public let isInMirrorSet: Bool

  /// This display is in a mirror set it CANNOT be removed from
  /// (`CGDisplayIsAlwaysInMirrorSet`). Sidecar and AirPlay receivers are the
  /// suspects; which displays actually report it on macOS 26 is UNVERIFIED,
  /// which is exactly why it is a field and a policy row rather than a special
  /// case.
  ///
  /// The defect it closes: the transplanted `Mirroring.engageMirror` saw such a
  /// display as "in a mirror set", took the break branch, staged a change that
  /// could not succeed, discarded the return, and reported success — forever.
  public let isAlwaysInMirrorSet: Bool

  /// True for the SLAVE of a mirror set only. Its own mode decides almost
  /// nothing while the mirror lasts — the pixels on it come from the master —
  /// so it is not a display an unattended pass should be reconfiguring.
  public var isMirrorSlave: Bool { mirrorsDisplay != kCGNullDirectDisplay }

  /// The display that OWNS the framebuffer a mirror set is showing.
  ///
  /// Requires BOTH halves. `CGDisplayMirrorsDisplay` returns null for a master
  /// and for a standalone display alike, so it is not a membership test on its
  /// own — this is the exact predicate that was hand-written in
  /// `KeyActionExecutor` before this type carried it.
  public var isMirrorMaster: Bool {
    isInMirrorSet && mirrorsDisplay == kCGNullDirectDisplay
  }

  public init(
    id: CGDirectDisplayID,
    identity: DisplayConfigIdentity,
    name: String,
    isBuiltIn: Bool,
    mirrorsDisplay: CGDirectDisplayID = kCGNullDirectDisplay,
    isInMirrorSet: Bool = false,
    isAlwaysInMirrorSet: Bool = false
  ) {
    self.id = id
    self.identity = identity
    self.name = name
    self.isBuiltIn = isBuiltIn
    self.mirrorsDisplay = mirrorsDisplay
    // DERIVED here rather than trusted from the caller: a slave that claims not
    // to be in a mirror set is not a state any caller should have to defend
    // against, and the defaulted parameters make it constructible by accident
    // in every fixture that sets only `mirrorsDisplay`.
    self.isInMirrorSet = isInMirrorSet || mirrorsDisplay != kCGNullDirectDisplay
    self.isAlwaysInMirrorSet = isAlwaysInMirrorSet
  }
}

public struct DisplayConfigError: Error, Sendable, Equatable {
  public let cgErrorCode: Int32
  public init(cgErrorCode: Int32) { self.cgErrorCode = cgErrorCode }
}

/// Opens a display-configuration transaction, or throws.
///
/// A nil token after a `.success` begin would otherwise be reported as error
/// code 0 — an error that reads as "no error".
func beginDisplayConfiguration() throws -> CGDisplayConfigRef {
  var config: CGDisplayConfigRef?
  let begin = CGBeginDisplayConfiguration(&config)
  guard begin == .success, let config else {
    throw DisplayConfigError(
      cgErrorCode: begin == .success ? CGError.failure.rawValue : begin.rawValue
    )
  }
  return config
}

/// One staged mirror change. `master == kCGNullDirectDisplay` REMOVES `display`
/// from any mirror set it is in — the only removal path there is; the API has
/// no dissolve-the-set call.
///
/// A named struct rather than the tuple the research sketched, for one concrete
/// reason: the fake conformance has to record what it was asked for and a test
/// has to `#expect` it against an expected list, and a tuple array is not
/// `Equatable`.
public struct MirrorChange: Sendable, Equatable {
  public let display: CGDirectDisplayID
  public let master: CGDirectDisplayID

  public init(display: CGDirectDisplayID, master: CGDirectDisplayID) {
    self.display = display
    self.master = master
  }
}

/// The post-commit check `applyMirroring` owes its callers, factored out so the
/// real configurator and its test double are held to the same rule.
///
/// **`CGCompleteDisplayConfiguration` returning `.success` is not evidence the
/// request was honoured.** Measured on the mirroring hardware pass
/// (`docs/spikes/2026-08-04-mirroring-hardware-pass.md` §6.2), with every stage
/// AND the complete returning `.success` in both cases:
///
/// - a cyclic list `[166→167, 167→166]` achieved `166→167, 167→0`;
/// - a list naming one display twice, `[166→167, 166→168]`, applied the FIRST
///   change and silently discarded the second.
///
/// This is the same lesson `CoreGraphicsDisplayConfigurator.apply` already
/// carries for a display MODE, where the resolved mode's geometry is re-derived
/// and compared because `ioModeID` is positional. That check was written there
/// first; this type closed the same gap for mirroring.
enum MirrorVerification {
  /// The first requested change the achieved topology does not show, or nil
  /// when every one of them stands.
  ///
  /// `achievedParent` is `CGDisplayMirrorsDisplay` in production: the parent
  /// each named display ACTUALLY has, read after the commit.
  ///
  /// **Named displays only, deliberately.** CoreGraphics also re-parents
  /// displays a change list never mentions — building `167→166` and then asking
  /// the master `166` to mirror `168` silently moved `167` from `166` to `168`
  /// (§6.3) — but that collapse is CoreGraphics enforcing the
  /// one-master-N-slaves shape `MirrorTopology` already assumes, not a request
  /// being ignored. Catching it needs a whole-topology comparison and a ruling
  /// on what "achieved" means for a set. This closes the two measured
  /// divergences and claims nothing more.
  static func unhonoured(
    in changes: [MirrorChange],
    achievedParent: (CGDirectDisplayID) -> CGDirectDisplayID
  ) -> MirrorChange? {
    changes.first { achievedParent($0.display) != $0.master }
  }
}

/// The seam between display-configuration policy and CoreGraphics. Everything
/// decidable is tested against a fake conformance; the real one is a thin
/// adapter with no judgement in it.
public protocol DisplayConfiguring: Sendable {
  /// Every display that is ONLINE — connected and powered, whether or not it is
  /// currently drawing. Deliberately not "active": callers read absence from
  /// this list as a DEPARTURE, and a display asleep on the idle timer is
  /// inactive without having gone anywhere. See
  /// `CoreGraphicsDisplayConfigurator.displays()`.
  func displays() -> [ConfiguredDisplay]
  func modes(for displayID: CGDirectDisplayID) -> [DisplayMode]
  func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode?
  /// The panel's own pixel count, from the mode flagged native. Needed to tell
  /// scaled modes from native ones.
  func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)?
  func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws

  /// Stages one `CGConfigureDisplayMirrorOfDisplay` per change in a SINGLE
  /// transaction and commits it.
  ///
  /// A BATCH because there is no dissolve-the-set call: breaking a set means
  /// staging a null-master change for every slave and committing them together.
  /// A per-display method would make a half-broken set expressible, and a
  /// half-broken set is a state no policy wants to reason about.
  ///
  /// Throws `DisplayConfigError` if the transaction cannot be begun, if any
  /// change fails to STAGE, if the completion fails, or if the committed
  /// topology does not show what was asked for (`MirrorVerification`). An empty
  /// `changes` array does nothing and opens no transaction.
  ///
  /// **That last throw is the ONE that can follow a committed change**, and it
  /// is the only place in this protocol where a throw does not mean "nothing
  /// moved". CoreGraphics accepted the batch and did something else; the
  /// machine is in whatever topology it chose, and nothing here puts it back.
  /// Reporting the divergence is still the right answer — the alternative is
  /// what shipped, which was a caller recording the REQUESTED changes as
  /// applied and later committing them at session scope with `.committed`, so a
  /// topology CoreGraphics is known to ignore would outlive the process wearing
  /// a success. Recovery is a retry, and every caller's retry recomputes its
  /// change list from a LIVE sample, so no retry can be a no-op that reports
  /// success forever.
  func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws

  /// Whether the private CGS mode list is reachable on this OS.
  ///
  /// **CR10** — false degrades to exactly the behaviour that shipped before
  /// revelation existed: the public mode list, no error, no alert. Same
  /// capability-answer shape as `canRotate` below.
  var revealsHiddenModes: Bool { get }

  /// Whether this build can rotate displays at all.
  ///
  /// **RT5** — a missing private symbol is a capability answer, not a crash. When
  /// this is false every rotation control is absent, the way
  /// `BrightnessPathPolicy` reports an unavailable path rather than trapping.
  var canRotate: Bool { get }

  /// The display's current orientation, or nil if it reports something that is
  /// not a right angle (RT7).
  func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation?

  /// Rotates ONE display and proves it happened.
  ///
  /// **One display, never a batch (RT9).** There is no `SLSConfigureDisplay-
  /// Rotation`, so rotation cannot be staged into a `CGBeginDisplayConfiguration`
  /// transaction the way a mirror change can. N displays would be N independent
  /// calls, each able to fail alone — so the half-applied state that
  /// `MirrorRefusal.residualMembers` had to describe is kept unrepresentable by
  /// never offering the batch.
  ///
  /// **Verifies the readback (RT8).** A `CGError` of 0 is not evidence: `-90`
  /// and `360` both return success and change nothing (RS5). Throws
  /// `DisplayConfigError` if the call fails OR if the achieved rotation is not
  /// the requested one.
  ///
  /// **Blocks (RS10).** Measured at 0.4–1.1s, because the call does not return
  /// until the rotation has taken effect. Never call it on the main actor.
  func applyRotation(_ rotation: DisplayRotation, to displayID: CGDirectDisplayID) throws
}
