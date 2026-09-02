import CoreGraphics
import Foundation

/// Where a drop goes when the position under the pointer is not one the display can
/// stay in.
///
/// Kept apart from the proposal's own `arrangement`, which is where the display IS
/// and has to track the pointer. One `propose` call returns both, so they cannot
/// drift, which is what the single-return contract protects.
///
/// **Both gestures land rather than move live.** An insert that rearranged the map
/// under the pointer was disorienting: displays the user was not touching slid about
/// while they were still deciding. Nothing moves now until the release.
public struct ArrangementLanding: Sendable, Equatable {
  /// Legal by construction: the attach and insert policies return only
  /// problem-free arrangements, so nothing downstream re-checks one.
  public let arrangement: DisplayArrangement
  /// The edges it comes to rest against, drawn while the drag is still running so
  /// the landing is visible before the release.
  public let lines: [SnapLine]

  public init(arrangement: DisplayArrangement, lines: [SnapLine]) {
    self.arrangement = arrangement
    self.lines = lines
  }
}

/// What a drag is asking for, at one instant.
///
/// **The single-return contract.** It carries what to draw, what to apply, and
/// whether applying it is legal, so a release computes nothing and commits the
/// value that was on screen.
/// "It snapped somewhere other than the preview showed" then takes a caller that
/// recomputes on purpose instead of falling out of two paths drifting.
public struct ArrangementProposal: Sendable, Equatable {
  /// The dragged tile moved AND snapped, in the baseline's display space.
  public let arrangement: DisplayArrangement
  /// The layout the drag started from, frozen for its duration.
  ///
  /// Carried so the proposal can answer whether it asks for anything, which
  /// `ArrangementPreviewSession.begin` needs to refuse a no-op. Comparing against the
  /// LIVE layout asks a different question: it can have changed under the drag, and
  /// then a gesture that moved nothing reads as a request and vice versa.
  public let baseline: DisplayArrangement
  public let movedID: CGDirectDisplayID
  /// Guides to draw. At most one per axis.
  public let lines: [SnapLine]
  /// Every display named in a problem, not only the dragged one (§3.5): moving the
  /// middle display of a row strands the far one.
  public let problems: [ArrangementProblem]
  /// Where a release puts the display when `arrangement` itself cannot be committed.
  /// `nil` for a drop with nothing to salvage: an overlap (the canvas springs
  /// those back), or a layout of one display.
  public let landing: ArrangementLanding?

  public init(
    arrangement: DisplayArrangement,
    baseline: DisplayArrangement,
    movedID: CGDirectDisplayID,
    lines: [SnapLine],
    problems: [ArrangementProblem],
    landing: ArrangementLanding? = nil
  ) {
    self.arrangement = arrangement
    self.baseline = baseline
    self.movedID = movedID
    self.lines = lines
    self.problems = problems
    self.landing = landing
  }

  public var isValid: Bool { problems.isEmpty }

  /// False when the drag ended where it started. Separate from `isValid` because a
  /// no-op is perfectly valid, so validity alone never says there is something to do.
  public var changesArrangement: Bool { arrangement != baseline }

  /// What a release should apply, or `nil` when it should apply nothing.
  ///
  /// The landing wins when there is one, safe only because `propose` builds one only
  /// for drops the rendered arrangement cannot answer for. A landing that could also
  /// exist for a legal drop would commit something other than what the canvas drew,
  /// which is the state the single-return contract makes unreachable. A
  /// landing equal to the baseline is no commitment: the preview session
  /// refuses a no-op.
  public var commitment: DisplayArrangement? {
    if let landing { return landing.arrangement == baseline ? nil : landing.arrangement }
    return isValid && changesArrangement ? arrangement : nil
  }

  /// The one question a drop has to ask. An overlap springs back, a no-op is
  /// refused, and a drop into open space has somewhere to go.
  public var isCommittable: Bool { commitment != nil }
}

/// The drag decision (drag-canvas §2.4). The only place a dragged display's new
/// origin is computed.
public enum ArrangementDragPolicy {
  /// **Canvas** points, so magnetism feels the same at every zoom (§3.3). A fixed
  /// display-point threshold would be enormous on a zoomed-out three-display map and
  /// invisible on a two-display one.
  public static let snapThresholdCanvasPoints: Double = 8

