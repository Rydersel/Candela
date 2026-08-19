import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Arrangement insert policy")
struct ArrangementInsertPolicyTests {
  private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> DisplayRect {
    ArrangementFixtures.rect(x, y, w, h)
  }

  private func origin(_ arrangement: DisplayArrangement, _ id: CGDirectDisplayID) -> DisplayPoint? {
    arrangement.tile(id)?.rect.origin
  }

  /// A row of two 1000-wide displays, with the display to be inserted parked
  /// well clear of them. 1 is at the origin, so 1 is main.
  private var row: DisplayArrangement {
    ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(1_000, 0, 1_000, 1_000)),
      (3, rect(5_000, 0, 800, 1_000)),
    ])
  }

  @Test func coveringTheSeamInsertsAndPushesEverythingBeyondIt() {
    let insertion = ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(600, 0, 800, 1_000),
      snappedRect: rect(600, 0, 800, 1_000),
      into: row
    )

    #expect(insertion?.seam.position == 1_000)
    #expect(insertion?.seam.gap == 0)
    #expect(insertion?.seam.nearID == 1)
    #expect(insertion?.seam.farID == 2)
    #expect(insertion?.seam.axis == .x)
    // The gap was zero, so the far display has to move by the whole width.
    #expect(insertion?.push == 800)

    let arrangement = insertion?.arrangement
    #expect(origin(arrangement!, 1) == DisplayPoint(x: 0, y: 0))
    #expect(origin(arrangement!, 3) == DisplayPoint(x: 1_000, y: 0))
    #expect(origin(arrangement!, 2) == DisplayPoint(x: 1_800, y: 0))
    #expect(ArrangementRules.problems(in: arrangement!).isEmpty)

    // Positive control: this is the layout ordinary snapping CANNOT reach.
    // Moving display 3 alone to the same place overlaps display 2, which is
    // what AR7 springs back today, so the push is what makes the drop legal.
    #expect(!ArrangementRules.problems(
      in: row.moving(3, to: DisplayPoint(x: 1_000, y: 0))
    ).isEmpty)

    // The guide names the display the inserted one will come to rest against,
    // and sits on the seam rather than on the moved display's own edge. It is
    // built from the rect the MAP is drawing, which during the drag is still
    // where the pointer is.
    let guide = ArrangementInsertPolicy.guide(
      for: insertion!.seam, rendered: rect(600, 0, 800, 1_000), in: row
    )
    #expect(guide?.axis == .x)
    #expect(guide?.position == 1_000)
    #expect(guide?.kind == .abut)
    #expect(guide?.otherDisplayID == 1)
    #expect(guide?.from == 0)
    #expect(guide?.to == 1_000)
  }

  @Test func aGapWideEnoughAbsorbsTheInsertAndNothingElseMoves() {
    // Display 4 is the bridge under the row, and it is load-bearing rather than
    // scenery. The gap is 1_000 and the inserted display is 800, so 200 points
    // of it are left over; in a bare row that leftover strands display 2 and
    // the insert is refused, since the policy now returns only layouts that can
    // be kept. The bridge keeps everything connected across the remainder, so
    // this stays a case about a push of zero.
    let spaced = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(2_000, 0, 1_000, 1_000)),
      (3, rect(5_000, 0, 800, 1_000)),
      (4, rect(0, 1_000, 3_000, 1_000)),
    ])

    let insertion = ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(600, 0, 800, 1_000),
      snappedRect: rect(600, 0, 800, 1_000),
      into: spaced
    )

    #expect(insertion?.seam.gap == 1_000)
    #expect(insertion?.push == 0)
    #expect(origin(insertion!.arrangement, 3) == DisplayPoint(x: 1_000, y: 0))
    // Untouched, and that is the whole point of this case.
    #expect(origin(insertion!.arrangement, 1) == DisplayPoint(x: 0, y: 0))
    #expect(origin(insertion!.arrangement, 2) == DisplayPoint(x: 2_000, y: 0))
    #expect(origin(insertion!.arrangement, 4) == DisplayPoint(x: 0, y: 1_000))
    #expect(ArrangementRules.problems(in: insertion!.arrangement).isEmpty)
  }

  @Test func theGuideIsBuiltInTheCoordinatesTheMapIsDrawnIn() {
    // AR14 re-anchors the whole layout when an insert pushes the main display,
    // so the insertion's own arrangement can be a translation away from the
    // baseline the canvas froze its transform on. A guide taken from there
    // would be drawn that far off the seam it names.
    let leftward = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(-1_000, 0, 1_000, 1_000)),
      (3, rect(5_000, 0, 800, 1_000)),
    ])
    let insertion = ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(-400, 0, 800, 1_000),
      snappedRect: rect(-400, 0, 800, 1_000),
      into: leftward
    )

    let guide = ArrangementInsertPolicy.guide(
      for: insertion!.seam, rendered: rect(-400, 0, 800, 1_000), in: leftward
    )
    // The seam is at 0 in the baseline. In the re-anchored arrangement the same
    // seam sits at -800, so a guide drawn from there would be a whole display
    // to the left of the edge the user is aiming at.
    #expect(guide?.position == 0)
    #expect(insertion!.arrangement.tile(2)!.rect.maxX == -800)
  }

  @Test func insertingLeftOfTheMainDisplayLeavesItMain() {
    // 1 sits at the origin, so 1 is main (AR5). 2 is to its LEFT, so inserting
    // between them pushes 1 off the origin.
    let leftward = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(-1_000, 0, 1_000, 1_000)),
      (3, rect(5_000, 0, 800, 1_000)),
    ])
    #expect(leftward.mainDisplayID == 1)

    let insertion = ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(-400, 0, 800, 1_000),
      snappedRect: rect(-400, 0, 800, 1_000),
      into: leftward
    )

    #expect(insertion?.seam.position == 0)
    #expect(insertion?.push == 800)

    let arrangement = insertion!.arrangement
    // Re-anchored: without it display 3 would have landed on (0,0) and taken
    // "main" from display 1 silently, because AR5 derives main from the origin.
    #expect(arrangement.mainDisplayID == 1)
    #expect(origin(arrangement, 1) == DisplayPoint(x: 0, y: 0))
    #expect(origin(arrangement, 3) == DisplayPoint(x: -800, y: 0))
    #expect(origin(arrangement, 2) == DisplayPoint(x: -1_800, y: 0))

    // Positive control on the re-anchor: it is a pure translation, so every
    // display sits the same distance from its neighbours as the un-anchored
    // push would have left it. 3 abuts 1 on the left, 2 abuts 3 on the left.
    #expect(arrangement.tile(3)!.rect.maxX == arrangement.tile(1)!.rect.x)
    #expect(arrangement.tile(2)!.rect.maxX == arrangement.tile(3)!.rect.x)
    #expect(ArrangementRules.problems(in: arrangement).isEmpty)
  }

  @Test func insertingIntoAColumnPushesAlongY() {
    let column = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(0, 1_000, 1_000, 1_000)),
      (3, rect(5_000, 0, 1_000, 600)),
    ])

    let insertion = ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(0, 700, 1_000, 600),
      snappedRect: rect(0, 700, 1_000, 600),
      into: column
    )

    #expect(insertion?.seam.axis == .y)
    #expect(insertion?.seam.position == 1_000)
    #expect(insertion?.push == 600)
    #expect(origin(insertion!.arrangement, 3) == DisplayPoint(x: 0, y: 1_000))
    #expect(origin(insertion!.arrangement, 2) == DisplayPoint(x: 0, y: 1_600))

    // A horizontal seam gives a horizontal guide, spanning the two displays it
    // separates rather than the axis it constrains.
    let guide = ArrangementInsertPolicy.guide(
      for: insertion!.seam, rendered: rect(0, 700, 1_000, 600), in: column
    )
    #expect(guide?.axis == .y)
    #expect(guide?.position == 1_000)
    #expect(guide?.otherDisplayID == 1)
  }

  @Test func touchingTheSeamIsNotCoveringIt() {
    // Leading edge exactly on the seam: an ordinary abut, which the snapper
    // already produces, so the insert policy must decline it. Both comparisons
    // are strict for this reason.
    #expect(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(1_000, 0, 800, 1_000),
      snappedRect: rect(1_000, 0, 800, 1_000),
      into: row
    ) == nil)

    // Trailing edge exactly on the seam, from the other side.
    #expect(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(200, 0, 800, 1_000),
      snappedRect: rect(200, 0, 800, 1_000),
      into: row
    ) == nil)
  }

  @Test func aDisplayThatCannotReachBothSidesDoesNotInsert() {
    // Squarely over the seam on X, but dragged along a track well above the
    // row: it shares no vertical span with either display, so there is nothing
    // for it to abut and this is not an insert.
    #expect(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(600, -3_000, 800, 1_000),
      snappedRect: rect(600, -3_000, 800, 1_000),
      into: row
    ) == nil)

    // Positive control: the same X, back down at the row's own height, does
    // insert. Without this the assertion above would pass for any reason.
    #expect(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(600, 0, 800, 1_000),
      snappedRect: rect(600, 0, 800, 1_000),
      into: row
    ) != nil)
  }

  @Test func aSeamNeedsTwoDisplaysThatAreNotTheOneBeingDragged() {
    let pair = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(1_000, 0, 1_000, 1_000)),
    ])

    // Dragging 2 leaves only display 1, and one display has no seams.
    #expect(ArrangementInsertPolicy.insertion(
      dragging: 2,
      freeRect: rect(500, 0, 1_000, 1_000),
      snappedRect: rect(500, 0, 1_000, 1_000),
      into: pair
    ) == nil)
  }

  @Test func theDraggedDisplaysOwnGapIsASeamItCanGoBackInto() {
    // Pulling the middle display out of a row and putting it back is the most
    // ordinary insert there is, and it only works because the dragged display
    // is excluded from the seam search: the gap it left is between 1 and 3.
    let pulled = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(1_000, 3_000, 800, 1_000)),
      (3, rect(1_800, 0, 1_000, 1_000)),
    ])

    let insertion = ArrangementInsertPolicy.insertion(
      dragging: 2,
      freeRect: rect(900, 0, 800, 1_000),
      snappedRect: rect(900, 0, 800, 1_000),
      into: pulled
    )

    #expect(insertion?.seam.nearID == 1)
    #expect(insertion?.seam.farID == 3)
    #expect(insertion?.seam.gap == 800)
    // The gap is exactly the width that left it, so nothing else has to move.
    #expect(insertion?.push == 0)
    #expect(origin(insertion!.arrangement, 2) == DisplayPoint(x: 1_000, y: 0))
    #expect(origin(insertion!.arrangement, 3) == DisplayPoint(x: 1_800, y: 0))
    #expect(ArrangementRules.problems(in: insertion!.arrangement).isEmpty)
  }

  @Test func theNearerSeamWinsAndTiesGoToTheTighterOne() {
    // Four in a row, so the dragged display can cover two seams at once.
    let long = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(1_000, 0, 1_000, 1_000)),
      (3, rect(2_000, 0, 1_000, 1_000)),
      (4, rect(6_000, 0, 400, 1_000)),
    ])

    // Centred at 1_100: nearer the 1_000 seam than the 2_000 one.
    let near = ArrangementInsertPolicy.insertion(
      dragging: 4,
      freeRect: rect(900, 0, 400, 1_000),
      snappedRect: rect(900, 0, 400, 1_000),
      into: long
    )
    #expect(near?.seam.position == 1_000)
    #expect(near?.seam.nearID == 1)

    // Centred at 1_900: the other seam, from a drag that still covers 2_000.
    let far = ArrangementInsertPolicy.insertion(
      dragging: 4,
      freeRect: rect(1_700, 0, 400, 1_000),
      snappedRect: rect(1_700, 0, 400, 1_000),
      into: long
    )
    #expect(far?.seam.position == 2_000)
    #expect(far?.seam.nearID == 2)

    // The outer pair (1, 3) also offers a seam at 1_000, straight through
    // display 2, with a gap of 2_000 rather than 0. Ascending gap is what puts
    // the tight one first here. It is not what saves this case: the wide seam
    // would under-push and bury the inserted display in display 2, and the walk
    // would step over it. The case where the gap term is the ONLY thing
    // deciding is `tiesAtOneSeamPositionGoToTheTighterSeam`.
    #expect(near?.seam.farID == 2)
    #expect(near?.push == 400)
    #expect(origin(near!.arrangement, 2) == DisplayPoint(x: 1_400, y: 0))
    #expect(origin(near!.arrangement, 3) == DisplayPoint(x: 2_400, y: 0))
  }

  @Test func theCrossAxisComesFromTheSnapperAndTheSeamAxisFromTheSeam() {
    // The snapped rect disagrees with the free rect on BOTH axes. The insert
    // must take Y from the snapped one and X from the seam, so a policy that
    // read either from the wrong source lands somewhere this cannot be.
    let insertion = ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(600, 40, 800, 1_000),
      snappedRect: rect(620, 0, 800, 1_000),
      into: row
    )

    #expect(origin(insertion!.arrangement, 3) == DisplayPoint(x: 1_000, y: 0))
  }

  @Test func tiesAtOneSeamPositionGoToTheTighterSeam() {
    // Both seams start at display 1's right edge, so they tie on distance and
    // `gap` is the only term left that separates them. Display 4 is pulled from
    // a slot it fits EXACTLY, which is what makes both candidates legal: the
    // tight seam (1, 3) has a gap of 400 and the wide one (1, 2) has 1_400, and
    // either way the push is zero and the layout comes out identical. So
    // nothing but the reported seam can tell them apart, and the walk cannot
    // paper over a mis-ranking by rejecting the loser.
    //
    // The ids are deliberately out of row order: the wide seam's far display is
    // 2 and the tight one's is 3, so with the `gap` term removed the trailing
    // `farID` term picks the WIDE seam and this test fails. In a row numbered
    // left to right the two terms agree and the mutation is invisible, which is
    // how the tie-break went untested.
    let exactFit = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (4, rect(1_000, 0, 400, 1_000)),
      (3, rect(1_400, 0, 1_000, 1_000)),
      (2, rect(2_400, 0, 1_000, 1_000)),
    ])
    #expect(ArrangementRules.problems(in: exactFit).isEmpty)

    let insertion = ArrangementInsertPolicy.insertion(
      dragging: 4,
      freeRect: rect(900, 0, 400, 1_000),
      snappedRect: rect(900, 0, 400, 1_000),
      into: exactFit
    )

    #expect(insertion?.seam.position == 1_000)
    #expect(insertion?.seam.nearID == 1)
    #expect(insertion?.seam.farID == 3)
    #expect(insertion?.seam.gap == 400)
    #expect(insertion?.push == 0)

    // Positive control on the premise: the seam that loses is a real candidate
    // and a legal one, not a candidate the walk was going to throw away. Both
    // produce this layout, which is why only the seam can be asserted on.
    #expect(insertion?.arrangement.tile(4)?.rect.origin == DisplayPoint(x: 1_000, y: 0))
    #expect(insertion?.arrangement.tile(3)?.rect.origin == DisplayPoint(x: 1_400, y: 0))
    #expect(insertion?.arrangement.tile(2)?.rect.origin == DisplayPoint(x: 2_400, y: 0))
    #expect(insertion.map { ArrangementRules.problems(in: $0.arrangement).isEmpty } == true)
  }

  @Test func aLowerRankedSeamIsUsedWhenTheTopRankedOneIsIllegal() {
    // The top-ranked seam is (x, 200, gap 0) between 1 and 4: the dragged
    // display's centre is 25 points from it, against 100 for either seam on y.
    // Inserting there pushes display 4 clear but leaves the inserted display
    // lying across display 2, so that seam cannot be used. A lower-ranked one
    // can: the y seam at 0 between 2 and 1 gives a layout with no problems at
    // all. Ranking once and taking the winner reported no insert here and the
    // drop sprang back, which is the defect the walk fixes.
    let baseline = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 200, 300)),
      (2, rect(50, -300, 300, 300)),
      (3, rect(200, 300, 300, 300)),
      (4, rect(200, 200, 100, 100)),
    ])
    #expect(ArrangementRules.problems(in: baseline).isEmpty)

    // Display 3 dragged up and left, far enough from every edge that nothing
    // snaps, so the free and snapped rects are the same rect.
    let dragged = rect(75, -50, 300, 300)

    // Positive control on the premise. The top-ranked seam is the x one at 200,
    // 25 points from the dragged centre against 100 for either y seam, and this
    // is the layout it would have produced: display 3 on the seam and display 4
    // pushed 300 clear of it. It is illegal, so a policy that ranks once and
    // takes the winner has to report no insert at all. Without this the
    // assertions below would pass for a policy that never ranked that seam
    // first in the first place.
    let ifTopRankedSeamHadBeenUsed = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 200, 300)),
      (2, rect(50, -300, 300, 300)),
      (3, rect(200, -50, 300, 300)),
      (4, rect(500, 200, 100, 100)),
    ])
    #expect(ArrangementRules.problems(in: ifTopRankedSeamHadBeenUsed) == [.overlap(2, 3)])

    let insertion = ArrangementInsertPolicy.insertion(
      dragging: 3, freeRect: dragged, snappedRect: dragged, into: baseline
    )

    #expect(insertion?.seam.axis == .y)
    #expect(insertion?.seam.position == 0)
    #expect(insertion?.seam.nearID == 2)
    #expect(insertion?.seam.farID == 1)
    // Optional-chained rather than force-unwrapped: the defect this pins made
    // `insertion` return nil, and a test that traps there reports a crash
    // instead of the four expectations that say what went wrong.
    #expect(insertion.map { ArrangementRules.problems(in: $0.arrangement).isEmpty } == true)
    #expect(insertion?.arrangement.tile(1)?.rect.origin == DisplayPoint(x: 0, y: 0))
    #expect(insertion?.arrangement.tile(2)?.rect.origin == DisplayPoint(x: 50, y: -600))
    #expect(insertion?.arrangement.tile(3)?.rect.origin == DisplayPoint(x: 75, y: -300))
    #expect(insertion?.arrangement.tile(4)?.rect.origin == DisplayPoint(x: 200, y: 200))
    // AR14 holds through the walk: the display that was main still is.
    #expect(insertion?.arrangement.mainDisplayID == 1)
  }
}
