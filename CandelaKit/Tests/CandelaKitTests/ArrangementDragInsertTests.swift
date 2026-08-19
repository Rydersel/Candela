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

  @Test func draggingTheEndOfARowOntoTheFirstSeamLandsAsAnInsert() {
    // 150 canvas points left is 1_500 display points, which puts display 3 at
    // x = 500: squarely across the seam at 1_000, and nowhere near a snap.
    let proposal = ArrangementDragPolicy.propose(
      dragging: 3, by: CanvasPoint(x: -150, y: 0), from: row, transform: tenToOne
    )

    // Rendered under the pointer, straddling both its neighbours, and reported
    // as the illegal position it is.
    #expect(origin(proposal, 3) == DisplayPoint(x: 500, y: 0))
    #expect(proposal?.problems == [.overlap(1, 3), .overlap(2, 3)])
    #expect(proposal?.isValid == false)

    // The insert is what the release applies.
    let landed = proposal?.landing?.arrangement
    #expect(landed?.tile(3)?.rect.origin == DisplayPoint(x: 1_000, y: 0))
    #expect(landed?.tile(2)?.rect.origin == DisplayPoint(x: 2_000, y: 0))
    #expect(landed?.tile(1)?.rect.origin == DisplayPoint(x: 0, y: 0))
    #expect(proposal?.commitment == landed)
    #expect(proposal?.isCommittable == true)
    #expect(ArrangementRules.problems(in: landed!).isEmpty)

    let guide = proposal?.landing?.lines.first
    #expect(guide?.axis == .x)
    #expect(guide?.position == 1_000)
    #expect(guide?.kind == .abut)
    #expect(guide?.otherDisplayID == 1)

    // Positive control: without the push this is the drop AR7 refuses. Moving
    // display 3 alone to the seam buries it in display 2.
    #expect(ArrangementRules.problems(
      in: row.moving(3, to: DisplayPoint(x: 1_000, y: 0))
    ) == [.overlap(2, 3)])
  }

  @Test func nothingButTheDraggedDisplayMovesBeforeTheRelease() {
    // The rule the feature is now built around: a drag rearranges nothing.
    // Displays the user is not holding keep their origins until the drop,
    // whichever gesture the drag turns out to be.
    let insert = ArrangementDragPolicy.propose(
      dragging: 3, by: CanvasPoint(x: -150, y: 0), from: row, transform: tenToOne
    )
    #expect(origin(insert, 1) == DisplayPoint(x: 0, y: 0))
    #expect(origin(insert, 2) == DisplayPoint(x: 1_000, y: 0))

    // Positive control: the layout it lands on DOES move display 2, so the
    // assertions above are about the rendered layout and not about an insert
    // that quietly stopped working.
    #expect(insert?.landing?.arrangement.tile(2)?.rect.origin == DisplayPoint(x: 2_000, y: 0))

    // And the same for a drop into open space.
    let landing = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 100, y: -300), from: pair, transform: tenToOne
    )
    #expect(landing?.arrangement.tile(1)?.rect.origin == DisplayPoint(x: 0, y: 0))
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
    #expect(proposal?.landing?.lines.first?.axis == .y)
    #expect(proposal?.landing?.lines.first?.position == 0)
    #expect(proposal?.landing?.lines.first?.otherDisplayID == 1)

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

  @Test func anInsertIsPreferredToTheAttachFallback() {
    // The insert is tried first, so a drag that covers a seam lands on the
    // inserted layout rather than being attached somewhere by the fallback.
    let proposal = ArrangementDragPolicy.propose(
      dragging: 3, by: CanvasPoint(x: -150, y: 0), from: row, transform: tenToOne
    )
    #expect(proposal?.landing?.arrangement.tile(2)?.rect.origin == DisplayPoint(x: 2_000, y: 0))

    // Positive control: take the same display off the seam entirely and the
    // insert stops applying. 400 canvas points down puts display 3 well below
    // the row, covering nothing, so it renders out in space with a landing.
    let offSeam = ArrangementDragPolicy.propose(
      dragging: 3, by: CanvasPoint(x: 0, y: 400), from: row, transform: tenToOne
    )
    #expect(origin(offSeam, 3) == DisplayPoint(x: 2_000, y: 4_000))
    #expect(offSeam?.problems == [.disconnected(3)])
    // Attached, not inserted: no other display moves in this landing either.
    #expect(offSeam?.landing?.arrangement.tile(3)?.rect.origin == DisplayPoint(x: 1_000, y: 1_000))
    #expect(offSeam?.landing?.arrangement.tile(2)?.rect.origin == DisplayPoint(x: 1_000, y: 0))
  }

  @Test func aLegalDropOverASeamCommitsWhereItWasDropped() {
    // AR3: what the canvas draws is what the release applies. This drop is
    // legal exactly where the pointer left it AND strictly straddles a seam, so
    // it is the case where the two gestures collide. The insert branch used to
    // run whether or not the rendered layout had problems, and `commitment`
    // prefers a landing whenever one exists, so this drop rendered clean,
    // reddened nothing (a drop with a landing reddens nothing), and then
    // committed display 2 a whole 200 points below where the user let go.
    let baseline = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 300, 200)),
      (2, rect(250, 200, 300, 300)),
      (3, rect(50, 200, 200, 300)),
      (4, rect(-50, 500, 300, 100)),
    ])
    #expect(ArrangementRules.problems(in: baseline).isEmpty)

    let proposal = ArrangementDragPolicy.propose(
      dragging: 2,
      by: CanvasPoint(x: -105, y: -40),
      from: baseline,
      transform: CanvasTransform(scale: 0.2, offsetX: 0, offsetY: 0)
    )

    #expect(origin(proposal, 2) == DisplayPoint(x: -300, y: 0))
    #expect(proposal?.problems.isEmpty == true)
    #expect(proposal?.isValid == true)

    // No landing at all, because there is nothing for one to salvage.
    #expect(proposal?.landing == nil)
    #expect(proposal?.commitment == proposal?.arrangement)
    #expect(proposal?.isCommittable == true)

    // Positive control on the premise: the drop really does straddle a seam, so
    // an unguarded insert branch really would fire here. The insert is the y
    // seam between displays 1 and 4, and it puts display 2 at y = 200 rather
    // than the y = 0 the pointer asked for.
    let wouldHaveInserted = ArrangementInsertPolicy.insertion(
      dragging: 2,
      freeRect: rect(-275, 0, 300, 300),
      snappedRect: rect(-300, 0, 300, 300),
      into: baseline
    )
    #expect(wouldHaveInserted?.arrangement.tile(2)?.rect.origin == DisplayPoint(x: -300, y: 200))
  }
}
