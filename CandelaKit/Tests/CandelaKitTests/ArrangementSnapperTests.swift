import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Arrangement snapper")
struct ArrangementSnapperTests {
  private func tile(_ id: CGDirectDisplayID, _ rect: DisplayRect) -> ArrangementTile {
    ArrangementTile(
      id: id,
      identity: .init(vendor: id, model: id, serial: id, isBuiltIn: false),
      name: "Display \(id)",
      rect: rect,
      mirroredIDs: []
    )
  }

  private func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> DisplayRect {
    DisplayRect(x: x, y: y, width: width, height: height)
  }

  private func line(_ result: SnapResult, _ axis: SnapAxis) -> SnapLine? {
    result.lines.first { $0.axis == axis }
  }

  @Test func abutBeatsAlignAtEqualDistance() {
    // S sits at 100…200. The moved display is 100 wide at x = 50, which is
    // exactly 50 from the abut target (0, landing it edge-to-edge against S's
    // left side) and exactly 50 from the align target (100, its left edge lined
    // up with S's).
    // Stated directly as well as through the geometry: the ranking key carries
    // `SnapKind`, whose order is its declaration order and nothing else.
    #expect(SnapKind.abut < SnapKind.align)

    let source = tile(2, rect(100, 0, 100, 100))

    let result = ArrangementSnapper.snap(
      rect(50, 0, 100, 100), id: 1, against: [source], threshold: 60
    )

    #expect(result.rect == rect(0, 0, 100, 100))
    #expect(line(result, .x)?.kind == .abut)
    // The shared edge, not the target: the tile lands at 0 and meets S at 100.
    #expect(line(result, .x)?.position == 100)
    #expect(line(result, .x)?.otherDisplayID == 2)

    // The same tie from the other side, where the abut target (200) is the
    // LARGER number. Without this the ranking's `target` term would decide the
    // case above on its own and dropping `kind` from the key would go unnoticed.
    let fromTheRight = ArrangementSnapper.snap(
      rect(150, 0, 100, 100), id: 1, against: [source], threshold: 60
    )
    #expect(fromTheRight.rect == rect(200, 0, 100, 100))
    #expect(line(fromTheRight, .x)?.kind == .abut)

    // Positive control — the tie is what abut wins. A strictly nearer align
    // still beats it, so the rule is a tie-break and not a blanket preference.
    let nearerAlign = ArrangementSnapper.snap(
      rect(60, 0, 100, 100), id: 1, against: [source], threshold: 60
    )
    #expect(nearerAlign.rect == rect(100, 0, 100, 100))
    #expect(line(nearerAlign, .x)?.kind == .align)
  }

  @Test func aDisplayThatDoesNotCrossOnTheOtherAxisOffersNoAbutCandidate() {
    // Same X geometry as the tie above, but the moved display is 500 points
    // below S, so their Y spans do not overlap and the two cannot abut on X at
    // all. The abut target (0) disappears and the align target (100) — the same
    // distance away, and the loser of the tie above — is what is left.
    let source = tile(2, rect(100, 0, 100, 100))

    let result = ArrangementSnapper.snap(
      rect(50, 500, 100, 100), id: 1, against: [source], threshold: 60
    )

    #expect(result.rect == rect(100, 500, 100, 100))
    #expect(result.lines.map(\.kind) == [.align])
    #expect(result.lines.map(\.axis) == [.x])
  }

  @Test func nothingOutsideTheThresholdSnaps() {
    let source = tile(2, rect(0, 0, 100, 100))
    // 50 from the nearest X candidate (abut at 100) and 50 from the nearest Y
    // candidate (align at 0).
    let moving = rect(150, 50, 100, 100)

    let outside = ArrangementSnapper.snap(moving, id: 1, against: [source], threshold: 49)
    #expect(outside.rect == moving)
    #expect(outside.lines.isEmpty)

    // Exactly at the threshold still snaps. The boundary is inclusive by
    // decision, not by accident.
    let atThreshold = ArrangementSnapper.snap(moving, id: 1, against: [source], threshold: 50)
    #expect(atThreshold.rect == rect(100, 0, 100, 100))
    #expect(atThreshold.lines.count == 2)

    // No neighbours at all is the degenerate case of the same rule.
    let alone = ArrangementSnapper.snap(moving, id: 1, against: [], threshold: 10_000)
    #expect(alone.rect == moving)
    #expect(alone.lines.isEmpty)
  }

