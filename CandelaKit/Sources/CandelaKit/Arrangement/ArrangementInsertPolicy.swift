import CoreGraphics
import Foundation

/// The boundary an insert opens: two displays facing each other across a gap of
/// zero or more points, sharing enough span on the other axis for something
/// dropped between them to abut both.
public struct ArrangementSeam: Sendable, Equatable {
  /// The axis the inserted display displaces along. `.x` is the vertical seam
  /// between a left-hand and a right-hand display.
  public let axis: SnapAxis
  /// Where the inserted display's leading edge lands: the near display's far edge.
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
  /// How far each display beyond the seam moved. Zero when the gap already held the
  /// inserted display, which is the insert that disturbs nothing.
  public let push: Int

  public init(arrangement: DisplayArrangement, seam: ArrangementSeam, push: Int) {
    self.arrangement = arrangement
    self.seam = seam
    self.push = push
  }
}

/// Dropping a display onto the boundary between two others puts it there and moves
/// the displays beyond that boundary out of its way.
///
/// **One of AR7's two amendments** (invalid drops spring back, never auto-correct);
/// the other is AR15's attach landing. AR7's argument is that macOS silently fixes
/// overlaps to somewhere of its own choosing, which teaches the user that the map
/// lies. An insert is not silent: covering a seam names one layout and no other, the
/// guide is drawn on the seam the release will use, and AR8's countdown still
/// defaults to revert. AR7 still governs every other overlap, including a display
/// dropped squarely on top of another, where the intent really is ambiguous.
///
/// Separate from `ArrangementSnapper` so a test can say which of the two decided a
/// layout: the snapper moves one display, this moves several.
public enum ArrangementInsertPolicy {
  /// - Parameters:
  ///   - freeRect: the dragged rect BEFORE snapping. Snapping has usually already
  ///     pulled the display onto the seam it straddles, and a rect whose leading edge
  ///     sits exactly on the seam no longer straddles it, so reading the pre-snap
  ///     rect keeps the question non-circular.
  ///   - snappedRect: only its OTHER-axis coordinate is used. An insert fixes the
  ///     seam axis and leaves the cross axis to the snapper, so the two compose.
  /// - Returns: `nil` when the drag covers no seam, or no seam it covers yields a
  ///   keepable layout. Every insertion returned is legal by construction.
  public static func insertion(
    dragging id: CGDirectDisplayID,
    freeRect: DisplayRect,
    snappedRect: DisplayRect,
    into baseline: DisplayArrangement
  ) -> ArrangementInsertion? {
    // Without this the seam walk still runs and hands back an insertion that pushes
    // the far side and contains no dragged display, applied without a re-check.
    // Unreachable from the app, but this function is public.
    guard baseline.tile(id) != nil else { return nil }

    let others = baseline.tiles.filter { $0.id != id }
    // A seam needs two displays that are not the one being dragged.
    guard others.count > 1 else { return nil }

    // Ranked once, then WALKED until one is legal, the shape
    // `ArrangementAttachPolicy.attach` uses for the same reason. Taking the top rank
    // and stopping throws legal inserts away: a lower-ranked seam can be the only one
    // yielding a valid layout, and the user then sees a spring-back instead.
    for seam in [SnapAxis.x, .y]
      .flatMap({
        candidateSeams(on: $0, freeRect: freeRect, snappedRect: snappedRect, others: others)
      })
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

  /// The layout one seam produces, legal or not. Only the walk above decides whether
  /// a result may be kept.
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
      // Everything from the seam outwards, not only the far display: pushing the far
      // display into its own neighbour trades one overlap for another. Near-side
      // tiles keep their origins.
      guard tile.rect.start(on: axis) >= seam.position else { return tile }
      return axis == .x ? tile.offset(dx: push, dy: 0) : tile.offset(dx: 0, dy: push)
    }

    var arrangement = DisplayArrangement(tiles: moved)

