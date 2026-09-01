import CoreGraphics
import Foundation

/// A rotation applied and waiting to be answered.
///
/// **There is no commit step.** The other preview sessions apply at
/// `kCGConfigureForAppOnly` and re-apply at session or permanent scope to make
/// it stick. A rotation is already permanent the instant it is applied: RS7
/// measured one outliving the process that set it, so there is no scope to
/// promote out of. `confirm` writes nothing; only `revert` touches hardware.
///
/// So **the countdown is not a backstop against a crash** (RT11). Kill the app
/// mid-preview and the display stays rotated. Survivable, because a rotated
/// display stays readable and System Settings stays reachable, but nothing here
/// may be written as though the app dying undoes anything.
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
  /// A second `begin` supersedes rather than nesting, and never refuses:
  /// refusing would leave someone stuck at an angle they are trying to change.
  ///
  /// **It keeps the STANDING preview's `from`, discarding the new request's.**
  /// A caller fills `from` with the display's current angle, and while a
  /// preview stands that angle is the unapproved previewed one, so an
  /// unanswered expiry would land on an angle nobody chose and, since a
  /// rotation is permanent the instant it applies, rest there. The origin
  /// therefore walks back to where the display was before any of this, however
  /// many times the user rotates inside one window. `previewed` reports the
  /// rewritten request, and `confirm`/`revert` match on it, so that is the
  /// value an answer has to carry back.
  public func begin(_ request: RotationRequest) -> Result<Void, DisplayConfigError> {
    var origin = request.from
    if let standing = outstanding, standing.display == request.display {
      origin = standing.from
    }
    let previewing = RotationRequest(
      display: request.display, from: origin, to: request.to
    )
    do {
      try configurator.applyRotation(previewing.to, to: previewing.display)
    } catch let error as DisplayConfigError {
      return .failure(error)
    } catch {
      // `-1`, the sentinel the sibling sessions use, not `CGError.failure`
      // (1000): 1000 is what a genuine CoreGraphics refusal reports, so reusing
      // it would make "the seam threw a non-`DisplayConfigError`"
      // indistinguishable from a real platform failure in the diagnostics.
      return .failure(DisplayConfigError(cgErrorCode: -1))
    }
    outstanding = previewing
    remaining = timeoutSeconds
    return .success(())
  }

  /// Keeps it. Nothing is written — see the type's note.
  public func confirm(_ answered: RotationRequest) -> PreviewOutcome {
    guard outstanding == answered else { return .stale }
    outstanding = nil
    remaining = 0
    return .committed
  }

  public func revert(_ answered: RotationRequest) -> PreviewOutcome {
    guard outstanding == answered else { return .stale }
    return performRevert(answered)
  }

  /// One second of the clock. Returns nil while it is still running, and the
  /// outcome of the expiry revert on the tick that spends it.
  public func tick() -> PreviewOutcome? {
    guard let outstanding, remaining > 0 else { return nil }
    remaining -= 1
    guard remaining == 0 else { return nil }
    return performRevert(outstanding)
  }

  /// The display went away while its rotation was unanswered. Nothing to undo:
  /// an absent display cannot be rotated back, and the request must not sit
  /// waiting for an answer about hardware that is gone.
  public func discardOnDeparture() {
    outstanding = nil
    remaining = 0
  }

  private func performRevert(_ request: RotationRequest) -> PreviewOutcome {
    do {
      try configurator.applyRotation(request.from, to: request.display)
    } catch let error as DisplayConfigError {
      // The clock is spent either way: a revert that failed will not succeed by
      // being waited for, and leaving it counting re-runs the failing call every
      // second.
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
