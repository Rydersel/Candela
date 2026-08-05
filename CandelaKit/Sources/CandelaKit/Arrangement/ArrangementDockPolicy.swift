import CoreGraphics
import Foundation

/// Which way an arrow key asks a display to go, in **display space** — y-down,
/// so `.up` is toward smaller y (AR1).
public enum ArrangementDirection: Sendable, Equatable, Hashable, CaseIterable {
  case left, right, up, down

  /// Whether `destination` lies in this direction from `origin`. **Strict**: a
  /// position level with where the display already is does not count as being
  /// in any direction from it.
  ///
  /// That strictness carries two of this file's three guarantees. A move always
  /// changes the origin, because a candidate equal to it is excluded; and a
  /// walk terminates, because each press strictly advances one coordinate over
  /// a candidate set that does not change between presses.
  func leadsFrom(_ origin: DisplayPoint, to destination: DisplayPoint) -> Bool {
    switch self {
    case .left: destination.x < origin.x
    case .right: destination.x > origin.x
    case .up: destination.y < origin.y
    case .down: destination.y > origin.y
    }
  }
}

/// The keyboard equivalent of a drag (drag-canvas §7.3).
///
/// **This is the accessibility route to the canvas**, which is not otherwise
/// keyboard-reachable — the settings sidebar redesign already cost arrow-key
/// navigation once, and a drag-only arrangement UI would cost it again for the
/// one view in the app whose whole content is a pointer gesture.
///
/// Arrow keys do **not** nudge by a point. In a space where only touching,
/// non-overlapping layouts are legal (`ArrangementRules`), a one-point nudge
/// produces an invalid arrangement almost everywhere, so a nudging key would
/// mostly refuse or mostly lie. The keys walk the finite set of positions that
/// *are* legal instead.
public enum ArrangementDockPolicy {
  /// Every position where `id` can sit against another display and leave the
  /// **whole** arrangement legal.
  ///
  /// Four sides × three alignments (leading / centre / trailing) per other
  /// display, filtered through `ArrangementRules.isValid` and deduplicated —
  /// equally sized neighbours collapse all three alignments onto one point, and
  /// two neighbours can offer the same position.
  ///
  /// Validity is checked on the whole arrangement rather than on the moved
  /// display's own contact (§3.5): docking the middle display of a row against
  /// one end strands the other end, and a position that strands a display is
  /// not a position a key may put one in.
  ///
  /// Sorted by `(x, y)`, so the value is a function of the arrangement and not
  /// of the order its tiles were enumerated in.
  ///
  /// This filtering is what makes `move`'s guarantee structural rather than a
  /// discipline: `move` returns one of these positions or nothing, so it has no
  /// way to express an illegal layout.
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

  /// The nearest legal dock position lying in `direction` from where `id` is
  /// now, as a whole arrangement ready to apply.
  ///
  /// `nil` means there is nowhere to go — no legal position in that direction,
  /// or no such display in the layout. It is deliberately not distinguished
  /// further: the only caller leaves the keystroke unhandled either way, and a
  /// reason nobody reads is a reason that goes stale.
  ///
  /// A returned arrangement always DIFFERS from the one passed in, so a caller
  /// never has to filter a no-op out of the way of a preview session that
  /// refuses one.
  ///
  /// Ranked by **Manhattan distance**, with `(x, y)` breaking ties. Both halves
  /// are deliberate. The distance means "left" is the nearest legal position
  /// strictly to the left, which is not always the position on the left-hand
  /// side of the neighbour: stacking above a neighbour can be a shorter journey
  /// than crossing to its far side, and the first press then goes up-and-left.
  /// The tie-break makes the path reproducible, so a bug report can describe it.
  /// `theNearestPositionInTheDirectionWins` pins both, including the second
  /// press that does reach the far side.
  ///
  /// **Repeated presses terminate.** `dockPositions` reads only the other
  /// displays' rects, the moved display's SIZE, and — through
  /// `arrangement.moving(id, to:)` — a layout in which the moved display is at
  /// the candidate rather than where it came from. A move changes none of those
  /// (`DisplayRect.moved(to:)` keeps the size), so every press ranks the same
  /// finite set. Each press then lands strictly further along one axis, and a
  /// strictly monotone walk over a fixed finite set runs out.
  /// `repeatedPressesInOneDirectionTerminate` presses 50 times and requires a
  /// `nil`, which its fixtures — at most 12 candidates per neighbour, two
  /// neighbours — cannot outlast.
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

  /// Distance first, then the position itself. Dock positions are deduplicated,
  /// so `(x, y)` is unique among them and this is a strict total order.
  ///
  /// Those last two terms **cannot currently decide anything**, and the comment
  /// says so rather than claiming a guarantee no test can see:
  /// `dockPositions` already returns its result in ascending `(x, y)`, so the
  /// first minimal element `min(by:)` keeps is the one this tie-break would pick
  /// anyway. Deleting them changes no answer and a mutation pass proves it. They
  /// stay for `ArrangementSnapper.key`'s reason — the ordering has to remain
  /// total if that sort is ever changed or another caller ranks an unsorted
  /// list, and a ranking that depends on an ordering established in a different
  /// function is one refactor away from being decided by array order.
  private static func rank(_ point: DisplayPoint, from origin: DisplayPoint) -> (Int, Int, Int) {
    (abs(point.x - origin.x) + abs(point.y - origin.y), point.x, point.y)
  }

  /// Twelve candidate origins — four sides × three alignments — before any
  /// validity check. Fewer DISTINCT positions when the two displays match on an
  /// axis, where all three of that axis's alignments collapse onto one point;
  /// `dockPositions` dedupes. Sizes are never changed: docking moves a display,
  /// exactly as snapping does.
  private static func positions(
    docking moving: DisplayRect,
    against other: DisplayRect
  ) -> [DisplayPoint] {
    // `halved` is `ArrangementSnapper`'s, shared rather than reimplemented: a
    // centre dock and a centre snap must land on the same point, or an arrow
    // press and a drag would disagree by one point on every odd difference.
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
