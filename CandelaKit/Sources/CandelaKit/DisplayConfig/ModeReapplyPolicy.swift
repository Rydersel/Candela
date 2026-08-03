import CoreGraphics
import Foundation

/// What the reapply pass has to TELL the user about one display.
///
/// Reapply runs unattended — at launch and when a display arrives — so there is
/// nobody watching to notice that the mode they asked for is not the mode they
/// got. Every case here exists because staying quiet about it would mean the
/// user asked for one thing, silently received another, and had no way to find
/// out (spec §8: "any outcome past step 1 is surfaced to the user rather than
/// applied silently").
public enum ModeReapplyNotice: Sendable, Equatable {
  /// The stored descriptor resolved to something adjacent — a different refresh
  /// rate, a different framebuffer, or a different size. Carries what is on the
  /// display now, which is not what was stored.
  case substituted(DisplayMode)
  /// Nothing on this display was an acceptable candidate. Nothing was changed.
  case unavailable
  /// The apply itself failed, including the descriptor-mismatch throw that
  /// `CoreGraphicsDisplayConfigurator.apply` raises when a reassigned
  /// `ioModeID` resolves to a different mode. Nothing was (reliably) changed —
  /// which is exactly why it cannot be swallowed: the alternative is a display
  /// left on some third mode with the app believing it restored the stored one.
  case failed(DisplayConfigError)
}

/// One display's reapply decision: what to apply, and what to say.
///
/// The two are independent on purpose. A display already sitting on the
/// substitute needs no apply and still needs the notice — the stored choice is
/// no more honoured than if we had just moved it there.
public struct ModeReapplyDecision: Sendable, Equatable {
  /// nil means "change nothing".
  public let modeToApply: DisplayMode?
  /// nil means "the stored choice was honoured exactly" — the only case that
  /// says nothing at all.
  public let notice: ModeReapplyNotice?
  /// "Not now" as distinct from "nothing to do". Nothing is applied and nothing
  /// is reported, and the caller is being told to give the arrival back
  /// (`DisplayArrivalTracker.release`) so a later event tries again.
  ///
  /// A third outcome is needed because the two fields above cannot express it:
  /// they say what to DO about this arrival, and this says the arrival has not
  /// been dealt with at all. Silently returning `.doNothing` would mark the
  /// display handled, and — since a display that never leaves is never an
  /// arrival again (DM7) — "not now" would quietly mean "never until replug".
  public let isDeferred: Bool

  public init(modeToApply: DisplayMode?, notice: ModeReapplyNotice?, isDeferred: Bool = false) {
    self.modeToApply = modeToApply
    self.notice = notice
    self.isDeferred = isDeferred
  }

  public static let doNothing = ModeReapplyDecision(modeToApply: nil, notice: nil)
  public static let deferred = ModeReapplyDecision(
    modeToApply: nil, notice: nil, isDeferred: true
  )
}

/// The unattended half of stored-mode handling: given what was stored and what
/// the display now offers, decide whether to move it and what to report.
///
/// Pure and separate from the CoreGraphics calls because this is the path with
/// no user in front of it. A preview that goes wrong is answered by a person
/// within fifteen seconds; a reapply that goes wrong is discovered days later,
/// so the rules it follows are stated once, here, and tested.
public enum ModeReapplyPolicy {
  /// - Parameters:
  ///   - isEnabled: the per-display opt-in (DM5). Deliberately part of THIS
  ///     decision rather than a call-site guard: "a display nobody opted in for
  ///     is never moved" is the property most worth having under test, and a
  ///     guard at the call site is a property of the caller instead.
  ///   - isMirroringAnotherDisplay: this display is the SLAVE of a mirror set
  ///     (`ConfiguredDisplay.isMirrorSlave`). Deferred, never applied: the
  ///     pixels on it are the master's, so a resolution change there is
  ///     something the user neither asked for nor can watch the consequences
  ///     of — and the online list this pass reads makes every mirror slave look
  ///     like an arrival. The MASTER is not this, and is a legitimate target.
  ///   - current: what the display is running, or nil when it could not be
  ///     read. Deferred, not guessed at — see the `guard` below.
  public static func decide(
    isEnabled: Bool,
    isMirroringAnotherDisplay: Bool = false,
    stored: DisplayModeDescriptor?,
    available: [DisplayMode],
    current: DisplayMode?
  ) -> ModeReapplyDecision {
    guard isEnabled, let stored else { return .doNothing }
    // Both gates below are deliberately BEFORE resolution, and both defer
    // rather than decide. Their common cause is that the display is not in a
    // state to be reconfigured OR to be described: a display that cannot report
    // its current mode generally cannot report a trustworthy mode list either,
    // so resolving here would just as easily produce a `.unavailable` notice —
    // a failure report about a display that was merely asleep.
    guard !isMirroringAnotherDisplay else { return .deferred }
    // Applying to a display whose current mode is unreadable used to be the
    // recoverable answer, on the grounds that skipping would silently drop the
    // reapply. It no longer is, in both halves. A blind apply is now the more
    // dangerous move — it is precisely the sleeping and mirrored displays that
    // read as unreadable, and an apply that fails there produces a failure
    // report that stands until the display is physically replugged, because a
    // wake is no longer a departure/arrival cycle. And skipping is no longer
    // silent: deferring hands the arrival back, so the next topology event —
    // the wake itself produces one — tries again with a display that can answer.
    guard let current else { return .deferred }

    switch ModePersistence.resolve(stored, in: available) {
    case let .exact(mode):
      // The skip is not an optimisation. Applying the mode a display is already
      // running still triggers a full CoreGraphics reconfiguration — which
      // suspends DDC writes, fires the topology callback, and would arrive back
      // here as another event. Doing it for every display at every launch is
      // visible screen-blanking in exchange for nothing.
      return isAlreadyRunning(mode, current)
        ? .doNothing
        : ModeReapplyDecision(modeToApply: mode, notice: nil)

    case let .refreshRateDiffers(mode), let .scaleDiffers(mode), let .sizeDiffers(mode):
      return ModeReapplyDecision(
        modeToApply: isAlreadyRunning(mode, current) ? nil : mode,
        notice: .substituted(mode)
      )

    case .none:
      return ModeReapplyDecision(modeToApply: nil, notice: .unavailable)
    }
  }

  /// Compared on the DESCRIPTOR, never on `ioModeID`: the ID is a positional
  /// handle that is reassigned across reconfiguration, so two equal IDs are not
  /// evidence of the same mode and two different IDs are not evidence of
  /// different ones. Refresh carries the usual tolerance — CoreGraphics reports
  /// 59.997, and an exact comparison would decide the display is never already
  /// where it is.
  private static func isAlreadyRunning(_ mode: DisplayMode, _ current: DisplayMode) -> Bool {
    current.logicalWidth == mode.logicalWidth
      && current.logicalHeight == mode.logicalHeight
      && current.pixelWidth == mode.pixelWidth
      && current.pixelHeight == mode.pixelHeight
      && ModePersistence.refreshMatches(current.refreshHz, mode.refreshHz)
  }
}
