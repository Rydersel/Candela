import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The drag decision's two new outcomes: a drop that covers a seam inserts, and
/// a drop that lands nowhere legal carries a landing instead of only a refusal.
/// The rest of `ArrangementDragPolicy` is pinned by `ArrangementDragPolicyTests`.
@Suite("Arrangement drag: inserting and landing")
struct ArrangementDragInsertTests {
  private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> DisplayRect {
    ArrangementFixtures.rect(x, y, w, h)
  }

  /// At scale 0.1 one canvas point is ten display points, so the 8-point
  /// threshold is 80 display points.
  private var tenToOne: CanvasTransform {
    CanvasTransform(scale: 0.1, offsetX: 0, offsetY: 0)
  }

  private var row: DisplayArrangement {
    ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(1_000, 0, 1_000, 1_000)),
      (3, rect(2_000, 0, 1_000, 1_000)),
    ])
  }

  private var pair: DisplayArrangement {
    ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(1_000, 0, 1_000, 1_000)),
    ])
  }

  private func origin(_ proposal: ArrangementProposal?, _ id: CGDirectDisplayID) -> DisplayPoint? {
    proposal?.arrangement.tile(id)?.rect.origin
  }

  @Test func draggingTheEndOfARowOntoTheFirstSeamInsertsItThere() {
    // 150 canvas points left is 1_500 display points, which puts display 3 at
    // x = 500: squarely across the seam at 1_000, and nowhere near a snap.
    let proposal = ArrangementDragPolicy.propose(
      dragging: 3, by: CanvasPoint(x: -150, y: 0), from: row, transform: tenToOne
    )

    #expect(origin(proposal, 3) == DisplayPoint(x: 1_000, y: 0))
    // The display nobody grabbed, moved out of the way. This is the whole
    // feature: AR4 already required the plan to carry every origin, and now it
    // carries one that changed.
    #expect(origin(proposal, 2) == DisplayPoint(x: 2_000, y: 0))
    #expect(origin(proposal, 1) == DisplayPoint(x: 0, y: 0))

    #expect(proposal?.isValid == true)
    #expect(proposal?.isCommittable == true)
    #expect(proposal?.commitment == proposal?.arrangement)
    // An insert IS the rendered layout, so there is nothing to land on later.
    #expect(proposal?.landing == nil)

    let xLine = proposal?.lines.first { $0.axis == .x }
    #expect(xLine?.position == 1_000)
    #expect(xLine?.kind == .abut)
    #expect(xLine?.otherDisplayID == 1)

    // Positive control: without the push this is the drop AR7 refuses. Moving
    // display 3 alone to the same origin buries it in display 2.
    #expect(ArrangementRules.problems(
      in: row.moving(3, to: DisplayPoint(x: 1_000, y: 0))
    ) == [.overlap(2, 3)])
  }

  @Test func aDropInOpenSpaceRendersUnderThePointerAndCarriesItsLanding() {
    // 100 canvas points right and 300 up: 1_000 and -3_000 display points, well
    // clear of everything.
    let proposal = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 100, y: -300), from: pair, transform: tenToOne
    )

    // Rendered where the pointer is, and still reported as illegal. Both are
    // deliberate: the tile has to follow the pointer, and it has to be visibly
    // not-there-yet.
    #expect(origin(proposal, 2) == DisplayPoint(x: 2_000, y: -3_000))
    #expect(proposal?.problems == [.disconnected(2)])
    #expect(proposal?.isValid == false)

    // And the landing says where the release puts it: against the top edge,
    // because the drop was further up than it was across.
    #expect(proposal?.landing?.arrangement.tile(2)?.rect.origin == DisplayPoint(x: 0, y: -1_000))
    #expect(proposal?.landing?.line.axis == .y)
    #expect(proposal?.landing?.line.position == 0)
    #expect(proposal?.landing?.line.otherDisplayID == 1)

    #expect(proposal?.isCommittable == true)
    #expect(proposal?.commitment == proposal?.landing?.arrangement)
    // The landing is a layout that can actually be applied.
    #expect(ArrangementRules.problems(in: proposal!.commitment!).isEmpty)
    // The rendered arrangement is NOT what gets applied, which is the one place
    // in this view where the two differ.
    #expect(proposal?.commitment != proposal?.arrangement)
  }

  @Test func anOverlapHasNoLandingAndStillSpringsBack() {
    // 95 canvas points left buries display 2 in display 1, and the snap
    // finishes the job by pulling it exactly on top.
    let proposal = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: -95, y: 0), from: pair, transform: tenToOne
    )

    #expect(origin(proposal, 2) == DisplayPoint(x: 0, y: 0))
    #expect(proposal?.problems == [.overlap(1, 2)])
    // AR7 stands here: a display dropped squarely on another names no layout,
    // so there is nothing to land on and the canvas springs it home.
    #expect(proposal?.landing == nil)
    #expect(proposal?.commitment == nil)
    #expect(proposal?.isCommittable == false)
  }

  @Test func aLandingThatResolvesBackToTheStartCommitsNothing() {
    // Pulling the middle display of a row straight down strands the far one.
    // The nearest legal place for it is back where it was, and a drop that
    // resolves to the layout it started from must not be sent to the preview
    // session, which refuses a no-op with `.illegalArgument`.
    let proposal = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 0, y: 500), from: row, transform: tenToOne
    )

    #expect(origin(proposal, 2) == DisplayPoint(x: 1_000, y: 5_000))
    #expect(proposal?.problems == [.disconnected(2), .disconnected(3)])
    #expect(proposal?.landing?.arrangement == row)
    #expect(proposal?.commitment == nil)
    #expect(proposal?.isCommittable == false)
  }

  @Test func insertingIsDecidedBeforeAnythingElseAndSuppressesTheLanding() {
    // The same drag as the insert test, checked from the other direction: the
    // proposal that comes back is the inserted layout and not an overlap
    // carrying a landing, so nothing downstream has to know which path ran.
    let proposal = ArrangementDragPolicy.propose(
      dragging: 3, by: CanvasPoint(x: -150, y: 0), from: row, transform: tenToOne
    )
    #expect(proposal?.problems.isEmpty == true)
    #expect(proposal?.landing == nil)

    // Positive control: take the same display off the seam entirely and the
    // insert stops applying. 400 canvas points down puts display 3 well below
    // the row, covering nothing, so it renders out in space with a landing.
    let offSeam = ArrangementDragPolicy.propose(
      dragging: 3, by: CanvasPoint(x: 0, y: 400), from: row, transform: tenToOne
    )
    #expect(origin(offSeam, 3) == DisplayPoint(x: 2_000, y: 4_000))
    #expect(offSeam?.problems == [.disconnected(3)])
    #expect(offSeam?.landing?.arrangement.tile(3)?.rect.origin == DisplayPoint(x: 1_000, y: 1_000))
  }
}
