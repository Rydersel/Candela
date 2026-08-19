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

  public init(arrangement: DisplayArrangement, seam: ArrangementSeam, push: Int) {
    self.arrangement = arrangement
    self.seam = seam
    self.push = push
  }
}

/// Dropping a display onto the boundary between two others puts it there and
/// moves the displays beyond that boundary out of its way.
///
/// **This is one of AR7's two amendments** (invalid drops are refused and sprung
/// back, never auto-corrected). The other is AR15's attach landing, which
/// replaces a spring-back with a nearest legal position; anything calling the
/// insert the only amendment is out of date. AR7's argument is that macOS
/// silently fixes overlaps to somewhere of its own choosing, so a silent
/// correction teaches the user that the map lies. An insert is not silent, but
/// after AR16 the reason is no longer that the result is drawn live: nothing
/// but the dragged display moves before the release. What keeps it honest
/// instead is that covering a seam names one layout and no other, that the seam
/// guide is drawn on the seam the release will use while the drag is still
/// running, and that AR8's countdown still defaults to revert. So the
/// correction is announced before it happens, and it is reversible after. AR7
/// still governs every other overlap, including a display dropped squarely on
/// top of another, where the intent genuinely is ambiguous.
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
  /// - Returns: `nil` when the drag is not covering a seam, or when no seam it
  ///   covers yields a layout that can be kept. Every insertion returned is
  ///   legal by construction, so callers do not re-check it.
  public static func insertion(
    dragging id: CGDirectDisplayID,
    freeRect: DisplayRect,
    snappedRect: DisplayRect,
    into baseline: DisplayArrangement
  ) -> ArrangementInsertion? {
    let others = baseline.tiles.filter { $0.id != id }
    // A seam needs two displays that are not the one being dragged.
    guard others.count > 1 else { return nil }

    // Ranked once, then WALKED until one is legal, which is the shape
    // `ArrangementAttachPolicy.attach` already uses and for the same reason.
    // Ranking once and taking the winner threw legal inserts away: a randomized
    // probe found a lower-ranked seam giving a fully valid layout in 7.8% of
    // the situations where any legal insert existed, and in every one of those
    // the user saw a spring-back instead of the layout they had asked for.
    for seam in [SnapAxis.x, .y]
      .flatMap({ candidateSeams(on: $0, freeRect: freeRect, others: others) })
      .sorted(by: { key($0, from: freeRect) < key($1, from: freeRect) })
    {
      let candidate = insertion(
        on: seam, dragging: id, freeRect: freeRect, snappedRect: snappedRect, into: baseline
      )
      guard ArrangementRules.problems(in: candidate.arrangement).isEmpty else { continue }
      return candidate
    }

    return nil
  }

  /// The layout one seam produces, legal or not. Only the walk above calls it,
  /// and only the walk decides whether the result may be kept.
  private static func insertion(
    on seam: ArrangementSeam,
    dragging id: CGDirectDisplayID,
    freeRect: DisplayRect,
    snappedRect: DisplayRect,
    into baseline: DisplayArrangement
  ) -> ArrangementInsertion {
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
    //
    // A baseline with NO tile at the origin skips AR14 entirely, and a push can
    // then move some display onto (0,0) and make it main without saying so.
    // Recorded rather than guarded: no path in the live app produces an
    // origin-less baseline. Tiles are read from `CGDisplayBounds`, whose space
    // is defined with the main display's top-left at the origin, and the saved
    // layouts round-trip those same origins. Writing a fallback would be
    // inventing behaviour for a state nothing can reach, and the invented
    // choice of which display to anchor on would be untestable against
    // anything real. If a source of tiles ever appears that can omit the
    // origin, this is the line that has to answer for it.
    if let main = baseline.mainDisplayID {
      arrangement = arrangement.makingMain(main)
    }

    return ArrangementInsertion(arrangement: arrangement, seam: seam, push: push)
  }

  /// The seam guide, in the coordinates the MAP is drawn in.
  ///
  /// It has to be built from the baseline rather than from the insertion's own
  /// arrangement. The canvas renders the dragged tile where the pointer is and
  /// holds the transform frozen on the baseline's bounds (AR2), while the
  /// insertion may have been re-anchored by a whole-layout translation (AR14).
  /// A guide taken from the re-anchored layout would be drawn that translation
  /// away from the seam it names.
  ///
  /// - Parameter rendered: the dragged display's rect as the map is drawing it.
  ///   The guide spans it and the display it will come to rest against, which is
  ///   the same rule `ArrangementSnapper` uses for a snap guide.
  public static func guide(
    for seam: ArrangementSeam,
    rendered: DisplayRect,
    in baseline: DisplayArrangement
  ) -> SnapLine? {
    guard let near = baseline.tile(seam.nearID) else { return nil }
    let across = seam.axis.other
    return SnapLine(
      axis: seam.axis,
      position: seam.position,
      kind: .abut,
      otherDisplayID: seam.nearID,
      from: min(rendered.start(on: across), near.rect.start(on: across)),
      to: max(rendered.end(on: across), near.rect.end(on: across))
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
  /// `gap` sorts ascending as the first tie-break. A row of three offers a seam
  /// between its OUTER two as well, straight through the middle display, and
  /// that seam shares its position with the near pair's: same distance, so
  /// nothing else in the key separates them. Its gap is always the wider one,
  /// because it contains the middle display and then some, so ascending gap
  /// puts the seam that is actually free ahead of the corridor something is
  /// already standing in. What the term decides is which seam is REPORTED and
  /// tried first, and the reported seam is what the guide names and what a bug
  /// report has to be able to cite. It can no longer decide the resulting
  /// LAYOUT for two seams sharing a position: they push the same set of
  /// displays, so they differ only in how far, and the wider gap always
  /// under-pushes into an overlap whenever it differs at all. Pinned by
  /// `tiesAtOneSeamPositionGoToTheTighterSeam`, which is built so that both
  /// candidates are legal and only the reported seam separates them.
  ///
  /// A corridor-occupancy test was written here and then deleted, on the
  /// argument that in an overlap-free layout a display blocking the corridor
  /// between two others necessarily forms a narrower seam with the same near
  /// display, so ascending gap already excluded it. **That argument is false.**
  /// Cross-axis overlap is not transitive. With 1 at (0,0,100,100), 2 at
  /// (300,0,100,100) and 3 at (0,100,400,100), display 3 sits squarely in the
  /// corridor between 1 and 2 while sharing no y span with 1, so it forms no
  /// seam with 1 at all and no ranking on gap can see it. What actually keeps a
  /// blocked corridor from costing a legal insert is the walk in `insertion`,
  /// which moves on to the next seam when the chosen one's layout has problems.
  /// Do not restore the check: the walk covers it, and a second gate would only
  /// be a second place for the two to disagree.
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
}
