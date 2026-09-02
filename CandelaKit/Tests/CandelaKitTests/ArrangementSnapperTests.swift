import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Arrangement snapper")
struct ArrangementSnapperTests {
  private func line(_ result: SnapResult, _ axis: SnapAxis) -> SnapLine? {
    result.lines.first { $0.axis == axis }
  }

  @Test func abutBeatsAlignAtEqualDistance() {
    // S sits at 100…200. The moved display is 100 wide at x = 50: exactly 50 from the
    // abut target (0) and 50 from the align target (100). The ranking key carries
    // `SnapKind`, whose order is its declaration order and nothing else.
    #expect(SnapKind.abut < SnapKind.align)

    let source = ArrangementFixtures.tile(2, ArrangementFixtures.rect(100, 0, 100, 100))

    let result = ArrangementSnapper.snap(
      ArrangementFixtures.rect(50, 0, 100, 100), id: 1, against: [source], threshold: 60
    )

    #expect(result.rect == ArrangementFixtures.rect(0, 0, 100, 100))
    #expect(line(result, .x)?.kind == .abut)
    // The shared edge, not the target: the tile lands at 0 and meets S at 100.
    #expect(line(result, .x)?.position == 100)
    #expect(line(result, .x)?.otherDisplayID == 2)

    // The same tie from the other side, where the abut target is the larger number.
    // Without it the ranking's `target` term decides alone and dropping `kind` is invisible.
    let fromTheRight = ArrangementSnapper.snap(
      ArrangementFixtures.rect(150, 0, 100, 100), id: 1, against: [source], threshold: 60
    )
    #expect(fromTheRight.rect == ArrangementFixtures.rect(200, 0, 100, 100))
    #expect(line(fromTheRight, .x)?.kind == .abut)

    // Positive control — the tie is what abut wins. A strictly nearer align
    // still beats it, so the rule is a tie-break and not a blanket preference.
    let nearerAlign = ArrangementSnapper.snap(
      ArrangementFixtures.rect(60, 0, 100, 100), id: 1, against: [source], threshold: 60
    )
    #expect(nearerAlign.rect == ArrangementFixtures.rect(100, 0, 100, 100))
    #expect(line(nearerAlign, .x)?.kind == .align)
  }

  @Test func aDisplayThatDoesNotCrossOnTheOtherAxisOffersNoAbutCandidate() {
    // Same X geometry as the tie above, but 500 points below S, so the Y spans do not
    // overlap and no abut is possible. Only the align target is left.
    let source = ArrangementFixtures.tile(2, ArrangementFixtures.rect(100, 0, 100, 100))

    let result = ArrangementSnapper.snap(
      ArrangementFixtures.rect(50, 500, 100, 100), id: 1, against: [source], threshold: 60
    )

    #expect(result.rect == ArrangementFixtures.rect(100, 500, 100, 100))
    #expect(result.lines.map(\.kind) == [.align])
    #expect(result.lines.map(\.axis) == [.x])
  }

  @Test func nothingOutsideTheThresholdSnaps() {
    let source = ArrangementFixtures.tile(2, ArrangementFixtures.rect(0, 0, 100, 100))
    // 50 from the nearest X candidate (abut at 100) and 50 from the nearest Y
    // candidate (align at 0).
    let moving = ArrangementFixtures.rect(150, 50, 100, 100)

    let outside = ArrangementSnapper.snap(moving, id: 1, against: [source], threshold: 49)
    #expect(outside.rect == moving)
    #expect(outside.lines.isEmpty)

    // Exactly at the threshold still snaps. The boundary is inclusive by
    // decision, not by accident.
    let atThreshold = ArrangementSnapper.snap(moving, id: 1, against: [source], threshold: 50)
    #expect(atThreshold.rect == ArrangementFixtures.rect(100, 0, 100, 100))
    #expect(atThreshold.lines.count == 2)

    // No neighbours at all is the degenerate case of the same rule.
    let alone = ArrangementSnapper.snap(moving, id: 1, against: [], threshold: 10_000)
    #expect(alone.rect == moving)
    #expect(alone.lines.isEmpty)
  }

  @Test func theResultIsIndependentOfTileArrayOrder() {
    // Two neighbours offer an abut at exactly 50 on X, so the display id is the only
    // tie-break left. On Y all three align at distance 0, exercising it a second time.
    let tiles = [
      ArrangementFixtures.tile(1, ArrangementFixtures.rect(0, 0, 100, 100)),
      ArrangementFixtures.tile(2, ArrangementFixtures.rect(400, 0, 100, 100)),
      ArrangementFixtures.tile(3, ArrangementFixtures.rect(150, 0, 50, 100)),
    ]
    let moving = ArrangementFixtures.rect(250, 0, 100, 100)

    let expected = ArrangementSnapper.snap(moving, id: 9, against: tiles, threshold: 60)
    #expect(expected.rect == ArrangementFixtures.rect(300, 0, 100, 100))
    #expect(line(expected, .x)?.kind == .abut)
    #expect(line(expected, .x)?.otherDisplayID == 2)
    #expect(line(expected, .y)?.otherDisplayID == 1)

    let orders = permutations(tiles)
    #expect(orders.count == 6)
    for order in orders {
      #expect(ArrangementSnapper.snap(moving, id: 9, against: order, threshold: 60) == expected)
    }
  }

