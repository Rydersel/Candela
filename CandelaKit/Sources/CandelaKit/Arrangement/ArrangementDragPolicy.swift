import CoreGraphics
import Foundation

/// Where a drop goes when the position under the pointer is not one the
/// display can stay in.
///
/// Kept apart from the proposal's own `arrangement` because the two answer
/// different questions at the same instant: `arrangement` is where the display
/// IS, which has to track the pointer or the user finds out only on release,
/// and this is where it LANDS. One `propose` call returns both, so they cannot
/// drift, which is what AR3 is actually protecting.
///
/// **Both new gestures land rather than move live.** An insert was built to
/// rearrange the map under the pointer and was disorienting to use: displays
/// the user was not touching slid about while they were still deciding where to
/// drop. Neither gesture moves anything now until the release, and both say
/// what they will do with a guide.
public struct ArrangementLanding: Sendable, Equatable {
  /// A whole layout, legal by construction: `ArrangementAttachPolicy` returns
  /// only placements whose arrangement has no problems.
  public let arrangement: DisplayArrangement
  /// The edges it comes to rest against, drawn while the drag is still running
  /// so the landing is visible before the release rather than after it.
  public let lines: [SnapLine]

  public init(arrangement: DisplayArrangement, lines: [SnapLine]) {
    self.arrangement = arrangement
    self.lines = lines
  }
}

/// What a drag is asking for, at one instant.
///
/// **AR3.** It carries everything both ends of a drag need — what to draw, what
/// to apply, and whether applying it is legal — so a release has nothing left to
/// compute and can commit the value that was on screen. "It snapped somewhere
/// other than the preview showed" then needs a caller that recomputes on
/// purpose, rather than being the default outcome of two code paths drifting.
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
  /// Where a release puts the display when `arrangement` itself cannot be
  /// committed. `nil` for a drop with nothing to salvage, which is an overlap
  /// (AR7 springs those back) and a layout of one display.
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

  /// False when the drag ended where it started. Separate from `isValid`,
  /// because a no-op is perfectly valid — it is the layout that was already on
  /// screen — so validity alone never tells a caller there is something to do.
  public var changesArrangement: Bool { arrangement != baseline }

  /// What a release should apply, or `nil` when it should apply nothing.
  ///
  /// The landing wins when there is one, because it exists only for drops the
  /// rendered arrangement cannot answer for. A landing equal to the baseline is
  /// no commitment at all: `ArrangementPreviewSession.begin` refuses a no-op
  /// with `.illegalArgument`, and a drop that resolves back to where the
  /// display started is exactly that.
  public var commitment: DisplayArrangement? {
    if let landing { return landing.arrangement == baseline ? nil : landing.arrangement }
    return isValid && changesArrangement ? arrangement : nil
  }

  /// The one question a drop has to ask. An overlap still springs back (AR7),
  /// and a no-op is still refused by the preview session; what changed is that
  /// a drop into open space now has somewhere to go.
  public var isCommittable: Bool { commitment != nil }
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

    // The floor is §3.3's, and it earns its keep twice. On a map zoomed in far
    // enough that 8 canvas points is worth under half a display point the
    // conversion rounds to 0, which admits an exact hit and nothing either side
    // of it; 1 keeps a point of tolerance, which is all display space has to
    // give. And it holds a negative `snapThreshold` — which admits nothing at
    // all, not even an exact hit — to the same floor.
    let threshold = max(1, transform.displayDistance(snapThreshold))
    let snapped = ArrangementSnapper.snap(
      moved, id: id, against: baseline.tiles, threshold: threshold
    )

    // The rendered layout is ALWAYS the dragged display alone, moved to where
    // the pointer put it. Nothing else moves during a drag, whichever gesture
    // this turns out to be.
    let arrangement = baseline.moving(id, to: snapped.rect.origin)
    let problems = ArrangementRules.problems(in: arrangement)

    // An insert is decided from the PRE-snap rect and is tried first, because
    // ordinary snapping cannot express one: it abuts the near display and lands
    // on top of the far one, which AR7 would otherwise spring back. An insert
    // whose own result is illegal is dropped rather than reported, so displays
    // the user did not grab move only when the layout that results is one they
    // can keep.
    var landing: ArrangementLanding?
    if let insertion = ArrangementInsertPolicy.insertion(
         dragging: id, freeRect: moved, snappedRect: snapped.rect, into: baseline
       ),
       ArrangementRules.problems(in: insertion.arrangement).isEmpty,
       let guide = ArrangementInsertPolicy.guide(
         for: insertion.seam, rendered: snapped.rect, in: baseline
       )
    {
      landing = ArrangementLanding(arrangement: insertion.arrangement, lines: [guide])
    }
    // A drop that leaves a display touching nothing was refused before this,
    // and the refusal said where the display may not be without saying where it
    // may. A landing answers that. Overlaps that are not an insert still spring
    // back under AR7: a display dropped squarely on another names no particular
    // layout.
    else if !problems.isEmpty, problems.allSatisfy(\.isDisconnection),
            let attachment = ArrangementAttachPolicy.attach(
              moved, id: id, in: baseline, threshold: threshold
            )
    {
      landing = ArrangementLanding(
        arrangement: baseline.moving(id, to: attachment.rect.origin),
        lines: [attachment.line]
      )
    }

    // The rendered arrangement keeps its problems even when there is a landing:
    // the display is not legally where it is being drawn. What the problems no
    // longer decide on their own is whether the tile reads as refused, because
    // a drop with a landing is going to succeed; the canvas asks about the
    // landing before it reddens anything.
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
