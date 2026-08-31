/// Ambient hunting deadband for cross-display brightness sync.
///
/// macOS's own ambient auto-brightness HUNTS the built-in panel: it oscillates
/// around a point in steps too small to see, and sync used to replicate every
/// one of them onto the externals as a DDC write. Measured over twelve idle
/// minutes: 1278 fan-outs, 84% of them from a source change between 0.005 and
/// 0.011.
///
/// A per-delta threshold would swallow real movement, because a deliberate
/// change reaches sync ALREADY split into small eased steps by `adoptExternal`.
/// This accumulates instead, and what leaves the band is the whole
/// accumulation, so hunting never escapes while a ramp walks out of it.
public struct SyncDeadband: Sendable {
  /// Bounded by the measurement from both sides:
  ///
  /// - above the hunting envelope: single hunting steps measured 0.005 to 0.011
  ///   and their running sum stays around 0.02 of the centre, so 0.03 leaves
  ///   hunting no way out of the band;
  /// - below half a brightness key press (1/16 = 0.0625): a residual can sit
  ///   anywhere inside the band, so a press clears it from ANY starting residual
  ///   only while 2 * threshold < 0.0625. At 0.03 the worst case still crosses
  ///   by 0.0325, and 0.032 would already lose that guarantee.
  ///
  /// Two costs, both deliberate. A press arrives eased into sub-steps, so its
  /// first crossing releases 0.0347 of the 0.0625 and the rest rides out with
  /// the next movement. The system's own fine adjust (1/64 = 0.015625) is under
  /// the band entirely, so one fine press moves nothing and the second or third
  /// releases them together. Candela's own fine step never reaches here: a local
  /// write is echo-suppressed at the poller.
  ///
  /// The standing cost is a steady-state lag: an external can sit one band, 3%
  /// of range, behind its source. That is under half the 9-unit raw swing the
  /// storm produced on the Dell, and it does not oscillate.
  public static let threshold = 0.03

  /// Source movement observed but not yet fanned out. Never reaches
  /// `threshold`: crossing it is what empties this.
  public private(set) var held: Double = 0

  public init() {}

  /// Returns the movement to fan out, or nil while the source has not moved
  /// far enough from the value the targets were last driven to.
  public mutating func admit(_ delta: Double) -> Double? {
    held += delta
    guard abs(held) >= Self.threshold else { return nil }
    let step = held
    held = 0
    return step
  }

  /// Drops what is held, re-centring the band on the source's current value.
  /// Movement nobody replicated is movement the targets do not owe.
  public mutating func reset() {
    held = 0
  }
}
