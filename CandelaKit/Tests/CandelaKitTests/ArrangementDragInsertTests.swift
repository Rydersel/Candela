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

  /// Optionals are bound with `#require` rather than force-unwrapped, and that
  /// is a rule for the whole file: a force-unwrap trap signal-kills the runner,
  /// so the failure came back as a crash with no test name and every suite that
  /// had not run yet reported nothing. `#require` gives one named failure and
  /// lets the run finish.
  @Test func draggingTheEndOfARowOntoTheFirstSeamLandsAsAnInsert() throws {
    // 150 canvas points left is 1_500 display points, which puts display 3 at
    // x = 500: squarely across the seam at 1_000, and nowhere near a snap.
    let proposal = try #require(ArrangementDragPolicy.propose(
      dragging: 3, by: CanvasPoint(x: -150, y: 0), from: row, transform: tenToOne
    ))

    // Rendered under the pointer, straddling both its neighbours, and reported
    // as the illegal position it is.
    #expect(origin(proposal, 3) == DisplayPoint(x: 500, y: 0))
    #expect(proposal.problems == [.overlap(1, 3), .overlap(2, 3)])
    #expect(proposal.isValid == false)

    // The insert is what the release applies.
    let landed = try #require(proposal.landing?.arrangement)
    #expect(landed.tile(3)?.rect.origin == DisplayPoint(x: 1_000, y: 0))
    #expect(landed.tile(2)?.rect.origin == DisplayPoint(x: 2_000, y: 0))
    #expect(landed.tile(1)?.rect.origin == DisplayPoint(x: 0, y: 0))
    #expect(proposal.commitment == landed)
    #expect(proposal.isCommittable == true)
    #expect(ArrangementRules.problems(in: landed).isEmpty)

    let guide = try #require(proposal.landing?.lines.first)
    #expect(guide.axis == .x)
    #expect(guide.position == 1_000)
    #expect(guide.kind == .abut)
    #expect(guide.otherDisplayID == 1)

    // Positive control: without the push this is the drop the overlap-refusal rule refuses. Moving
    // display 3 alone to the seam buries it in display 2.
    #expect(ArrangementRules.problems(
      in: row.moving(3, to: DisplayPoint(x: 1_000, y: 0))
    ) == [.overlap(2, 3)])
  }

  @Test func nothingButTheDraggedDisplayMovesBeforeTheRelease() {
    // A drag rearranges nothing. Displays the user is not holding keep their
    // origins until the drop, whichever gesture the drag turns out to be.
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

  @Test func aDropInOpenSpaceRendersUnderThePointerAndCarriesItsLanding() throws {
    // 100 canvas points right and 300 up: 1_000 and -3_000 display points, well
    // clear of everything.
    let proposal = try #require(ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 100, y: -300), from: pair, transform: tenToOne
    ))

    // Rendered where the pointer is, and still reported as illegal: the tile has
    // to follow the pointer and be visibly not-there-yet.
    #expect(origin(proposal, 2) == DisplayPoint(x: 2_000, y: -3_000))
    #expect(proposal.problems == [.disconnected(2)])
    #expect(proposal.isValid == false)

    // And the landing says where the release puts it: against the top edge,
    // because the drop was further up than it was across.
    let landing = try #require(proposal.landing)
    #expect(landing.arrangement.tile(2)?.rect.origin == DisplayPoint(x: 0, y: -1_000))
    #expect(landing.lines.first?.axis == .y)
    #expect(landing.lines.first?.position == 0)
    #expect(landing.lines.first?.otherDisplayID == 1)

    #expect(proposal.isCommittable == true)
    #expect(proposal.commitment == landing.arrangement)
    // The landing is a layout that can actually be applied.
    let commitment = try #require(proposal.commitment)
    #expect(ArrangementRules.problems(in: commitment).isEmpty)
    // The rendered arrangement is NOT what gets applied, which is the one place
    // in this view where the two differ.
    #expect(commitment != proposal.arrangement)
  }

  @Test func anOverlapHasNoLandingAndStillSpringsBack() {
    // 95 canvas points left buries display 2 in display 1, and the snap
    // finishes the job by pulling it exactly on top.
    let proposal = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: -95, y: 0), from: pair, transform: tenToOne
    )

    #expect(origin(proposal, 2) == DisplayPoint(x: 0, y: 0))
    #expect(proposal?.problems == [.overlap(1, 2)])
    // The overlap-refusal rule stands here: a display dropped squarely on another names no layout,
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
    // The render-matches-commit rule: what the canvas draws is what the release applies. This drop is legal
    // exactly where the pointer left it AND strictly straddles a seam, so it is
    // where the two gestures collide. The insert branch used to run whether or
    // not the rendered layout had problems, and `commitment` prefers a landing
    // whenever one exists, so a drop like this rendered clean, reddened nothing,
    // and then committed a layout in which display 4, untouched by the user, sat
    // 200 points lower than the map had just shown it.
    //
    // Display 3 is dragged down and left until it straddles the seam on display
    // 2's bottom edge. The snap abuts it there, which is where the drop is legal:
    // display 2 above, display 4 to its left, overlapping neither. The insert
    // would land display 3 in the same place and shove display 4 out of the way.
    let baseline = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 400, 900)),
      (2, rect(400, 0, 500, 200)),
      (3, rect(900, 0, 300, 300)),
      (4, rect(400, 300, 400, 200)),
    ])
    #expect(ArrangementRules.problems(in: baseline).isEmpty)

    let proposal = ArrangementDragPolicy.propose(
      dragging: 3,
      by: CanvasPoint(x: -12, y: 19),
      from: baseline,
      transform: tenToOne
    )

    #expect(origin(proposal, 3) == DisplayPoint(x: 800, y: 200))
    #expect(proposal?.problems.isEmpty == true)
    #expect(proposal?.isValid == true)

    // No landing at all, because there is nothing for one to salvage.
    #expect(proposal?.landing == nil)
    #expect(proposal?.commitment == proposal?.arrangement)
    #expect(proposal?.isCommittable == true)
    // And display 4 is where it started, in the layout that is about to be
    // applied. That is the assertion the guard is really protecting.
    #expect(proposal?.commitment?.tile(4)?.rect.origin == DisplayPoint(x: 400, y: 300))

    // Positive control on the premise: the drop really does straddle a seam, so
    // an unguarded insert branch really would fire here. The insert is the y
    // seam between displays 2 and 4, and its push moves display 4 from y = 300
    // to y = 500 while leaving display 3 exactly where the pointer left it.
    let wouldHaveInserted = ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(780, 190, 300, 300),
      snappedRect: rect(800, 200, 300, 300),
      into: baseline
    )
    #expect(wouldHaveInserted?.seam.nearID == 2)
    #expect(wouldHaveInserted?.push == 200)
    #expect(wouldHaveInserted?.arrangement.tile(3)?.rect.origin == DisplayPoint(x: 800, y: 200))
    #expect(wouldHaveInserted?.arrangement.tile(4)?.rect.origin == DisplayPoint(x: 400, y: 500))
  }

  @Test func theSeamGuideIsDrawnInTheBaselineEvenWhenTheInsertReAnchors() throws {
    // Every other insert fixture here lands on a layout the main-anchor rule did not re-anchor,
    // so handing `ArrangementInsertPolicy.guide` the insertion's own arrangement
    // instead of the baseline left the whole suite green.
    //
    // This drop re-anchors: the dragged display is the one at the origin and the
    // insert puts it elsewhere, so the main-anchor rule translates the whole layout back onto it.
    // The translation has a y component, which is what an x-seam guide's extent
    // is measured along, so here the two arrangements finally disagree.
    let baseline = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 400, 400)),
      (2, rect(0, 400, 400, 400)),
      (3, rect(400, 400, 400, 400)),
    ])
    #expect(ArrangementRules.problems(in: baseline).isEmpty)
    #expect(baseline.mainDisplayID == 1)

    let proposal = try #require(ArrangementDragPolicy.propose(
      dragging: 1, by: CanvasPoint(x: 25, y: 50), from: baseline, transform: tenToOne
    ))
    #expect(origin(proposal, 1) == DisplayPoint(x: 250, y: 500))

    let landing = try #require(proposal.landing)
    // The main-anchor rule: display 1 was main and still is, and the price is that every other
    // display's origin in the landed layout is 500 points up and 400 left of
    // where the map is drawing it.
    #expect(landing.arrangement.mainDisplayID == 1)
    #expect(landing.arrangement.tile(1)?.rect.origin == DisplayPoint(x: 0, y: 0))
    #expect(landing.arrangement.tile(2)?.rect.origin == DisplayPoint(x: -400, y: -100))
    #expect(landing.arrangement.tile(3)?.rect.origin == DisplayPoint(x: 400, y: -100))

    let guide = try #require(landing.lines.first)
    #expect(guide.axis == .x)
    #expect(guide.position == 400)
    #expect(guide.otherDisplayID == 2)
    // The extent is the part that separates the two arrangements, and it is the
    // whole point of this test. Display 2 spans y 400 to 800 in the baseline the
    // canvas froze its transform on, and y -100 to 300 in the landed layout, so
    // a guide built from the landed layout starts at -100 and is drawn 500
    // points off the seam it names.
    #expect(guide.from == 400)
    #expect(guide.to == 900)
  }
}
