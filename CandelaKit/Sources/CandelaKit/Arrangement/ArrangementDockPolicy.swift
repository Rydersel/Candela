import CoreGraphics
import Foundation

/// Which way an arrow key asks a display to go, in **display space**: y-down, so
/// `.up` is toward smaller y (AR1).
public enum ArrangementDirection: Sendable, Equatable, Hashable, CaseIterable {
  case left, right, up, down

  /// Whether `destination` lies in this direction from `origin`. **Strict**: level
  /// with the current position counts as no direction at all, which is what makes a
  /// move always change the origin and a repeated walk terminate.
  func leadsFrom(_ origin: DisplayPoint, to destination: DisplayPoint) -> Bool {
    switch self {
    case .left: destination.x < origin.x
    case .right: destination.x > origin.x
    case .up: destination.y < origin.y
    case .down: destination.y > origin.y
    }
  }
}

/// The keyboard equivalent of a drag (drag-canvas §7.3), and the accessibility
/// route to a canvas that is not otherwise keyboard-reachable.
///
/// Arrow keys do **not** nudge by a point. Only touching, non-overlapping layouts
/// are legal (`ArrangementRules`), so a one-point nudge is invalid almost
/// everywhere. The keys walk the finite set of legal positions instead.
public enum ArrangementDockPolicy {
  /// Every position where `id` can sit against another display and leave the
  /// **whole** arrangement legal.
  ///
  /// Validity is checked on the whole arrangement rather than on the moved display's
  /// own contact (§3.5): docking the middle display of a row against one end strands
  /// the other end. Sorted by `(x, y)`, so the value does not depend on the order
  /// tiles were enumerated in.
  ///
  /// `move` returns one of these or nothing, so it has no way to express an illegal
  /// layout.
  public static func dockPositions(
    for id: CGDirectDisplayID,
    in arrangement: DisplayArrangement
  ) -> [DisplayPoint] {
    guard let moving = arrangement.tile(id)?.rect else { return [] }
    let candidates = Set(
      arrangement.tiles
        .filter { $0.id != id }
        .flatMap { positions(docking: moving, against: $0.rect) }
    )
    return candidates
      .filter { ArrangementRules.isValid(arrangement.moving(id, to: $0)) }
      .sorted { ($0.x, $0.y) < ($1.x, $1.y) }
  }

  /// The nearest legal dock position lying in `direction` from where `id` is now, as
  /// a whole arrangement ready to apply.
  ///
  /// `nil` means nowhere to go, undistinguished on purpose: the only caller leaves
  /// the keystroke unhandled either way. A returned arrangement always DIFFERS from
  /// the input, so no caller has to filter a no-op out of a preview session that
  /// refuses one.
  ///
  /// Ranked by **Manhattan distance**, `(x, y)` breaking ties. So "left" is the
  /// nearest legal position strictly to the left, which is not always the one on the
  /// neighbour's left-hand side: stacking above it can be the shorter journey.
  ///
  /// **Repeated presses terminate.** `dockPositions` reads only the other displays'
  /// rects and the moved display's size, neither of which a move changes, so every
  /// press ranks the same finite set and each lands strictly further along one axis.
  public static func move(
    _ id: CGDirectDisplayID,
    _ direction: ArrangementDirection,
    in arrangement: DisplayArrangement
  ) -> DisplayArrangement? {
    guard let from = arrangement.tile(id)?.rect.origin else { return nil }
    let destination = dockPositions(for: id, in: arrangement)
      .filter { direction.leadsFrom(from, to: $0) }
      .min { rank($0, from: from) < rank($1, from: from) }
    guard let destination else { return nil }
    return arrangement.moving(id, to: destination)
  }

  /// Distance first, then the position itself. The last two terms decide nothing
  /// today, because `dockPositions` already returns ascending `(x, y)`. They stay so
  /// the order is still total if that sort changes or another caller ranks an
  /// unsorted list.
  private static func rank(_ point: DisplayPoint, from origin: DisplayPoint) -> (Int, Int, Int) {
    (abs(point.x - origin.x) + abs(point.y - origin.y), point.x, point.y)
  }

  /// Twelve candidate origins (four sides by three alignments) before any validity
  /// check. Fewer DISTINCT ones when the two displays match on an axis, where that
  /// axis's three alignments collapse onto one point; `dockPositions` dedupes.
  private static func positions(
    docking moving: DisplayRect,
    against other: DisplayRect
  ) -> [DisplayPoint] {
    // Shared with `ArrangementSnapper` rather than reimplemented: a centre dock and a
    // centre snap must land on the same point, or an arrow press and a drag disagree
    // by one point on every odd difference.
    let alignedX = [
      other.x,
      other.x + ArrangementSnapper.halved(other.width - moving.width),
      other.maxX - moving.width,
    ]
    let alignedY = [
      other.y,
      other.y + ArrangementSnapper.halved(other.height - moving.height),
      other.maxY - moving.height,
    ]

    let besides = [other.x - moving.width, other.maxX]
      .flatMap { x in alignedY.map { DisplayPoint(x: x, y: $0) } }
    let aboveAndBelow = [other.y - moving.height, other.maxY]
      .flatMap { y in alignedX.map { DisplayPoint(x: $0, y: y) } }
    return besides + aboveAndBelow
  }
}
