import Foundation

/// Slider snapping and the percentage readout — the two panel slider options
/// that survive D26. (Tick marks are cut: `showTickMarks` keeps its key so the
/// name is not reused, but nothing renders it and D32 files it as
/// reserved-and-inert, NOT as a `defaults write` escape hatch.)
///
/// One type for both because they describe the same scale. The fork spreads
/// this across three places — `25` in `SliderHandler.valueChanged`, `5` tick
/// marks in its `init`, and a separate percentage formatter — so its own
/// caption's promise ("0%, 25%, 50%, 75% and 100%") is not enforced anywhere.
public enum SliderSnap {
  /// 0%, 25%, 50%, 75%, 100%, in slider units.
  public static let stops: [Double] = [0, 0.25, 0.5, 0.75, 1]

  /// The same stops with `0` removed, for controls where landing on 0 is a
  /// STATE change rather than a value (D29): `DDCValueController.apply` reads
  /// volume 0 as a mute event and, under `enableMuteUnmute`, writes
  /// VCP 0x8D = 1 — a persistent hardware mute that survives relaunch and wake
  /// restore. A cosmetic snapping convenience must not be able to cause that
  /// from anywhere in the bottom `tolerance` of a drag; a user who genuinely
  /// wants silence can still drag all the way to 0, which is unchanged.
  public static let stopsWithoutZero: [Double] = [0.25, 0.5, 0.75, 1]

  /// Capture window either side of a stop — 3 percentage points, fork parity.
  public static let tolerance = 0.03

  /// Snaps to the nearest member of `stops` inside the window. `enabled == false`
  /// returns the value untouched (but still clamped).
  ///
  /// Clamping happens in BOTH modes and before anything else: this sits on the
  /// drag path, where the pointer routinely leaves the capsule, and the
  /// controllers downstream take 0…1. Order is observable — an overshoot far
  /// from every stop (e.g. −0.5) would survive a snap-then-clamp arrangement,
  /// which is why `clampHappensBeforeSnapping…` pins it.
  public static func snapped(
    _ value: Double,
    enabled: Bool,
    stops: [Double] = SliderSnap.stops
  ) -> Double {
    let clamped = min(max(value, 0), 1)
    guard enabled else { return clamped }
    guard let stop = stops.min(by: { abs($0 - clamped) < abs($1 - clamped) }) else { return clamped }
    return abs(stop - clamped) <= tolerance ? stop : clamped
  }

  /// Whole-percent text for the readout AND for the slider's accessibility
  /// value, so the number a sighted user reads and the number VoiceOver
  /// announces are produced by the same call.
  public static func percentText(_ value: Double) -> String {
    let clamped = min(max(value, 0), 1)
    return "\(Int((clamped * 100).rounded()))%"
  }
}
