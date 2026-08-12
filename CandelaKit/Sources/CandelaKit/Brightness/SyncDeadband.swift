/// Ambient hunting deadband for cross-display brightness sync.
///
/// macOS's own ambient auto-brightness HUNTS the built-in panel: it oscillates
/// around a point in steps too small to see instead of drifting one way, and
/// sync used to replicate every one of them onto the externals as a DDC write.
/// Measured over twelve idle minutes: 1278 fan-outs, 84% of them driven by a
/// source change between 0.005 and 0.011.
///
/// A per-delta threshold would be the wrong shape: a deliberate change reaches
/// sync ALREADY split into small eased steps by `adoptExternal`, so a per-delta
/// rule would swallow real movement. This accumulates instead. Movement is
/// held until it leaves the band, and what leaves is the whole accumulation,
/// so hunting (which returns to its centre) never escapes while a ramp walks
/// out of the band and tracks in band-sized steps.
public struct SyncDeadband: Sendable {
  /// Chosen against the measurement, from both sides:
  ///
  /// - above the hunting envelope: single hunting steps measured 0.005 to
  ///   0.011 and their running sum stays around 0.02 of the centre, so 0.03
  ///   leaves hunting no way out of the band;
  /// - below half a brightness key press (1/16 = 0.0625): a residual can sit
  ///   anywhere inside the band, so a press clears the band from ANY starting
  ///   residual only while 2 * threshold < 0.0625. At 0.03 the worst case
  ///   still crosses by 0.0625 - 0.03 = 0.0325; 0.032 would already lose that
  ///   guarantee, so the margin here is 0.06 against 0.0625 and thin on
  ///   purpose.
  ///
  /// Two costs, both deliberate. A press does not arrive all at once: eased
  /// into sub-steps by `adoptExternal`, its first crossing releases 0.0347 of
  /// the 0.0625, so about 55% lands promptly and the rest rides out with the
  /// next movement. And a fine adjust is under the band entirely (1/64 =
  /// 0.015625 on the system's own grid, a flat 0.01 through `step`), so one
  /// fine press moves nothing and the second or third releases the pair or
  /// triple together: still tracking, in coarser grain than it was asked for.
  ///
  /// The standing cost is a steady-state lag: an external can sit up to one
  /// band, 3% of range, behind its source. That is under half of the 9-unit
  /// raw swing the storm produced on the Dell, and it does not oscillate.
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