  @Test func centreAlignmentOnAnOddDifferenceRoundsDownByOnePoint() {
    // 100 − 51 = 49, so the exact centre alignment is x = 24.5. It lands at 24:
    // one point below, never above.
    let wider = ArrangementFixtures.tile(2, ArrangementFixtures.rect(0, 0, 100, 100))
    let narrowResult = ArrangementSnapper.snap(
      ArrangementFixtures.rect(26, 0, 51, 100), id: 1, against: [wider], threshold: 8
    )
    #expect(narrowResult.rect.x == 24)
    #expect(line(narrowResult, .x)?.kind == .align)
    // The guide runs through the OTHER display's centre, which is the stable one.
    #expect(line(narrowResult, .x)?.position == 50)

    // The mirror image: exact centre −24.5 still rounds down, to −25. Swift's `/`
    // truncates toward zero and gives −24, which makes the direction of the one-point
    // bias depend on which display the user happened to grab.
    let narrower = ArrangementFixtures.tile(2, ArrangementFixtures.rect(0, 0, 51, 100))
    let wideResult = ArrangementSnapper.snap(
      ArrangementFixtures.rect(-23, 0, 100, 100), id: 1, against: [narrower], threshold: 8
    )
    #expect(wideResult.rect.x == -25)

    // Stated as the effect rather than the arithmetic: in both directions the
    // moved display's centre sits half a point below the other display's.
    #expect(Double(narrowResult.rect.x) + 51.0 / 2 == 50.0 - 0.5)
    #expect(Double(wideResult.rect.x) + 100.0 / 2 == 25.5 - 0.5)
  }

  @Test func theCrossingPreconditionIsReadAtThePreSnapPosition() {
    // Reading the precondition after an X snap makes the axes circular. Pre-snap this
    // display shares neither span with S; the X snap brings its span over S's, so a
    // re-read would find a Y abut 5 away and drag the tile up with it.
    let source = ArrangementFixtures.tile(2, ArrangementFixtures.rect(0, 0, 100, 100))

    let result = ArrangementSnapper.snap(
      ArrangementFixtures.rect(105, 105, 50, 100), id: 1, against: [source], threshold: 60
    )

    #expect(result.rect == ArrangementFixtures.rect(50, 105, 50, 100))
    #expect(result.lines.map(\.axis) == [.x])
  }

  @Test func equalWidthsCollapseThreeAlignmentsOntoOneTargetAndTheGuideNamesTheLeadingEdge() {
    // Leading edge, trailing edge and centre ask for the same x at equal widths, so only
    // the guide can differ, and the ranking key's last term decides which is drawn.
    let source = ArrangementFixtures.tile(2, ArrangementFixtures.rect(0, 0, 100, 100))

    let result = ArrangementSnapper.snap(
      ArrangementFixtures.rect(5, 0, 100, 100), id: 1, against: [source], threshold: 8
    )

    #expect(result.rect.x == 0)
    #expect(line(result, .x)?.kind == .align)
    #expect(line(result, .x)?.position == 0)
  }

  @Test func theMovedDisplayIsNeverACandidateAgainstItself() {
    // The canvas passes the whole tile list, including the dragged tile. Its own starting
    // edges sit 40 away, inside the threshold, so failing to filter it drags it back.
    let tiles = [
      ArrangementFixtures.tile(1, ArrangementFixtures.rect(0, 0, 100, 100)),
      ArrangementFixtures.tile(2, ArrangementFixtures.rect(500, 700, 100, 100)),
    ]

    let result = ArrangementSnapper.snap(
      ArrangementFixtures.rect(40, 0, 100, 100), id: 1, against: tiles, threshold: 60
    )

    #expect(result.rect == ArrangementFixtures.rect(40, 0, 100, 100))
    #expect(result.lines.isEmpty)
  }

  @Test func aGuideSpansTheUnionOfTheTwoRectsAlongTheOtherAxis() {
    // A line that reaches only one of the rects reads as belonging to it.
    let source = ArrangementFixtures.tile(2, ArrangementFixtures.rect(0, 0, 100, 100))

    let result = ArrangementSnapper.snap(
      ArrangementFixtures.rect(150, 50, 100, 200), id: 1, against: [source], threshold: 60
    )
    #expect(result.rect == ArrangementFixtures.rect(100, 0, 100, 200))

    // The extent is measured from the SNAPPED rect: pre-snap the moved display
    // reached y = 250 and x = 250, and a guide drawn to there would overhang.
    #expect(line(result, .x)?.from == 0)
    #expect(line(result, .x)?.to == 200)
    #expect(line(result, .y)?.from == 0)
    #expect(line(result, .y)?.to == 200)
  }

  @Test func aSnapThatProducesAnOverlapIsStillApplied() {
    // The snapper does not judge: undoing a snap because it overlaps is the silent
    // auto-correction the overlap-refusal rule forbids. The rules report it and the drop is refused instead.
    let source = ArrangementFixtures.tile(2, ArrangementFixtures.rect(0, 0, 100, 100))
    let result = ArrangementSnapper.snap(
      ArrangementFixtures.rect(28, 28, 50, 50), id: 1, against: [source], threshold: 8
    )

    #expect(result.rect == ArrangementFixtures.rect(25, 25, 50, 50))
    #expect(result.rect.overlaps(source.rect))
  }

  private func permutations(_ tiles: [ArrangementTile]) -> [[ArrangementTile]] {
    guard tiles.count > 1 else { return [tiles] }
    return tiles.indices.flatMap { index -> [[ArrangementTile]] in
      var rest = tiles
      let head = rest.remove(at: index)
      return permutations(rest).map { [head] + $0 }
    }
  }
}
