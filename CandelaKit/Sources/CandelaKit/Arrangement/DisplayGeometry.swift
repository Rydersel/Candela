import Foundation

/// A point in **display space**: integral, y-**down**, origin at the top-left of
/// the main display (AR1). This is `CGDisplayBounds`' space, never
/// `NSScreen.frame`'s y-up one — mixing the two draws a display above its
/// neighbour on the map and below it in reality.
public struct DisplayPoint: Sendable, Equatable, Hashable {
  public var x: Int
  public var y: Int

  public init(x: Int, y: Int) {
    self.x = x
    self.y = y
  }

  public static let zero = DisplayPoint(x: 0, y: 0)
}

/// A display's rect in display space. Integers make equality exact, kill float
/// drift in snapping, and match `CGConfigureDisplayOrigin`'s `int32_t` (AR1).
public struct DisplayRect: Sendable, Equatable, Hashable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = max(0, width)
    self.height = max(0, height)
  }

  public var origin: DisplayPoint { DisplayPoint(x: x, y: y) }
  public var maxX: Int { x + width }
  public var maxY: Int { y + height }
  public var isEmpty: Bool { width == 0 || height == 0 }

  public func moved(to origin: DisplayPoint) -> DisplayRect {
    DisplayRect(x: origin.x, y: origin.y, width: width, height: height)
  }

  public func offset(dx: Int, dy: Int) -> DisplayRect {
    DisplayRect(x: x + dx, y: y + dy, width: width, height: height)
  }

  /// Strictly positive interior intersection. A shared edge is NOT overlap —
  /// it is the only legal way for two displays to meet.
  public func overlaps(_ other: DisplayRect) -> Bool {
    x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
  }

  /// Share a boundary segment of nonzero length. Corner-only contact is
  /// deliberately NOT adjacency.
  public func touches(_ other: DisplayRect) -> Bool {
    let verticalEdge = (maxX == other.x || other.maxX == x)
      && Self.spansOverlap(y, maxY, other.y, other.maxY)
    let horizontalEdge = (maxY == other.y || other.maxY == y)
      && Self.spansOverlap(x, maxX, other.x, other.maxX)
    return verticalEdge || horizontalEdge
  }

  static func spansOverlap(_ aMin: Int, _ aMax: Int, _ bMin: Int, _ bMax: Int) -> Bool {
    max(aMin, bMin) < min(aMax, bMax) // strict: touching ends do not overlap
  }

  public static func union(_ rects: [DisplayRect]) -> DisplayRect? {
    guard let first = rects.first else { return nil }
    var minX = first.x, minY = first.y
    var maxX = first.maxX, maxY = first.maxY
    for rect in rects.dropFirst() {
      minX = min(minX, rect.x)
      minY = min(minY, rect.y)
      maxX = max(maxX, rect.maxX)
      maxY = max(maxY, rect.maxY)
    }
    return DisplayRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}
