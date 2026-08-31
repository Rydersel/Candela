import CoreGraphics
import Foundation

/// The applied-but-unresolved preview a UI renders, and the value an answer
/// carries back so it can only ever resolve the preview it was given for.
public struct PreviewedMode: Sendable, Equatable {
  public let displayID: CGDirectDisplayID
  public let mode: DisplayMode

  public init(displayID: CGDirectDisplayID, mode: DisplayMode) {
    self.displayID = displayID
    self.mode = mode
  }
}

/// Preview, confirm, commit, with a countdown that defaults to revert.
///
/// A mode can leave a display unreadable, and then nobody can click "Keep", so
/// the safe outcome is the one that happens when nobody answers (DM4).
/// `.preview` scope is a second backstop: `kCGConfigureForAppOnly` reverts if
/// the app dies. An actor because the countdown and the answer race.
///
/// Invariants the safety argument rests on:
/// - No preview begins until the fallback mode has been read.
/// - Confirm commits the mode that was previewed, not what the display reports
///   now; the two differ exactly when something went wrong.
/// - A preview stays outstanding until a resolution succeeds. An apply that
///   throws changed nothing, so the original fallback is still the one to keep,
///   which is why every guard asks "is a preview applied?" and never "was an
///   answer given?".
public actor ModePreviewSession {
  /// One value so no path can pair one preview's display ID with another's
  /// fallback mode.
  private struct OutstandingPreview {
    let displayID: CGDirectDisplayID
    /// Captured before the preview was applied. Survives failed resolutions.
    let previousMode: DisplayMode
    let previewedMode: DisplayMode
  }

  private let configurator: any DisplayConfiguring
  private let countdownSeconds: Int

  private var outstanding: OutstandingPreview?
  private var countdown = PreviewCountdown()
  private var lastOutcome: PreviewOutcome?

  /// Thirty seconds, matching `MirrorPreviewSession`. Fifteen was not long
  /// enough to find and read a confirmation on a display whose text just halved.
  public init(configurator: any DisplayConfiguring, countdownSeconds: Int = 30) {
    self.configurator = configurator
    self.countdownSeconds = countdownSeconds
  }

  public var secondsRemaining: Int { countdown.remaining }

  /// True while a preview is applied and unresolved, including after a
  /// resolution that threw. `revert()` is worth calling exactly while it holds.
  public var hasOutstandingPreview: Bool { outstanding != nil }

  /// What is applied and unresolved. A UI rebuilds its state from this.
  public var previewedMode: PreviewedMode? {
    outstanding.map { PreviewedMode(displayID: $0.displayID, mode: $0.previewedMode) }
  }

  /// Reported rather than inferred: a failed expiry disarms the countdown
  /// while a failed commit leaves it armed.
  public var isCountingDown: Bool { countdown.isArmed && outstanding != nil }

  /// The display is gone: drop the preview without applying anything.
  ///
  /// `begin()` on another display refuses when it cannot revert an outstanding
  /// preview, so one departed display would otherwise wedge mode switching for
  /// every other display. The departed mode was app-scoped and is renegotiated
  /// on return, so `.reverted` is the honest outcome.
  @discardableResult
  public func discard(displayID: CGDirectDisplayID) -> Bool {
    guard outstanding?.displayID == displayID else { return false }
    outstanding = nil
    countdown.disarm()
    lastOutcome = .reverted
    return true
  }

  public func begin(
    mode: DisplayMode, on displayID: CGDirectDisplayID
  ) -> Result<Void, DisplayConfigError> {
    let previous: DisplayMode

    if let outstanding {
      if outstanding.displayID == displayID {
        // Keep the ORIGINAL fallback: the mode on screen is the unconfirmed
        // preview, which is never safe to fall back to.
        previous = outstanding.previousMode
      } else {
        // End a live preview on another display first, or its fallback gets
        // retargeted here and that display is left in preview with no
        // countdown. Refuse if the revert fails rather than strand it.
        if case let .failed(error) = revertOutstanding() { return .failure(error) }
        guard let read = configurator.currentMode(for: displayID) else {
          return .failure(DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
        }
        previous = read
      }
    } else {
      // Capture before applying: revert restores this exact mode, not
      // whatever macOS considers the default.
      guard let read = configurator.currentMode(for: displayID) else {
        // No readable mode means no way back, so refuse the preview.
        return .failure(DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
      }
      previous = read
    }

    do {
      try configurator.apply(mode, to: displayID, scope: .preview)
    } catch let error as DisplayConfigError {
      return .failure(error)
    } catch {
      return .failure(DisplayConfigError(cgErrorCode: -1))
    }
    outstanding = OutstandingPreview(
      displayID: displayID, previousMode: previous, previewedMode: mode
    )
    // Cleared here, not on entry: a begin() that fails establishes nothing, so
    // the last thing that really happened to the display stays the last outcome.
    lastOutcome = nil
    countdown.arm(seconds: countdownSeconds)
    return .success(())
  }

  /// Commits the preview the caller was looking at.
  ///
  /// `answered` is the `PreviewedMode` that was rendered. If a second selection
  /// landed since, the answer is stale: committing would make a mode the user
  /// never saw permanent at session scope while reporting success.
  public func confirm(_ answered: PreviewedMode) -> PreviewOutcome {
    guard let outstanding else {
      // Nothing applied: repeat the last outcome rather than invent a
      // reversion. Never begun reports reverted, since nothing is kept.
      return lastOutcome ?? .reverted
    }
    guard matches(answered, outstanding) else { return .stale }
    return resolve(
      applying: outstanding.previewedMode, to: outstanding.displayID, success: .committed
    )
  }

  /// Safe to call repeatedly for the same preview. A revert that threw left the
  /// display where it was, so retrying once CoreGraphics recovers is the
  /// recovery path the error UI drives.
  public func revert(_ answered: PreviewedMode) -> PreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }
    guard matches(answered, outstanding) else { return .stale }
    return revertOutstanding()
  }

  /// Call once per second. Returns nil while the countdown runs, and the
  /// outcome when it expires.
  public func tick() -> PreviewOutcome? {
    guard outstanding != nil, countdown.tick() else { return nil }
    return revertOutstanding()
  }

  // MARK: - Private

  /// The expiry and the cross-display hand-off skip the intent check: they are
  /// the session's own decisions, not a person's answer. Only answers go stale.
  private func revertOutstanding() -> PreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }
    return resolve(
      applying: outstanding.previousMode, to: outstanding.displayID, success: .reverted
    )
  }

  private func matches(_ answered: PreviewedMode, _ outstanding: OutstandingPreview) -> Bool {
    answered.displayID == outstanding.displayID && answered.mode == outstanding.previewedMode
  }

  /// Success is what clears the outstanding preview. A throw leaves session
  /// state intact: the display did not move, so the record of how to move it
  /// back is still true.
  ///
  /// A failed commit leaves the countdown armed on purpose, so a mode that
  /// could not be made permanent still falls back to one the user can see.
  private func resolve(
    applying mode: DisplayMode, to displayID: CGDirectDisplayID,
    success: PreviewOutcome
  ) -> PreviewOutcome {
    do {
      try configurator.apply(mode, to: displayID, scope: .session)
    } catch let error as DisplayConfigError {
      lastOutcome = .failed(error)
      return .failed(error)
    } catch {
      let error = DisplayConfigError(cgErrorCode: -1)
      lastOutcome = .failed(error)
      return .failed(error)
    }
    outstanding = nil
    countdown.disarm()
    lastOutcome = success
    return success
  }
}
