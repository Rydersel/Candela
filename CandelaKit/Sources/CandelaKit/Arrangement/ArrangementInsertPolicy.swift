import CoreGraphics
import Foundation

/// The boundary an insert opens: two displays facing each other across a gap of
/// zero or more points, sharing enough span on the other axis for something
/// dropped between them to abut both.
public struct ArrangementSeam: Sendable, Equatable {
  /// The axis the inserted display displaces along. `.x` is the vertical seam
  /// between a left-hand and a right-hand display.
  public let axis: SnapAxis
  /// Where the inserted display's leading edge lands: the near display's far
  /// edge.
  public let position: Int
  /// Points already free between the two. Zero when they abut.
  public let gap: Int
  /// The display on the low side of the seam. It never moves.
  public let nearID: CGDirectDisplayID
  /// The display on the high side. It moves by `ArrangementInsertion.push`.
  public let farID: CGDirectDisplayID

  public init(
    axis: SnapAxis,
    position: Int,
    gap: Int,
    nearID: CGDirectDisplayID,
    farID: CGDirectDisplayID
  ) {
    self.axis = axis
    self.position = position
    self.gap = gap
    self.nearID = nearID
    self.farID = farID
  }
}

public struct ArrangementInsertion: Sendable, Equatable {
  /// Every display's origin, the displaced ones included (AR4).
  public let arrangement: DisplayArrangement
  public let seam: ArrangementSeam
  /// How far each display beyond the seam moved. Zero when the gap was already
  /// wide enough to hold the inserted display, which is the case where an
  /// insert disturbs nothing.
  public let push: Int
  /// Guides to draw, same contract as `SnapResult.lines`: at most one per axis,
  /// X before Y.
  public let lines: [SnapLine]

  public init(
    arrangement: DisplayArrangement,
    seam: ArrangementSeam,
    push: Int,
    lines: [SnapLine]
  ) {
    self.arrangement = arrangement
    self.seam = seam
    self.push = push
    self.lines = lines
  }
}

/// Dropping a display onto the boundary between two others puts it there and
/// moves the displays beyond that boundary out of its way.
///
/// **This is the one amendment to AR7** (invalid drops are refused and sprung
/// back, never auto-corrected). AR7's argument is that macOS silently fixes
/// overlaps to somewhere of its own choosing, so a silent correction teaches the
/// user that the map lies. An insert is not that: the user covered a seam with a
/// display, which names one layout and no other, and the whole result is drawn
/// live before the drop commits (AR3), so nothing about it is silent. AR7 still
/// governs every other overlap, including a display dropped squarely on top of
/// another, where the intent genuinely is ambiguous.
///
/// Pure, and deliberately separate from `ArrangementSnapper`: the snapper moves
/// one display and this moves several, so keeping them apart is what lets a test
/// say which of the two decided a layout.
public enum ArrangementInsertPolicy {
  /// - Parameters:
  ///   - freeRect: the dragged display's rect BEFORE snapping. Detection reads
  ///     this rather than the snapped rect because snapping has usually already
  ///     pulled the display onto the seam it is straddling, and a rect whose
  ///     leading edge sits exactly on the seam no longer straddles it. Reading
  ///     the pre-snap rect keeps the question non-circular, the same discipline
  ///     `ArrangementSnapper` applies to its crossing precondition.
  ///   - snappedRect: the result of ordinary snapping. Only its OTHER-axis
  ///     coordinate is used: an insert fixes the seam axis exactly and leaves
  ///     the cross axis to the snapper, so the two compose instead of competing.
  /// - Returns: `nil` when the drag is not covering a seam, which is every drag
  ///   that is not an insert.
  public static func insertion(
    dragging id: CGDirectDisplayID,
    freeRect: DisplayRect,
    snappedRect: DisplayRect,
    into baseline: DisplayArrangement
  ) -> ArrangementInsertion? {
    let others = baseline.tiles.filter { $0.id != id }
    // A seam needs two displays that are not the one being dragged.
    guard others.count > 1 else { return nil }

    let seams = [SnapAxis.x, .y].flatMap {
      candidateSeams(on: $0, freeRect: freeRect, others: others)
    }
    guard let seam = seams.min(by: { key($0, from: freeRect) < key($1, from: freeRect) })
    else { return nil }

    let axis = seam.axis
    let push = max(0, freeRect.length(on: axis) - seam.gap)
    let placed = snappedRect.placing(on: axis, at: seam.position)

    let moved = baseline.tiles.map { tile -> ArrangementTile in
      if tile.id == id { return tile.moved(to: placed.origin) }
      // Everything from the seam outwards, not only the far display: a display
      // is inserted into a ROW, and pushing the far display into its own
      // neighbour would trade one overlap for another. Tiles on the near side
      // keep their origins, so the layout the user was looking at stays put on
      // the half they were not pointing at.
      guard tile.rect.start(on: axis) >= seam.position else { return tile }
      return axis == .x ? tile.offset(dx: push, dy: 0) : tile.offset(dx: 0, dy: push)
    }

    var arrangement = DisplayArrangement(tiles: moved)

    // AR5 derives the main display from the tile at (0,0), so a push that moves
    // that tile silently hands "main" to whichever display lands on the origin.
    // Inserting to the LEFT of the main display would otherwise make the
    // inserted display main, which is a change the user did not ask for and
    // cannot see on the map. Re-anchoring is a pure translation, so it cannot
    // alter relative geometry: the layout is the same one, described from the
    // same display.
    //
    // Only the insert path does this. An ordinary drag of the main display
    // leaves no tile at the origin today, and changing that is a separate
    // question from this one.
    if let main = baseline.mainDisplayID {
      arrangement = arrangement.makingMain(main)
    }

    guard let finalTile = arrangement.tile(id), let near = arrangement.tile(seam.nearID)
    else { return nil }

    // Rebuilt from the FINAL arrangement, because re-anchoring above may have
    // translated every coordinate the snapper's own lines were expressed in.
    let seamLine = line(
      axis: axis, moved: finalTile.rect, other: near.rect, otherID: near.id
    )
    // Threshold 0 admits only an exact hit, which is all that is wanted here:
    // the cross axis was already snapped, so a real alignment still registers
    // and a near miss correctly draws nothing.
    let crossLine = ArrangementSnapper.snap(
      finalTile.rect, id: id, against: arrangement.tiles, threshold: 0
    ).lines.first { $0.axis == axis.other }

    return ArrangementInsertion(
      arrangement: arrangement,
      seam: seam,
      push: push,
      lines: [
        axis == .x ? seamLine : crossLine,
        axis == .x ? crossLine : seamLine,
      ].compactMap { $0 }
    )
  }

