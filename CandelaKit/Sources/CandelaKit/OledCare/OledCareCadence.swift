import Foundation

/// The OLED care driver's poll cadence.
///
/// In the Kit and pure because the coordinator's own copy shipped with a term
/// missing: it keyed the fast cadence on an overlay being up, so a lock dim
/// (delivered on the wire, no overlay) fell through to the 2 s cadence and a
/// user typing their password waited up to 2 s for the lift.
public enum OledCareCadence {
  /// Restore-latency gate: any perceptible lag makes this unusable.
  public static let fast: Duration = .milliseconds(100)
  /// The thresholds are minutes, so nothing needs a fast tick to reach them.
  public static let slow: Duration = .seconds(2)
  /// Nothing enrolled: the loop has no work, and `reconcileEnrollment` restarts
  /// it on enrollment so nothing waits this out.
  public static let idle: Duration = .seconds(30)

  /// One capture per enrolled display. Kit-owned because the settings panes
  /// judge staleness against multiples of it.
  public static let sampling: Duration = .seconds(60)

  /// Derived, so the two spellings cannot drift.
  public static let samplingSeconds: Double = Double(
    OledCareCadence.sampling.components.seconds)

  /// Two and a half intervals: exactly two put the boundary on the next
  /// capture's arrival, so one late capture flipped the dot off.
  public static let livenessWindowSeconds: Double = 2.5 * OledCareCadence.samplingSeconds

  /// Not the liveness window: this one accuses macOS of dropping the grant, so
  /// it waits until skipped captures cannot explain the silence.
  public static let stallWarningSeconds: Double = 10 * OledCareCadence.samplingSeconds

  /// Fast whenever a dim is UP BY ANY DELIVERY, or an achieved-state
  /// verification is pending.
  ///
  /// `anyOverlayUp` is the WANT, not the verified presence, on purpose: input
  /// lifts a dim the engine believes is up, and that belief needs fast ticks to
  /// be corrected.
  ///
  /// `anythingEnrolled` defaults to true so a caller that forgets it cannot idle
  /// the loop by accident.
  public static func interval(
    anyOverlayUp: Bool, anyLockDimEngaged: Bool, verificationPending: Bool,
    anythingEnrolled: Bool = true
  ) -> Duration {
    if anyOverlayUp || anyLockDimEngaged || verificationPending { return fast }
    return anythingEnrolled ? slow : idle
  }
}
