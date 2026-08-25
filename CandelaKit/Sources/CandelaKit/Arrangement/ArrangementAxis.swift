import Foundation

/// Axis projection for display rects.
///
/// One copy, for the reason `ArrangementSnapper.halved` already gives about
/// centring: a second copy of a projection lets two policies disagree about
/// which edge they mean, and the disagreement surfaces as a whole-display
/// offset with no obvious cause. The snapper, the insert policy and the attach
/// policy all reason one axis at a time, so they all read these.
///
/// Named `start`/`end`/`length` rather than `origin`/`maxEdge`/`extent` because
/// `DisplayRect` already has an `origin` property and a `maxX`.
extension DisplayRect {
  func start(on axis: SnapAxis) -> Int { axis == .x ? x : y }

  func end(on axis: SnapAxis) -> Int { axis == .x ? maxX : maxY }

  func length(on axis: SnapAxis) -> Int { axis == .x ? width : height }

  /// The centre, floored through `ArrangementSnapper.halved` so an odd extent
  /// biases the same way everywhere. It matches the snapper's centre-alignment
  /// GUIDE position, which is `sourceOrigin + halved(source.length)`: the same
  /// quantity on the same rect. It is NOT the snapper's centre-alignment
  /// target, which is `sourceOrigin + halved(source.length - movingExtent)` and
  /// answers a different question, where a second rect comes to rest.
  func centre(on axis: SnapAxis) -> Int {
    start(on: axis) + ArrangementSnapper.halved(length(on: axis))
  }

  /// The same rect with one axis's origin replaced. The size is untouched:
  /// every policy here moves displays and none resizes one.
  func placing(on axis: SnapAxis, at value: Int) -> DisplayRect {
    axis == .x
      ? DisplayRect(x: value, y: y, width: width, height: height)
      : DisplayRect(x: x, y: value, width: width, height: height)
  }

  /// Whether the two spans overlap on `axis` by a nonzero length. Touching ends
  /// do not count, which is what makes a shared edge adjacency rather than
  /// overlap.
  func spansOverlap(with other: DisplayRect, on axis: SnapAxis) -> Bool {
    Self.spansOverlap(
      start(on: axis), end(on: axis), other.start(on: axis), other.end(on: axis)
    )
  }
}