  /// - Parameters:
  ///   - baseline: the arrangement as of drag **start**, never the live one.
  ///     `translation` is measured from the same instant, so feeding this function's
  ///     own output back in would apply the move again every frame.
  ///   - transform: **frozen** at drag start. It is fitted to the arrangement's
  ///     bounds, which the dragged tile changes, so recomputing it here would rescale
  ///     the map under the pointer every frame. Taken as a parameter so it cannot.
  /// - Returns: `nil` only when `baseline` has no tile for `id`. An invalid proposal
  ///   is still RETURNED with `isValid == false`, because the user has to see where
  ///   they are and the canvas springs the tile back.
  public static func propose(
    dragging id: CGDirectDisplayID,
    by translation: CanvasPoint,
    from baseline: DisplayArrangement,
    transform: CanvasTransform,
    snapThreshold: Double = snapThresholdCanvasPoints
  ) -> ArrangementProposal? {
    guard let tile = baseline.tile(id) else { return nil }

    // §1.5: ONE rounding, on the translation, against a rect captured at drag start.
    // Converting start and current separately and subtracting rounds twice, which
    // drifts a tile a point per gesture and never self-corrects.
    let moved = tile.rect.offset(
      dx: transform.displayDistance(translation.x),
      dy: transform.displayDistance(translation.y)
    )

    // §3.3's floor, earning its keep twice. Zoomed in far enough that the threshold
    // is worth under half a display point, the conversion rounds to 0 and admits only
    // an exact hit; 1 keeps the one point of tolerance display space has to give. It
    // also holds a negative `snapThreshold`, which would admit nothing at all.
    let threshold = max(1, transform.displayDistance(snapThreshold))
    let snapped = ArrangementSnapper.snap(
      moved, id: id, against: baseline.tiles, threshold: threshold
    )

    // The rendered layout is ALWAYS the dragged display alone. Nothing else moves
    // during a drag, whichever gesture this turns out to be.
    let arrangement = baseline.moving(id, to: snapped.rect.origin)
    let problems = ArrangementRules.problems(in: arrangement)

    // A landing exists ONLY when the rendered drop cannot be committed as it stands,
    // so a drop legal exactly where the user let go commits there and nowhere else.
    // Run the insert branch unguarded and a drop that was legal AND happened
    // to straddle a seam renders clean, reddens nothing, then commits the display
    // somewhere the user never put it.
    var landing: ArrangementLanding?
    if !problems.isEmpty {
      // Decided from the PRE-snap rect and tried first, because ordinary snapping
      // cannot express an insert: it abuts the near display and lands on top of the
      // far one, which the canvas would spring back. `ArrangementInsertPolicy`
      // returns only legal layouts, so displays the user did not grab move
      // only into a result they can keep.
      if let insertion = ArrangementInsertPolicy.insertion(
           dragging: id, freeRect: moved, snappedRect: snapped.rect, into: baseline
         ),
         let guide = ArrangementInsertPolicy.guide(
           for: insertion.seam, rendered: snapped.rect, in: baseline
         )
      {
        landing = ArrangementLanding(arrangement: insertion.arrangement, lines: [guide])
      }
      // A drop that leaves a display touching nothing gets a landing rather than a
      // bare refusal. Overlaps that are not an insert still spring back: a
      // display dropped squarely on another names no particular layout.
      //
      // UNRESOLVED, recorded rather than fixed. The insert path re-anchors on
      // the display that was main; this branch does not, so an attach landing that
      // moves main off (0,0) commits a layout whose `mainDisplayID` is nil (main
      // is derived from the tile at the origin). Inherited, not introduced: an
      // ordinary legal drag of the main display already does this. Whether either
      // should re-anchor is a question about main derivation and the insert
      // path's re-anchor together.
      else if problems.allSatisfy(\.isDisconnection),
              let attachment = ArrangementAttachPolicy.attach(
                moved, id: id, in: baseline, threshold: threshold
              )
      {
        landing = ArrangementLanding(
          arrangement: baseline.moving(id, to: attachment.rect.origin),
          lines: [attachment.line]
        )
      }
    }

    // The rendered arrangement keeps its problems even when there is a landing: the
    // display is not legally where it is being drawn. The problems alone no longer
    // decide whether the tile reads as refused, so the canvas asks about the landing
    // before it reddens anything.
    return ArrangementProposal(
      arrangement: arrangement,
      baseline: baseline,
      movedID: id,
      lines: snapped.lines,
      problems: problems,
      landing: landing
    )
  }
}
