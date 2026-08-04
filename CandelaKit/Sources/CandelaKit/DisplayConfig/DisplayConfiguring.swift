import CoreGraphics
import Foundation

/// How long an applied mode should last.
///
/// `Equatable` is declared here rather than added by a test-side extension:
/// it is our own type in our own module, so a `@retroactive` conformance
/// would be both unnecessary and wrong.
public enum DisplayConfigScope: Sendable, Equatable {
  /// `kCGConfigureForAppOnly` — reverts when this process exits, including on
  /// a crash. The safe way to show someone a mode before committing to it.
  case preview
  /// `kCGConfigureForSession` — outlives the process.
  case session
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
  /// own — this is the exact predicate that was hand-written at
  /// `KeyActionExecutor.swift:250-251` before this type carried it.
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
}
