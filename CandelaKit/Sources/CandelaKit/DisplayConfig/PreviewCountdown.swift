import Foundation

/// A preview session's clock: how many seconds are left, and whether it is
/// still allowed to fire. Held by the Mode, Mirror and Arrangement sessions.
///
/// **The armed flag is not the same fact as `remaining > 0`**, which is why it
/// exists: the countdown fires at most once, so a failed expiry revert disarms
/// rather than re-attempting from every later tick. Re-attempting is
/// `revert()`'s job, on a person's say-so.
///
/// `RotationPreviewSession` deliberately does NOT use this. A rotation is
/// already permanent when applied (RS7), so it has no commit step and no armed
/// flag: its clock is `remaining > 0` alone.
struct PreviewCountdown: Equatable {
  private(set) var remaining = 0
  /// Whether the clock may still fire. False once it has been spent.
  private(set) var isArmed = false

  /// Starts the clock. Restarting supersedes: a second preview replaces the
  /// first rather than nesting.
  mutating func arm(seconds: Int) {
    remaining = seconds
    isArmed = true
  }

  /// Spends the clock without firing it. Used wherever a preview ends by some
  /// route other than expiry: an answer, a discard, a departure.
  mutating func disarm() {
    remaining = 0
    isArmed = false
  }

  /// One second. Returns true on the tick that spends the clock, and only then;
  /// the caller turns that into a revert. A disarmed clock never returns true,
  /// however often it is ticked.
  mutating func tick() -> Bool {
    guard isArmed else { return false }
    remaining -= 1
    guard remaining <= 0 else { return false }
    disarm()
    return true
  }
}