    // AR5 derives the main display from the tile at (0,0), so a push that moves that
    // tile hands "main" to whichever display lands on the origin. Inserting to the
    // LEFT of main would otherwise make the inserted display main, a change the user
    // did not ask for and cannot see. Re-anchoring is a pure translation, so relative
    // geometry is untouched. Only the insert path does this; an ordinary drag of the
    // main display leaves no tile at the origin.
    //
    // A baseline with NO tile at the origin skips AR14, and a push can then make some
    // display main silently. Recorded rather than guarded: tiles come from
    // `CGDisplayBounds`, whose space puts the main display's top-left at the origin,
    // and saved layouts round-trip those origins, so nothing reaches that state. If a
    // source of tiles that can omit the origin ever appears, this is the line.
    if let main = baseline.mainDisplayID {
      arrangement = arrangement.makingMain(main)
    }

    return ArrangementInsertion(arrangement: arrangement, seam: seam, push: push)
  }

  /// The seam guide, in the coordinates the MAP is drawn in.
  ///
  /// Built from the baseline, not the insertion's arrangement: the canvas holds the
  /// transform frozen on the baseline's bounds (AR2) while the insertion may have
  /// been re-anchored by a whole-layout translation (AR14), so a guide taken from the
  /// re-anchored layout would be drawn that translation away from the seam it names.
  ///
  /// - Parameter rendered: the dragged display's rect as the map is drawing it. The
  ///   guide spans it and the display it will rest against.
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
    snappedRect: DisplayRect,
    others: [ArrangementTile]
  ) -> [ArrangementSeam] {
    var result: [ArrangementSeam] = []

    for near in others {
      for far in others where far.id != near.id {
        let position = near.rect.end(on: axis)
        let gap = far.rect.start(on: axis) - position
        // Ordered, so each pair is considered once per direction. A negative gap is
        // the two overlapping on this axis, which is no seam at all.
        guard gap >= 0 else { continue }
        // No shared span on the other axis means nothing dropped there abuts both.
        guard near.rect.spansOverlap(with: far.rect, on: axis.other) else { continue }

        // Covering the seam IS the gesture. Strict, so a display merely touching the
        // seam is an ordinary abut and stays with the snapper.
        guard freeRect.start(on: axis) < position, position < freeRect.end(on: axis)
        else { continue }
        // It has to reach both on the other axis, or a display dragged along a row
        // well above this one would insert into it.
        guard freeRect.spansOverlap(with: near.rect, on: axis.other),
              freeRect.spansOverlap(with: far.rect, on: axis.other)
        else { continue }
        // Candidacy is judged on the pre-snap rect but the display LANDS on the
        // snapped one, and snapping can move it up to the threshold on the other
        // axis. Where that ends the shared span, the guide would draw a solid line
        // naming a boundary the release does not use, and AR13 rests on the guide
        // being truthful. Askable here because the placed rect takes its other-axis
        // coordinate from `snappedRect` unchanged.
        guard snappedRect.spansOverlap(with: near.rect, on: axis.other) else { continue }

        result.append(
          ArrangementSeam(
            axis: axis, position: position, gap: gap, nearID: near.id, farID: far.id
          )
        )
      }
    }

    return result
  }

  /// Ranked by how far the dragged display's centre is from the seam, so the seam it
  /// sits most squarely over wins. The remaining terms only make the order total: a
  /// seam decided by array order is not reproducible in a bug report.
  ///
  /// `gap` ascending is the first tie-break. A row of three also offers a seam
  /// between its OUTER two, straight through the middle display, sharing a position
  /// with the near pair's; its gap is always the wider one, so ascending gap reports
  /// the seam that is actually free ahead of the corridor something stands in.
  ///
  /// A corridor-occupancy test was written here on the argument that a display
  /// blocking the corridor necessarily forms a narrower seam with the same near
  /// display. **That argument is false**: cross-axis overlap is not transitive. With
  /// 1 at (0,0,100,100), 2 at (300,0,100,100) and 3 at (0,100,400,100), display 3
  /// blocks the corridor between 1 and 2 while sharing no y span with 1, so it forms
  /// no seam with 1 and no gap ranking can see it. The walk in `insertion` is what
  /// covers a blocked corridor. Do not restore the check; a second gate is only a
  /// second place for the two to disagree.
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
