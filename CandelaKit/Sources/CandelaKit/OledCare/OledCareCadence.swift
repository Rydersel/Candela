import Foundation

/// The OLED care driver's poll cadence.
///
/// In the Kit, and a pure function, because the coordinator's own copy shipped
/// with a term missing: it keyed the fast cadence on an overlay being up, and a
/// lock dim (delivered on the wire, so it raises no overlay) fell through to the
/// 2 s cadence. The any-input lift is driven by a tick noticing a falling idle
/// counter, so the user typing their password waited up to 2 s for a dim the
/// overlay era lifted in 100 ms. A predicate nobody can test is a predicate that
/// loses a term.
public enum OledCareCadence {
  /// #21's restore-latency gate: "any perceptible lag makes this unusable".
  public static let fast: Duration = .milliseconds(100)
  /// The thresholds are minutes, so nothing needs a fast tick to reach them.
  public static let slow: Duration = .seconds(2)

  /// Fast whenever a dim is UP BY ANY DELIVERY, or an OC12 verification is
  /// pending.
  ///
  /// `anyOverlayUp` is the WANT, not the verified presence, on purpose: the
  /// gate is about input lifting a dim the engine believes is up, and that
  /// belief is what needs fast ticks to be corrected.
  public static func interval(
    anyOverlayUp: Bool, anyLockDimEngaged: Bool, verificationPending: Bool
  ) -> Duration {
    anyOverlayUp || anyLockDimEngaged || verificationPending ? fast : slow
  }
}
