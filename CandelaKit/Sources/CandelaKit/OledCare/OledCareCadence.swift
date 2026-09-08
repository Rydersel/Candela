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
  /// The nomination geometry refresh rides this loop on a one second throttle:
  /// slower stretches a moved window's shed, faster is dropped by the throttle.
  public static let windowFollow: Duration = .seconds(1)
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

  /// Fast whenever a dim INPUT SHOULD LIFT is up by any delivery, or an
  /// achieved-state verification is pending.
  ///
  /// `anyOverlayUp` is the WANT, not the verified presence, on purpose: input
  /// lifts a dim the engine believes is up, and that belief needs fast ticks to
  /// be corrected. Only dims `liftsOnInput` covers: detection dimming's mask is
  /// `nominationDisplayed`, which buys the window-follow second, not 10 Hz.
  ///
  /// `anythingEnrolled` defaults to true so a caller that forgets it cannot idle
  /// the loop by accident. A displayed nomination outranks it: a mask on screen
  /// is work in flight whatever the caller says about enrollment.
  public static func interval(
    anyOverlayUp: Bool, anyLockDimEngaged: Bool, verificationPending: Bool,
    nominationDisplayed: Bool = false, anythingEnrolled: Bool = true
  ) -> Duration {
    if anyOverlayUp || anyLockDimEngaged || verificationPending { return fast }
    if nominationDisplayed { return windowFollow }
    return anythingEnrolled ? slow : idle
  }
}

extension OledDimState {
  /// Whether the user's next input should end this dim. The cadence's fast term
  /// and the driver's input monitor both key on it, so they cannot disagree.
  /// `.active` is excluded though it can carry an overlay: detection dimming's
  /// mask follows window geometry, not input, and counting it held the loop at 10 Hz.
  public var liftsOnInput: Bool {
    switch self {
    case .idleDim, .blackout, .lockDim, .unfocusedDim: true
    case .active, .suspended: false
    }
  }
}