  @Test func theResultIsIndependentOfTileArrayOrder() {
    // Two neighbours offer an abut at exactly 50 on X — display 2 from the
    // right, display 3 from the left — so the winner is decided by the display
    // id and by nothing else. On Y all three offer an align at distance 0, which
    // exercises the same tie-break a second time.
    let tiles = [
      tile(1, rect(0, 0, 100, 100)),
      tile(2, rect(400, 0, 100, 100)),
      tile(3, rect(150, 0, 50, 100)),
    ]
    let moving = rect(250, 0, 100, 100)

    let expected = ArrangementSnapper.snap(moving, id: 9, against: tiles, threshold: 60)
    #expect(expected.rect == rect(300, 0, 100, 100))
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
    let wider = tile(2, rect(0, 0, 100, 100))
    let narrowResult = ArrangementSnapper.snap(
      rect(26, 0, 51, 100), id: 1, against: [wider], threshold: 8
    )
    #expect(narrowResult.rect.x == 24)
    #expect(line(narrowResult, .x)?.kind == .align)
    // The guide runs through the OTHER display's centre, which is the stable one.
    #expect(line(narrowResult, .x)?.position == 50)

    // The mirror image: 51 − 100 = −49, exact centre −24.5, and it still rounds
    // DOWN, to −25. Swift's `/` truncates toward zero and would give −24 here,
    // which would make the direction of the one-point bias depend on which of
    // the two displays the user happened to grab.
    let narrower = tile(2, rect(0, 0, 51, 100))
    let wideResult = ArrangementSnapper.snap(
      rect(-23, 0, 100, 100), id: 1, against: [narrower], threshold: 8
    )
    #expect(wideResult.rect.x == -25)

    // Stated as the effect rather than the arithmetic: in both directions the
    // moved display's centre sits half a point below the other display's.
    #expect(Double(narrowResult.rect.x) + 51.0 / 2 == 50.0 - 0.5)
    #expect(Double(wideResult.rect.x) + 100.0 / 2 == 25.5 - 0.5)
  }

  @Test func theCrossingPreconditionIsReadAtThePreSnapPosition() {
    // §3.4: reading it after an X snap would make the two axes circular — which
    // one was evaluated first would change the answer.
    //
    // Pre-snap the moved display shares neither span with S. Its X aligns to S's
    // right edge (50), which brings its X span to 50…100, overlapping S's. An
    // implementation that re-read the precondition would then find a Y abut at
    // 100, only 5 away, and drag the tile up with it.
    let source = tile(2, rect(0, 0, 100, 100))

    let result = ArrangementSnapper.snap(
      rect(105, 105, 50, 100), id: 1, against: [source], threshold: 60
    )

    #expect(result.rect == rect(50, 105, 50, 100))
    #expect(result.lines.map(\.axis) == [.x])
  }

  @Test func equalWidthsCollapseThreeAlignmentsOntoOneTargetAndTheGuideNamesTheLeadingEdge() {
    // Leading edge, trailing edge and centre all ask for the same x when the two
    // displays are the same width, so only the guide can differ. Which one gets
    // drawn is decided by the ranking key's last term, not by which candidate
    // happened to be built first.
    let source = tile(2, rect(0, 0, 100, 100))

    let result = ArrangementSnapper.snap(
      rect(5, 0, 100, 100), id: 1, against: [source], threshold: 8
    )

    #expect(result.rect.x == 0)
    #expect(line(result, .x)?.kind == .align)
    #expect(line(result, .x)?.position == 0)
  }

  @Test func theMovedDisplayIsNeverACandidateAgainstItself() {
    // The canvas passes the whole tile list, which includes the tile being
    // dragged. Its own starting edges sit 40 away — inside the threshold — so
    // failing to filter it would drag every display back toward where it began.
    let tiles = [tile(1, rect(0, 0, 100, 100)), tile(2, rect(500, 700, 100, 100))]

    let result = ArrangementSnapper.snap(
      rect(40, 0, 100, 100), id: 1, against: tiles, threshold: 60
    )

    #expect(result.rect == rect(40, 0, 100, 100))
    #expect(result.lines.isEmpty)
  }

  @Test func aGuideSpansTheUnionOfTheTwoRectsAlongTheOtherAxis() {
    // A line that reaches only one of the rects reads as belonging to it.
    let source = tile(2, rect(0, 0, 100, 100))

    let result = ArrangementSnapper.snap(
      rect(150, 50, 100, 200), id: 1, against: [source], threshold: 60
    )
    #expect(result.rect == rect(100, 0, 100, 200))

    // The extent is measured from the SNAPPED rect: pre-snap the moved display
    // reached y = 250 and x = 250, and a guide drawn to there would overhang.
    #expect(line(result, .x)?.from == 0)
    #expect(line(result, .x)?.to == 200)
    #expect(line(result, .y)?.from == 0)
    #expect(line(result, .y)?.to == 200)
  }

  @Test func aSnapThatProducesAnOverlapIsStillApplied() {
    // §3.4's last paragraph: the snapper does not judge. Undoing a snap because
    // it overlaps would be the silent auto-correction AR7 forbids — the rules
    // report it, the tile renders red, and the drop is refused instead.
    let source = tile(2, rect(0, 0, 100, 100))
    let result = ArrangementSnapper.snap(
      rect(28, 28, 50, 50), id: 1, against: [source], threshold: 8
    )

    #expect(result.rect == rect(25, 25, 50, 50))
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
