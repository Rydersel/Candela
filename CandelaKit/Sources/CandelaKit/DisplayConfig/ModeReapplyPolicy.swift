import CoreGraphics
import Foundation

/// What the reapply pass has to tell the user about one display.
///
/// Reapply runs unattended, at launch and on arrival, so nobody is watching to
/// notice that the mode they asked for is not the mode they got. Every case
/// here exists because staying quiet leaves no way to find out.
public enum ModeReapplyNotice: Sendable, Equatable {
  /// The stored descriptor resolved to an adjacent mode. Carries what is on the
  /// display now, which is not what was stored.
  case substituted(DisplayMode)
  /// Nothing on this display was an acceptable candidate. Nothing was changed.
  case unavailable
  /// The apply failed, including the descriptor-mismatch throw
  /// `CoreGraphicsDisplayConfigurator.apply` raises when a reassigned
  /// `ioModeID` resolves to a different mode. Swallowing it would leave a
  /// display on some third mode with the app believing it restored the stored
  /// one.
  case failed(DisplayConfigError)
}

/// One display's reapply decision: what to apply, and what to say. Independent
/// on purpose, because a display already sitting on the substitute needs no
/// apply and still needs the notice.
public struct ModeReapplyDecision: Sendable, Equatable {
  /// nil means "change nothing".
  public let modeToApply: DisplayMode?
  /// nil means the stored choice was honoured exactly.
  public let notice: ModeReapplyNotice?
  /// "Not now", as distinct from "nothing to do": nothing is applied, nothing
  /// is reported, and the caller hands the arrival back
  /// (`DisplayArrivalTracker.release`) so a later event retries. `.doNothing`
  /// would mark the display handled, and since a display that never leaves is
  /// never an arrival again (DM7), "not now" would mean "never until replug".
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
/// Pure and separate from the CoreGraphics calls because nobody is watching. A
/// preview that goes wrong is answered in thirty seconds; a reapply that goes
/// wrong is found days later.
public enum ModeReapplyPolicy {
  /// - Parameters:
  ///   - isEnabled: the per-display opt-in (DM5). Part of this decision rather
  ///     than a call-site guard, so "a display nobody opted in for is never
  ///     moved" is a property under test here.
  ///   - isMirroringAnotherDisplay: the SLAVE of a mirror set
  ///     (`ConfiguredDisplay.isMirrorSlave`). Deferred, never applied: its
  ///     pixels are the master's, and the online list this pass reads makes
  ///     every mirror slave look like an arrival. The master is a legitimate
  ///     target.
  ///   - current: what the display is running, or nil when it could not be
  ///     read. Deferred, not guessed at.
  public static func decide(
    isEnabled: Bool,
    isMirroringAnotherDisplay: Bool = false,
    stored: DisplayModeDescriptor?,
    available: [DisplayMode],
    current: DisplayMode?
  ) -> ModeReapplyDecision {
    guard isEnabled, let stored else { return .doNothing }
    // Both gates run before resolution and both defer rather than decide: a
    // display that cannot report its current mode cannot report a trustworthy
    // mode list either, so resolving would raise `.unavailable` about a display
    // that was merely asleep.
    guard !isMirroringAnotherDisplay else { return .deferred }
    // A blind apply is the more dangerous move: sleeping and mirrored displays
    // are exactly the ones that read as unreadable, and a failure there stands
    // until a physical replug, because a wake is not a departure/arrival cycle.
    // Deferring hands the arrival back and the wake itself produces an event.
    guard let current else { return .deferred }

    switch ModePersistence.resolve(stored, in: available) {
    case let .exact(mode):
      // Not an optimisation. Applying the mode a display already runs still
      // triggers a full CoreGraphics reconfiguration, which suspends DDC writes
      // and fires the topology callback: visible blanking in exchange for
      // nothing, on every display at every launch.
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

  /// Wraps `DisplayMode.matchesGeometry(of:)`, the same predicate the apply
  /// cross-check uses.
  private static func isAlreadyRunning(_ mode: DisplayMode, _ current: DisplayMode) -> Bool {
    current.matchesGeometry(of: mode)
  }
}
