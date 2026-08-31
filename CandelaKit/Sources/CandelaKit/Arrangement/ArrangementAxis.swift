import Foundation

/// Axis projection for display rects, in one copy: a second lets two policies
/// disagree about which edge they mean, and that surfaces as a whole-display offset
/// with no obvious cause. Named `start`/`end`/`length` because `DisplayRect` already
/// has `origin` and `maxX`.
extension DisplayRect {
  func start(on axis: SnapAxis) -> Int { axis == .x ? x : y }

  func end(on axis: SnapAxis) -> Int { axis == .x ? maxX : maxY }

  func length(on axis: SnapAxis) -> Int { axis == .x ? width : height }

  /// Floored through `ArrangementSnapper.halved` so an odd extent biases the same
  /// way everywhere. This is the snapper's centre-alignment GUIDE position, NOT its
  /// centre-alignment target `sourceOrigin + halved(source.length - movingExtent)`,
  /// which answers where a second rect comes to rest.
  func centre(on axis: SnapAxis) -> Int {
    start(on: axis) + ArrangementSnapper.halved(length(on: axis))
  }

  /// Size untouched: every policy here moves displays and none resizes one.
  func placing(on axis: SnapAxis, at value: Int) -> DisplayRect {
    axis == .x
      ? DisplayRect(x: value, y: y, width: width, height: height)
      : DisplayRect(x: x, y: value, width: width, height: height)
  }

  /// Nonzero overlap. Touching ends do not count, which is what makes a shared edge
  /// adjacency rather than overlap.
  func spansOverlap(with other: DisplayRect, on axis: SnapAxis) -> Bool {
    Self.spansOverlap(
      start(on: axis), end(on: axis), other.start(on: axis), other.end(on: axis)
    )
  }
}
