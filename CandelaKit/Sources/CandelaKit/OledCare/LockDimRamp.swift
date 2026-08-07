import Foundation

/// The factor sequence a lock dim fades through, and the cadence it walks them
/// at.
///
/// **Dim-in only.** The restore is a single immediate write: someone who has
/// just unlocked wants their screen back now, and a fade there would be a
/// feature working against the user. Nothing here is reachable from the restore
/// path.
///
/// **Scope is lock dim.** A general smooth-fade engine is #78 and is NOT built
/// here. What that issue can reuse: this type is a pure sequence over a 0...1
/// multiplier and knows nothing about locking, and the mechanism underneath it
/// (`BrightnessController.rampTemporaryDim(to:)`) is expressed in temporary-dim
/// factors, which are already leg-agnostic. A general fade would want an easing
/// curve and a from-value, neither of which exists here.
public enum LockDimRamp {
  /// 24 steps over 1.2 s, 50 ms apart.
  ///
  /// The two constraints that picked these numbers. A DDC transaction costs
  /// ~20 ms and more on retries, so a step interval has to leave room for one
  /// to land or the coalescer (latest-wins) simply drops the intermediate steps
  /// and the fade degrades to a jump; 50 ms is over twice the transaction cost.
  /// And an OLED panel bands visibly on too few steps: across a typical dim
  /// from 100 to 50 on a 0...100 register, 24 steps is about two register units
  /// per step.
  ///
  /// NOT visually verified on the MAG. Verifying it needs a locked screen and
  /// eyes on the panel, which is a hardware-checklist item, not something the
  /// Kit can assert.
  public static let steps = 24
  public static let stepInterval: Duration = .milliseconds(50)
  public static var duration: Duration { stepInterval * steps }

  /// The factors to walk, in order, ending EXACTLY at `target`.
  ///
  /// Linear in the factor, which is linear in the value written. Perceptual
  /// easing is deliberately not attempted: it is a curve choice that belongs
  /// with #78's general fade, and a wrong curve is worse than none.
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