  // MARK: - Seams

  private static func candidateSeams(
    on axis: SnapAxis,
    freeRect: DisplayRect,
    others: [ArrangementTile]
  ) -> [ArrangementSeam] {
    var result: [ArrangementSeam] = []

    for near in others {
      for far in others where far.id != near.id {
        let position = near.rect.end(on: axis)
        let gap = far.rect.start(on: axis) - position
        // Ordered, so each unordered pair is considered once per direction and
        // the pair that faces the wrong way is dropped rather than mirrored.
        // A negative gap is the two overlapping on this axis, which is not a
        // seam anything can be inserted into.
        guard gap >= 0 else { continue }
        // Two displays that never share a span on the other axis have no seam
        // between them: nothing dropped there could abut both.
        guard near.rect.spansOverlap(with: far.rect, on: axis.other) else { continue }

        // Covering the seam IS the gesture. Both comparisons are strict, so a
        // display merely touching the seam is an ordinary abut and stays with
        // the snapper.
        guard freeRect.start(on: axis) < position, position < freeRect.end(on: axis)
        else { continue }
        // And it has to reach both displays on the other axis, or a display
        // dragged along a row well above it would insert into that row.
        guard freeRect.spansOverlap(with: near.rect, on: axis.other),
              freeRect.spansOverlap(with: far.rect, on: axis.other)
        else { continue }

        result.append(
          ArrangementSeam(
            axis: axis, position: position, gap: gap, nearID: near.id, farID: far.id
          )
        )
      }
    }

    return result
  }

  /// Ranked by how far the dragged display's centre is from the seam, so the
  /// seam it is sitting most squarely over wins. The remaining terms make the
  /// order strict and total over a tile list with distinct ids: a seam decided
  /// by array order is not reproducible in a bug report.
  ///
  /// `gap` sorts ascending as the first tie-break, and it is load-bearing
  /// rather than cosmetic. A row of three offers a seam between its OUTER two
  /// as well, straight through the middle display, and that seam shares its
  /// position with the near pair's: same distance, so nothing else in the key
  /// separates them. Its gap is always the wider one, because it contains the
  /// middle display and then some, so ascending gap is what keeps an insert
  /// from being measured against a corridor something is already standing in.
  ///
  /// A corridor-occupancy test was written here and then removed: in a layout
  /// with no overlaps, a display blocking the corridor between two others
  /// necessarily forms a narrower seam with the same near display, so the test
  /// could never reject a seam this ranking would have chosen. Picking the wide
  /// seam anyway would only under-push, and `ArrangementRules` refuses the
  /// result, so the failure is caught rather than applied.
  private static func key(
    _ seam: ArrangementSeam,
    from freeRect: DisplayRect
  ) -> (Int, Int, Int, CGDirectDisplayID, CGDirectDisplayID) {
    (
      abs(freeRect.centre(on: seam.axis) - seam.position),
      seam.gap,
      seam.axis == .x ? 0 : 1,
      seam.nearID,
      seam.farID
    )
  }

  private static func line(
    axis: SnapAxis,
    moved: DisplayRect,
    other: DisplayRect,
    otherID: CGDirectDisplayID
  ) -> SnapLine {
    let across = axis.other
    return SnapLine(
      axis: axis,
      position: other.end(on: axis),
      kind: .abut,
      otherDisplayID: otherID,
      from: min(moved.start(on: across), other.start(on: across)),
      to: max(moved.end(on: across), other.end(on: across))
    )
  }
}
