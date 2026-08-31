import Foundation

/// The factor sequence a lock dim fades through, and the cadence it walks them
/// at.
///
/// **Dim-in only.** The restore is a single immediate write: someone who has
/// just unlocked wants their screen back now. Nothing here is reachable from
/// the restore path.
///
/// **Scope is lock dim**, not a general smooth-fade engine. This is a pure
/// sequence over a 0...1 multiplier, with no easing curve and no from-value.
public enum LockDimRamp {
  /// 24 steps over 1.2 s, 50 ms apart.
  ///
  /// A DDC transaction costs ~20 ms, more on retries, so a shorter interval
  /// lets the latest-wins coalescer drop intermediate steps and the fade
  /// degrades to a jump. An OLED panel also bands visibly on too few steps: a
  /// dim from 100 to 50 on a 0...100 register is about two register units per
  /// step at 24.
  ///
  /// NOT visually verified on the MAG; that needs a locked screen and eyes on
  /// the panel.
  public static let steps = 24
  public static let stepInterval: Duration = .milliseconds(50)
  public static var duration: Duration { stepInterval * steps }

  /// The factors to walk, in order, ending EXACTLY at `target`. Linear in the
  /// factor, so linear in the value written; no perceptual easing, because a
  /// wrong curve is worse than none.
  ///
  /// Empty when there is nothing to fade to (a target at or above 1), so a
  /// caller cannot walk a sequence that ends brighter than it started.
  public static func factors(to target: Double) -> [Double] {
    let clamped = min(max(target, 0), 1)
    guard clamped < 1 else { return [] }
    return (1 ... steps).map { step in
      1 + (clamped - 1) * (Double(step) / Double(steps))
    }
  }
}
