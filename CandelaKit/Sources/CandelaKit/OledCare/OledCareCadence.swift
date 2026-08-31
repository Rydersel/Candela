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

  /// Fast whenever a dim is UP BY ANY DELIVERY, or an OC12 verification is
  /// pending.
  ///
  /// `anyOverlayUp` is the WANT, not the verified presence, on purpose: input
  /// lifts a dim the engine believes is up, and that belief needs fast ticks to
  /// be corrected.
  public static func interval(
    anyOverlayUp: Bool, anyLockDimEngaged: Bool, verificationPending: Bool
  ) -> Duration {
    anyOverlayUp || anyLockDimEngaged || verificationPending ? fast : slow
  }
}
