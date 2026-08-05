import CoreGraphics
import Foundation

/// What a drag is asking for, at one instant.
///
/// **AR3.** This is the value the canvas renders mid-drag AND the value it
/// commits on release — the same instance, not a recomputation from the same
/// inputs. "It snapped somewhere other than the preview showed" is then not a
/// reachable state rather than merely an unlikely one.
public struct ArrangementProposal: Sendable, Equatable {
  /// The dragged tile moved AND snapped, in the baseline's display space.
  public let arrangement: DisplayArrangement
  /// The layout the drag started from (AR2's baseline, frozen for its duration).
  ///
  /// Carried so the proposal can answer whether it asks for anything.
  /// `ArrangementPreviewSession.begin` REFUSES a no-op with `.illegalArgument`,
  /// and a caller that compared `arrangement` against the *live* layout instead
  /// would be asking a different question: the live layout can have changed
  /// under the drag, and then a gesture that moved nothing would look like a
  /// request and a gesture that moved something could look like a no-op.
  public let baseline: DisplayArrangement
  public let movedID: CGDirectDisplayID
  /// Guides to draw. At most one per axis.
  public let lines: [SnapLine]
  /// Every display named in a problem, not only the dragged one (§3.5): moving
  /// the middle display of a row strands the far one, and the user has to see
  /// which displays they broke.
  public let problems: [ArrangementProblem]

  public init(
    arrangement: DisplayArrangement,
    baseline: DisplayArrangement,
    movedID: CGDirectDisplayID,
    lines: [SnapLine],
    problems: [ArrangementProblem]
  ) {
    self.arrangement = arrangement
    self.baseline = baseline
    self.movedID = movedID
    self.lines = lines
    self.problems = problems
  }

  public var isValid: Bool { problems.isEmpty }

  /// False when the drag ended where it started. Separate from `isValid`,
  /// because a no-op is perfectly valid — it is the layout that was already on
  /// screen — so validity alone never tells a caller there is something to do.
  public var changesArrangement: Bool { arrangement != baseline }

  /// The one question a drop has to ask. Both halves are required: an invalid
  /// proposal springs back (AR7) and a no-op is refused by the preview session.
  public var isCommittable: Bool { isValid && changesArrangement }
}

/// The drag decision (drag-canvas §2.4). Pure, and the only place a dragged
/// display's new origin is ever computed.
public enum ArrangementDragPolicy {
  /// Authored in **canvas** points, so magnetism feels the same at every zoom
  /// (§3.3). A fixed display-point threshold would be enormous on a zoomed-out
  /// three-display map and invisible on a two-display one.
  public static let snapThresholdCanvasPoints: Double = 8

  /// - Parameters:
  ///   - baseline: the arrangement as of drag **start**, never the live one.
  ///     `translation` is measured from the same instant, so folding this
  ///     function's own output back in would apply the move again on every
  ///     frame.
  ///   - transform: **frozen** at drag start (AR2). It is fitted to the
  ///     arrangement's bounds, which the dragged tile changes, so recomputing it
  ///     here would rescale the whole map under the pointer every frame. This
  ///     function does not recompute it, and takes it as a parameter so it
  ///     cannot.
  /// - Returns: `nil` only when `baseline` has no tile for `id` — a drag of a
  ///   display that is not in the layout. An invalid proposal is still
  ///   RETURNED, with `isValid == false`: the user has to see where they are,
  ///   and AR7 makes the canvas spring the tile back rather than making the
  ///   policy refuse to answer.
  public static func propose(
    dragging id: CGDirectDisplayID,
    by translation: CanvasPoint,
    from baseline: DisplayArrangement,
    transform: CanvasTransform,
    snapThreshold: Double = snapThresholdCanvasPoints
  ) -> ArrangementProposal? {
    guard let tile = baseline.tile(id) else { return nil }

    // §1.5 — ONE rounding, on the translation, against a rect captured at drag
    // start. Converting the gesture's start point and current point separately
    // and subtracting rounds twice, which lets a tile drift a point per gesture
    // without the pointer having moved that far; the drift accumulates over a
    // session and never self-corrects.
    let moved = tile.rect.offset(
      dx: transform.displayDistance(translation.x),
      dy: transform.displayDistance(translation.y)
    )

    // At least 1: on a map zoomed in far enough that 8 canvas points is under
    // half a display point, a threshold of 0 would admit only an exact hit and
    // snapping would appear to stop working.
    let threshold = max(1, transform.displayDistance(snapThreshold))
    let snapped = ArrangementSnapper.snap(
      moved, id: id, against: baseline.tiles, threshold: threshold
    )

    let arrangement = baseline.moving(id, to: snapped.rect.origin)
    return ArrangementProposal(
      arrangement: arrangement,
      baseline: baseline,
      movedID: id,
      lines: snapped.lines,
      problems: ArrangementRules.problems(in: arrangement)
    )
  }
}
