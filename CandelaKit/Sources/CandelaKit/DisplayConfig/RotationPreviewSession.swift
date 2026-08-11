import CoreGraphics
import Foundation

/// A rotation applied and waiting to be answered.
///
/// **There is no commit step, and that is the structural difference from the
/// other three preview sessions in this codebase.** A display mode is applied at
/// `kCGConfigureForAppOnly` and has to be re-applied at session scope to stick;
/// a mirror likewise, and an arrangement commits at `.permanent`. A rotation is
/// **already permanent the instant it is applied** — RS7 measured one outliving
/// the process that set it entirely, so there is no scope to promote out of.
///
/// So `confirm` does not write anything. It stops the countdown, and that is the
/// whole of it. `revert` is the only answer that touches the hardware.
///
/// The consequence worth stating out loud (RT11): **the countdown is not a
/// backstop against a crash.** Mirroring's could be — `kCGConfigureForAppOnly`
/// self-reverts when the process dies. If this app is killed mid-preview, the
/// display stays rotated. That is survivable in a way a bad refresh rate is not,
/// because a rotated display remains readable and System Settings stays
/// reachable, but nothing here should be written as though the app dying undoes
/// anything.
public actor RotationPreviewSession {
  private let configurator: any DisplayConfiguring
  private let timeoutSeconds: Int

  private var outstanding: RotationRequest?
  private var remaining = 0

  public init(configurator: any DisplayConfiguring, timeoutSeconds: Int = 30) {
    self.configurator = configurator
    self.timeoutSeconds = timeoutSeconds
  }

  public var previewed: RotationRequest? { outstanding }
  public var secondsRemaining: Int { remaining }
  public var isCountingDown: Bool { outstanding != nil && remaining > 0 }

  /// Applies the rotation and starts the clock.
  ///
  /// A second `begin` while one is outstanding **supersedes** it rather than
  /// nesting: the new request's `from` is whatever the display is at now, so
  /// reverting it returns to the previous preview's angle, not to the one before
  /// that. The alternative — refusing — leaves someone stuck at an angle they
  /// are trying to change.
  public func begin(_ request: RotationRequest) -> Result<Void, DisplayConfigError> {
    do {
      try configurator.applyRotation(request.to, to: request.display)
    } catch let error as DisplayConfigError {
      return .failure(error)
    } catch {
      // `-1`, the sentinel the three sibling sessions use for this arm, and not
      // `CGError.failure` (1000): 1000 is what a genuine CoreGraphics refusal
      // reports, so reusing it here makes "the seam threw something that was
      // not a `DisplayConfigError`" indistinguishable from a real platform
      // failure in the diagnostics that read the code back.
      return .failure(DisplayConfigError(cgErrorCode: -1))
    }
    outstanding = request
    remaining = timeoutSeconds
    return .success(())
  }

  /// Keeps it. Nothing is written — see the type's note.
  public func confirm(_ answered: RotationRequest) -> ModePreviewOutcome {
    guard outstanding == answered else { return .stale }
    outstanding = nil
    remaining = 0
    return .committed
  }

  public func revert(_ answered: RotationRequest) -> ModePreviewOutcome {
    guard outstanding == answered else { return .stale }
    return performRevert(answered)
  }

  /// One second of the clock. Returns nil while it is still running, and the
  /// outcome of the expiry revert on the tick that spends it.
  public func tick() -> ModePreviewOutcome? {
    guard let outstanding, remaining > 0 else { return nil }
    remaining -= 1
    guard remaining == 0 else { return nil }
    return performRevert(outstanding)
  }

  /// The display went away while its rotation was unanswered. Nothing to undo —
  /// an absent display cannot be rotated back, and the request must not sit
  /// outstanding waiting for an answer about hardware that is gone.
  public func discardOnDeparture() {
    outstanding = nil
    remaining = 0
  }

  private func performRevert(_ request: RotationRequest) -> ModePreviewOutcome {
    do {
      try configurator.applyRotation(request.from, to: request.display)
    } catch let error as DisplayConfigError {
      // The clock is spent either way: a revert that failed will not succeed by
      // being waited for again, and leaving it counting would re-run the same
      // failing call every second. The failure is the caller's to state.
      outstanding = nil
      remaining = 0
      return .failed(error)
    } catch {
      outstanding = nil
      remaining = 0
      // The `-1` sentinel, for the reason `begin` states.
      return .failed(DisplayConfigError(cgErrorCode: -1))
    }
    outstanding = nil
    remaining = 0
    return .reverted
  }
}
