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

  /// One discrete step from `value`, for the keyboard and VoiceOver routes.
  ///
  /// The drag path is continuous and only snaps inside `tolerance`; a stepping
  /// route has no such thing as "near a stop", so it cannot reuse `snapped` and
  /// must land ON the grid. Two grids, one rule: with `toStops` the grid is
  /// `stops`, without it the grid is the multiples of `step`. Either way the
  /// result is the next grid point strictly beyond `value` in the direction of
  /// travel, which is why a 62.5% slider steps to 60/65 rather than 57.5/67.5.
  ///
  /// **The zero-free grid is D29's enforcement point on this route.** When
  /// `stops` excludes 0 (`stopsWithoutZero`, the volume rows), 0 is not a grid
  /// point, so a decrement stops at the lowest one there is: 25% snapping,
  /// otherwise one `step`. Volume 0 is a hardware mute over VCP 0x8D, and
  /// decrement is the ONLY way a VoiceOver user can lower the volume, so this
  /// route reaching 0 would mute the display with no equivalent to the
  /// deliberate drag that mute is supposed to take. `snapped` cannot do this
  /// job: with `stopsWithoutZero` the nearest stop to 0.4 is 0.15 away, far
  /// outside `tolerance`, so it hands every value between the stops back
  /// untouched and a 5% walk-down reaches 0 unimpeded.
  ///
  /// A step never moves against its own direction. A value already below the
  /// grid's lowest point (a volume dragged to 0, or muted) therefore stays put
  /// on a decrement rather than being shoved up to the floor, which would
  /// unmute the display as a side effect of asking for less.
  public static func stepped(
    from value: Double,
    up: Bool,
    step: Double,
    toStops: Bool,
    stops: [Double] = SliderSnap.stops
  ) -> Double {
    let current = min(max(value, 0), 1)
    let grid = toStops ? nextStop(from: current, up: up, stops: stops) : nextMultiple(of: step, from: current, up: up)
    // The floor can only hold the value where it is, never raise it.
    let floor = min(zeroFreeFloor(step: step, toStops: toStops, stops: stops), current)
    let bounded = min(max(grid, floor), 1)
    return up ? max(bounded, current) : min(bounded, current)
  }

  /// 0 unless the grid excludes it, in which case the lowest point it has.
  private static func zeroFreeFloor(step: Double, toStops: Bool, stops: [Double]) -> Double {
    guard !stops.contains(0) else { return 0 }
    return toStops ? (stops.min() ?? 0) : abs(step)
  }

  private static func nextStop(from value: Double, up: Bool, stops: [Double]) -> Double {
    let beyond = up
      ? stops.filter { $0 > value + epsilon }.min()
      : stops.filter { $0 < value - epsilon }.max()
    // No stop beyond means the grid ends here: hold at its extreme rather than
    // running on to 0 or 1, which for `stopsWithoutZero` is the whole point.
    return beyond ?? (up ? (stops.max() ?? 1) : (stops.min() ?? 0))
  }

  /// Multiples of `step`, so a stepping route lands on round numbers (60%, 65%)
  /// wherever a drag left the value.
  private static func nextMultiple(of step: Double, from value: Double, up: Bool) -> Double {
    let size = abs(step)
    guard size > 0 else { return value }
    // Binary can put an exact multiple a hair under itself (0.6 / 0.05 is
    // 11.999999999999998), which without the nudge steps to 0.6 again.
    let quotient = value / size
    let index = up ? (quotient + epsilon).rounded(.down) + 1 : (quotient - epsilon).rounded(.up) - 1
    // Rounded back to whole millionths so repeated stepping cannot drift a
    // grid point into a number the readout renders as 59% or 61%.
    return ((index * size) * 1e6).rounded() / 1e6
  }

  /// Slack for the float noise above, far below one whole percent.
  private static let epsilon = 1e-6

  /// Whole-percent text for the readout AND for the slider's accessibility
  /// value, so the number a sighted user reads and the number VoiceOver
  /// announces are produced by the same call.
  public static func percentText(_ value: Double) -> String {
    let clamped = min(max(value, 0), 1)
    return "\(Int((clamped * 100).rounded()))%"
  }
}
