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

  /// Optionals bind with `#require` rather than force-unwrap throughout this file:
  /// a trap signal-kills the runner, so a nil `insertion` came back as a crash with
  /// no test name and every suite that had not run yet reported nothing.
  @Test func coveringTheSeamInsertsAndPushesEverythingBeyondIt() throws {
    let insertion = try #require(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(600, 0, 800, 1_000),
      snappedRect: rect(600, 0, 800, 1_000),
      into: row
    ))

    #expect(insertion.seam.position == 1_000)
    #expect(insertion.seam.gap == 0)
    #expect(insertion.seam.nearID == 1)
    #expect(insertion.seam.farID == 2)
    #expect(insertion.seam.axis == .x)
    // The gap was zero, so the far display has to move by the whole width.
    #expect(insertion.push == 800)

    let arrangement = insertion.arrangement
    #expect(origin(arrangement, 1) == DisplayPoint(x: 0, y: 0))
    #expect(origin(arrangement, 3) == DisplayPoint(x: 1_000, y: 0))
    #expect(origin(arrangement, 2) == DisplayPoint(x: 1_800, y: 0))
    #expect(ArrangementRules.problems(in: arrangement).isEmpty)

    // Moving display 3 alone to the same place overlaps display 2, which AR7 springs
    // back, so the push is what makes this drop legal.
    #expect(!ArrangementRules.problems(
      in: row.moving(3, to: DisplayPoint(x: 1_000, y: 0))
    ).isEmpty)

    // The guide sits on the seam, not the moved display's own edge, and is built from
    // the rect the map is drawing: during a drag that is still under the pointer.
    let guide = try #require(ArrangementInsertPolicy.guide(
      for: insertion.seam, rendered: rect(600, 0, 800, 1_000), in: row
    ))
    #expect(guide.axis == .x)
    #expect(guide.position == 1_000)
    #expect(guide.kind == .abut)
    #expect(guide.otherDisplayID == 1)
    #expect(guide.from == 0)
    #expect(guide.to == 1_000)
  }

  @Test func aGapWideEnoughAbsorbsTheInsertAndNothingElseMoves() throws {
    // Display 4 bridges the row and is load-bearing: without it the 200-point
    // remainder strands display 2 and the insert is refused, not a push of zero.
    let spaced = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(2_000, 0, 1_000, 1_000)),
      (3, rect(5_000, 0, 800, 1_000)),
      (4, rect(0, 1_000, 3_000, 1_000)),
    ])

    let insertion = try #require(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(600, 0, 800, 1_000),
      snappedRect: rect(600, 0, 800, 1_000),
      into: spaced
    ))

    #expect(insertion.seam.gap == 1_000)
    #expect(insertion.push == 0)
    #expect(origin(insertion.arrangement, 3) == DisplayPoint(x: 1_000, y: 0))
    // Untouched, and that is the whole point of this case.
    #expect(origin(insertion.arrangement, 1) == DisplayPoint(x: 0, y: 0))
    #expect(origin(insertion.arrangement, 2) == DisplayPoint(x: 2_000, y: 0))
    #expect(origin(insertion.arrangement, 4) == DisplayPoint(x: 0, y: 1_000))
    #expect(ArrangementRules.problems(in: insertion.arrangement).isEmpty)
  }

  @Test func theGuideIsBuiltInTheCoordinatesTheMapIsDrawnIn() throws {
    // AR14 re-anchors the layout when an insert pushes the main display, so the
    // insertion's arrangement can be a translation away from the frozen baseline.
    let leftward = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(-1_000, 0, 1_000, 1_000)),
      (3, rect(5_000, 0, 800, 1_000)),
    ])
    let insertion = try #require(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(-400, 0, 800, 1_000),
      snappedRect: rect(-400, 0, 800, 1_000),
      into: leftward
    ))

    let guide = try #require(ArrangementInsertPolicy.guide(
      for: insertion.seam, rendered: rect(-400, 0, 800, 1_000), in: leftward
    ))
    // The seam is at 0 in the baseline and at -800 in the re-anchored arrangement:
    // a guide read from the latter names an edge a whole display off.
    #expect(guide.position == 0)
    #expect(insertion.arrangement.tile(2)?.rect.maxX == -800)
    // This pins the function, not the call site: an x-axis re-anchor translates along
    // x while the guide's extent runs along y, so both arrangements give the same guide
    // here. `ArrangementDragInsertTests` holds the case that separates them.
  }

  @Test func insertingLeftOfTheMainDisplayLeavesItMain() throws {
    // 1 sits at the origin, so 1 is main (AR5). 2 is to its LEFT, so inserting
    // between them pushes 1 off the origin.
    let leftward = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(-1_000, 0, 1_000, 1_000)),
      (3, rect(5_000, 0, 800, 1_000)),
    ])
    #expect(leftward.mainDisplayID == 1)

    let insertion = try #require(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(-400, 0, 800, 1_000),
      snappedRect: rect(-400, 0, 800, 1_000),
      into: leftward
    ))

    #expect(insertion.seam.position == 0)
    #expect(insertion.push == 800)

    let arrangement = insertion.arrangement
    // Without the re-anchor display 3 lands on (0,0) and silently takes main from
    // display 1, since AR5 derives main from the origin.
    #expect(arrangement.mainDisplayID == 1)
    #expect(origin(arrangement, 1) == DisplayPoint(x: 0, y: 0))
    #expect(origin(arrangement, 3) == DisplayPoint(x: -800, y: 0))
    #expect(origin(arrangement, 2) == DisplayPoint(x: -1_800, y: 0))

    // The re-anchor is a pure translation, so neighbours keep their distances:
    // 3 abuts 1 on the left, 2 abuts 3.
    let one = try #require(arrangement.tile(1))
    let two = try #require(arrangement.tile(2))
    let three = try #require(arrangement.tile(3))
    #expect(three.rect.maxX == one.rect.x)
    #expect(two.rect.maxX == three.rect.x)
    #expect(ArrangementRules.problems(in: arrangement).isEmpty)
  }

  @Test func insertingIntoAColumnPushesAlongY() throws {
    let column = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(0, 1_000, 1_000, 1_000)),
      (3, rect(5_000, 0, 1_000, 600)),
    ])

    let insertion = try #require(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(0, 700, 1_000, 600),
      snappedRect: rect(0, 700, 1_000, 600),
      into: column
    ))

    #expect(insertion.seam.axis == .y)
    #expect(insertion.seam.position == 1_000)
    #expect(insertion.push == 600)
    #expect(origin(insertion.arrangement, 3) == DisplayPoint(x: 0, y: 1_000))
    #expect(origin(insertion.arrangement, 2) == DisplayPoint(x: 0, y: 1_600))

    // A horizontal seam gives a horizontal guide, spanning the two displays it
    // separates rather than the axis it constrains.
    let guide = try #require(ArrangementInsertPolicy.guide(
      for: insertion.seam, rendered: rect(0, 700, 1_000, 600), in: column
    ))
    #expect(guide.axis == .y)
    #expect(guide.position == 1_000)
    #expect(guide.otherDisplayID == 1)
  }

  @Test func touchingTheSeamIsNotCoveringIt() {
    // An edge exactly on the seam is an ordinary abut the snapper already produces,
    // so the insert policy declines it and both comparisons are strict.
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
    // Squarely over the seam on X but on a track above the row: it shares no vertical
    // span with either display, so there is nothing to abut.
    #expect(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(600, -3_000, 800, 1_000),
      snappedRect: rect(600, -3_000, 800, 1_000),
      into: row
    ) == nil)

    // Positive control: the same X at the row's own height does insert.
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

  @Test func theDraggedDisplaysOwnGapIsASeamItCanGoBackInto() throws {
    // Putting the middle display back works only because the dragged display is
    // excluded from the seam search: the gap it left is between 1 and 3.
    let pulled = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(1_000, 3_000, 800, 1_000)),
      (3, rect(1_800, 0, 1_000, 1_000)),
    ])

    let insertion = try #require(ArrangementInsertPolicy.insertion(
      dragging: 2,
      freeRect: rect(900, 0, 800, 1_000),
      snappedRect: rect(900, 0, 800, 1_000),
      into: pulled
    ))

    #expect(insertion.seam.nearID == 1)
    #expect(insertion.seam.farID == 3)
    #expect(insertion.seam.gap == 800)
    // The gap is exactly the width that left it, so nothing else has to move.
    #expect(insertion.push == 0)
    #expect(origin(insertion.arrangement, 2) == DisplayPoint(x: 1_000, y: 0))
    #expect(origin(insertion.arrangement, 3) == DisplayPoint(x: 1_800, y: 0))
    #expect(ArrangementRules.problems(in: insertion.arrangement).isEmpty)
  }

  @Test func theNearerSeamWinsAndTiesGoToTheTighterOne() throws {
    // Four in a row, so the dragged display can cover two seams at once.
    let long = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(1_000, 0, 1_000, 1_000)),
      (3, rect(2_000, 0, 1_000, 1_000)),
      (4, rect(6_000, 0, 400, 1_000)),
    ])

    // Centred at 1_100: nearer the 1_000 seam than the 2_000 one.
    let near = try #require(ArrangementInsertPolicy.insertion(
      dragging: 4,
      freeRect: rect(900, 0, 400, 1_000),
      snappedRect: rect(900, 0, 400, 1_000),
      into: long
    ))
    #expect(near.seam.position == 1_000)
    #expect(near.seam.nearID == 1)

    // Centred at 1_900: the other seam, from a drag that still covers 2_000.
    let far = ArrangementInsertPolicy.insertion(
      dragging: 4,
      freeRect: rect(1_700, 0, 400, 1_000),
      snappedRect: rect(1_700, 0, 400, 1_000),
      into: long
    )
    #expect(far?.seam.position == 2_000)
    #expect(far?.seam.nearID == 2)

    // The outer pair (1, 3) offers a seam at the same position with a gap of 2_000.
    // Ascending gap ranks the tight one first, but the wide one would under-push and
    // the walk steps over it; `tiesAtOneSeamPositionGoToTheTighterSeam` is where the
    // gap term alone decides.
    #expect(near.seam.farID == 2)
    #expect(near.push == 400)
    #expect(origin(near.arrangement, 2) == DisplayPoint(x: 1_400, y: 0))
    #expect(origin(near.arrangement, 3) == DisplayPoint(x: 2_400, y: 0))
  }

  @Test func theCrossAxisComesFromTheSnapperAndTheSeamAxisFromTheSeam() throws {
    // The snapped rect disagrees with the free rect on both axes, so a policy that
    // takes Y from anywhere but the snap, or X from anywhere but the seam, lands wrong.
    let insertion = try #require(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(600, 40, 800, 1_000),
      snappedRect: rect(620, 0, 800, 1_000),
      into: row
    ))

    #expect(origin(insertion.arrangement, 3) == DisplayPoint(x: 1_000, y: 0))
  }

  @Test func tiesAtOneSeamPositionGoToTheTighterSeam() {
    // Both seams start at display 1's right edge, so they tie on distance and `gap` is
    // the only term separating them. Display 4 fits its slot exactly, so both are legal
    // and give the same layout, leaving the reported seam as the only observable. The
    // ids are out of row order on purpose: with `gap` removed the trailing `farID` term
    // picks the wide seam, and in a left-to-right row the two terms agree and hide that.
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

    // The losing seam is legal too, not one the walk would have thrown away, and both
    // produce this layout, which is why only the seam can be asserted on.
    #expect(insertion?.arrangement.tile(4)?.rect.origin == DisplayPoint(x: 1_000, y: 0))
    #expect(insertion?.arrangement.tile(3)?.rect.origin == DisplayPoint(x: 1_400, y: 0))
    #expect(insertion?.arrangement.tile(2)?.rect.origin == DisplayPoint(x: 2_400, y: 0))
    #expect(insertion.map { ArrangementRules.problems(in: $0.arrangement).isEmpty } == true)
  }

  @Test func aLowerRankedSeamIsUsedWhenTheTopRankedOneIsIllegal() {
    // The top-ranked seam (x at 200, between 1 and 4) leaves the inserted display lying
    // across display 2, so the walk has to fall through to the y seam at 0. Ranking once
    // and taking the winner reported no insert here and the drop sprang back.
    let baseline = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 200, 300)),
      (2, rect(50, -300, 300, 300)),
      (3, rect(200, 300, 300, 300)),
      (4, rect(200, 200, 100, 100)),
    ])
    #expect(ArrangementRules.problems(in: baseline).isEmpty)

    // Far enough from every edge that nothing snaps, so free and snapped are one rect.
    let dragged = rect(75, -50, 300, 300)

    // The layout the top-ranked seam would have produced, and it is illegal, so a
    // policy that ranks once reports no insert. Without this the assertions below
    // would pass for a policy that never ranked that seam first.
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
    // Optional-chained rather than `#require`d: the defect made `insertion` nil, and
    // each expectation below reports a different part of what went wrong.
    #expect(insertion.map { ArrangementRules.problems(in: $0.arrangement).isEmpty } == true)
    #expect(insertion?.arrangement.tile(1)?.rect.origin == DisplayPoint(x: 0, y: 0))
    #expect(insertion?.arrangement.tile(2)?.rect.origin == DisplayPoint(x: 50, y: -600))
    #expect(insertion?.arrangement.tile(3)?.rect.origin == DisplayPoint(x: 75, y: -300))
    #expect(insertion?.arrangement.tile(4)?.rect.origin == DisplayPoint(x: 200, y: 200))
    // AR14 holds through the walk: the display that was main still is.
    #expect(insertion?.arrangement.mainDisplayID == 1)
  }

  @Test func aSeamWhoseLandingWouldMissItsNearDisplayIsNotChosen() {
    // Candidacy is judged on the pre-snap rect but the display lands on the snapped
    // one. The snap pulled this drop 16 points left, which was its whole shared x span
    // with display 2, so the landing would meet it at one corner under a solid guide.
    let baseline = ArrangementFixtures.arrangement([
      (1, rect(400, 296, 200, 200)),
      (2, rect(0, 0, 400, 300)),
      (3, rect(-500, -32, 500, 500)),
      (4, rect(0, 453, 400, 600)),
      (5, rect(-310, 1_053, 500, 300)),
    ])
    #expect(ArrangementRules.problems(in: baseline).isEmpty)

    #expect(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(-484, 94, 500, 500),
      snappedRect: rect(-500, 94, 500, 500),
      into: baseline
    ) == nil)

    // The same drop without the snap keeps those 16 points and inserts, so the nil
    // above is the landing's span deciding it, not a drop that covers no seam.
    #expect(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(-484, 94, 500, 500),
      snappedRect: rect(-484, 94, 500, 500),
      into: baseline
    ) != nil)
  }

  @Test func aDisplayThatIsNotInTheLayoutHasNothingToInsert() {
    // The gap is wider than the dragged display, so the push is zero and the layout
    // is the baseline itself, which is what makes the guard visible: with an unknown
    // id the walk still finds the seam and hands back an insertion missing a display.
    let spacedRow = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(2_000, 0, 1_000, 1_000)),
      (3, rect(3_000, 1_000, 800, 1_000)),
      (4, rect(0, 1_000, 3_000, 1_000)),
    ])
    #expect(ArrangementRules.problems(in: spacedRow).isEmpty)

    #expect(ArrangementInsertPolicy.insertion(
      dragging: 9,
      freeRect: rect(600, 0, 800, 1_000),
      snappedRect: rect(600, 0, 800, 1_000),
      into: spacedRow
    ) == nil)

    // The identical drop by a display the layout holds inserts, so the nil above is
    // the unknown id and nothing else.
    #expect(ArrangementInsertPolicy.insertion(
      dragging: 3,
      freeRect: rect(600, 0, 800, 1_000),
      snappedRect: rect(600, 0, 800, 1_000),
      into: spacedRow
    ) != nil)
  }
}
