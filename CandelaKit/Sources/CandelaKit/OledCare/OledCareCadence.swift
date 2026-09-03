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
  /// Nothing enrolled. The loop still has to exist, since an enrollment can
  /// arrive at any moment, but it has no work to do and no reason to wake 30
  /// times a minute for the life of the app. `reconcileEnrollment` restarts the
  /// driver when the idle state ends, so an enrollment does not wait this out.
  public static let idle: Duration = .seconds(30)

  /// Telemetry's own cadence: one capture per enrolled display per minute. It
  /// lives here because three surfaces judge a reading stale against multiples
  /// of it and each had picked its own number.
  public static let sampling: Duration = .seconds(60)

  /// The same interval where the caller reasons in `TimeInterval`. Derived, so
  /// the two spellings cannot drift.
  public static let samplingSeconds: Double = Double(
    OledCareCadence.sampling.components.seconds)

  /// A reading counts as live for two and a half sampling intervals. Exactly two
  /// put the boundary on top of the next capture's own arrival, so a single late
  /// or skipped one flipped the dot off; the half interval is the slack that
  /// takes to survive one miss. Still short enough that a dead Screen Recording
  /// grant stills the dot inside three minutes.
  public static let livenessWindowSeconds: Double = 2.5 * OledCareCadence.samplingSeconds

  /// The stall warning's window, ten intervals, and deliberately NOT the
  /// liveness window. This one accuses macOS of having dropped the Screen
  /// Recording grant, so it waits until an ordinary run of skipped captures
  /// cannot explain the silence.
  public static let stallWarningSeconds: Double = 10 * OledCareCadence.samplingSeconds

  /// Fast whenever a dim is UP BY ANY DELIVERY, or an achieved-state
  /// verification is pending.
  ///
  /// `anyOverlayUp` is the WANT, not the verified presence, on purpose: input
  /// lifts a dim the engine believes is up, and that belief needs fast ticks to
  /// be corrected.
  ///
  /// `anythingEnrolled` defaults to true so that the parameter cannot change a
  /// caller's answer by being forgotten; the one term that reaches `idle` is the
  /// one a caller has to state.
  public static func interval(
    anyOverlayUp: Bool, anyLockDimEngaged: Bool, verificationPending: Bool,
    anythingEnrolled: Bool = true
  ) -> Duration {
    if anyOverlayUp || anyLockDimEngaged || verificationPending { return fast }
    return anythingEnrolled ? slow : idle
  }
}
