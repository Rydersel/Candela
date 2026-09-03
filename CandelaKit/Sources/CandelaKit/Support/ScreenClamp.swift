import CoreGraphics

/// One axis of keeping something on screen. Scalar because the HUD pill clamps
/// x against the visible frame and y against the full frame; a rect rule cannot.
enum ScreenClamp {
  /// Near edge of a span of `length`, held inside `lower...upper`. The inner `max`
  /// covers a span longer than its screen: without it the upper bound drops below
  /// the lower one and the span lands off the near edge instead of pinned to it.
  static func clamped(_ value: CGFloat, length: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
    min(max(value, lower), max(lower, upper - length))
  }
}
