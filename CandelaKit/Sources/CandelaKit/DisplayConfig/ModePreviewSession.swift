import CoreGraphics
import Foundation

public enum ModePreviewOutcome: Sendable, Equatable {
  case committed
  case reverted
  case failed(DisplayConfigError)
}

/// Preview → confirm → commit, with a countdown that **defaults to revert**.
///
/// The whole reason this exists: a mode can leave a display unreadable, and at
/// that point the user cannot click "Keep". So the safe outcome must be the
/// one that happens when nobody does anything (spec DM4). `.preview` scope is
/// a second backstop — `kCGConfigureForAppOnly` reverts if the app dies.
///
/// An actor because the countdown and the user's answer race by construction.
///
/// Two things the safety argument depends on, both enforced below:
/// - A preview never begins unless the mode to fall back to was read first.
///   Without it the countdown would expire into a no-op, which is the failure
///   this whole type exists to prevent.
/// - Confirming commits the mode that was previewed, not whatever the display
///   reports at confirm time. The two differ exactly when something went wrong
///   (replug, sleep/wake, another process reconfiguring), and committing the
///   drifted value with session scope would make an unapproved mode permanent
///   while reporting success.
public actor ModePreviewSession {
  private let configurator: any DisplayConfiguring
  private let countdownSeconds: Int

  private var previousMode: DisplayMode?
  private var previewedMode: DisplayMode?
  private var displayID: CGDirectDisplayID?
  private var remaining = 0
  private var resolved = true
  private var lastOutcome: ModePreviewOutcome?

  public init(configurator: any DisplayConfiguring, countdownSeconds: Int = 15) {
    self.configurator = configurator
    self.countdownSeconds = countdownSeconds
  }

  public var secondsRemaining: Int { remaining }

  public func begin(
    mode: DisplayMode, on displayID: CGDirectDisplayID
  ) -> Result<Void, DisplayConfigError> {
    // A live preview on a DIFFERENT display is ended rather than abandoned:
    // otherwise its fallback mode would be silently retargeted at the new
    // display, and the old one would be left in preview with no countdown.
    if !resolved, self.displayID != displayID {
      _ = revert()
    }
    // Capture BEFORE applying — reverting restores this exact mode, not
    // "whatever macOS thinks the default is". Re-previewing the same display
    // keeps the ORIGINAL fallback; the mode currently on screen is the
    // unconfirmed preview, which is never a safe thing to fall back to.
    let previous = resolved ? configurator.currentMode(for: displayID) : previousMode
    guard let previous else {
      // Nothing readable to restore means nothing to undo with. Refusing the
      // preview is the only safe answer; the caller surfaces it.
      return .failure(DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
    }
    do {
      try configurator.apply(mode, to: displayID, scope: .preview)
    } catch let error as DisplayConfigError {
      return .failure(error)
    } catch {
      return .failure(DisplayConfigError(cgErrorCode: -1))
    }
    previousMode = previous
    previewedMode = mode
    self.displayID = displayID
    remaining = countdownSeconds
    resolved = false
    lastOutcome = nil
    return .success(())
  }

  public func confirm() -> ModePreviewOutcome {
    guard !resolved, let displayID, let mode = previewedMode else {
      // Already answered: repeat the answer already given rather than
      // inventing a reversion that never happened. Never begun at all is
      // reported as reverted — nothing is being kept.
      return lastOutcome ?? .reverted
    }
    return resolve(applying: mode, to: displayID, success: .committed)
  }

  public func revert() -> ModePreviewOutcome {
    guard !resolved, let displayID, let previousMode else {
      return lastOutcome ?? .reverted
    }
    return resolve(applying: previousMode, to: displayID, success: .reverted)
  }

  /// Call once per second. Returns nil while the countdown runs, and the
  /// outcome when it expires.
  public func tick() -> ModePreviewOutcome? {
    guard !resolved else { return nil }
    remaining -= 1
    guard remaining <= 0 else { return nil }
    return revert()
  }

  // MARK: - Private

  /// Resolution is one-way and happens whether the apply succeeded or not: a
  /// failed revert is reported to the caller rather than retried forever on
  /// every tick. The `.preview` scope remains the last backstop — the mode is
  /// dropped when the process exits.
  private func resolve(
    applying mode: DisplayMode, to displayID: CGDirectDisplayID,
    success: ModePreviewOutcome
  ) -> ModePreviewOutcome {
    resolved = true
    remaining = 0
    let outcome: ModePreviewOutcome
    do {
      try configurator.apply(mode, to: displayID, scope: .session)
      outcome = success
    } catch let error as DisplayConfigError {
      outcome = .failed(error)
    } catch {
      outcome = .failed(DisplayConfigError(cgErrorCode: -1))
    }
    lastOutcome = outcome
    return outcome
  }
}
