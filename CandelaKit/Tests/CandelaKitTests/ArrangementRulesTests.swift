import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Arrangement rules")
struct ArrangementRulesTests {
  @Test func cornerOnlyContactIsDisconnected() {
    let layout = ArrangementFixtures.arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      (2, DisplayRect(x: 100, y: 100, width: 100, height: 100)),
    ])
    #expect(ArrangementRules.problems(in: layout) == [.disconnected(2)])
    #expect(!ArrangementRules.isValid(layout))

    // The built-in tucked under the left end of the ultrawide: it looks like a normal
    // desktop but meets at exactly one point, so macOS treats it as a gap.
    let tucked = ArrangementFixtures.arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 3440, height: 1440)),
      (2, DisplayRect(x: -1470, y: 1440, width: 1470, height: 956)),
    ])
    #expect(ArrangementRules.problems(in: tucked) == [.disconnected(2)])
  }

  @Test func aZeroLengthSharedEdgeIsNotAdjacency() {
    // The vertical edges are collinear but their spans meet at exactly one point.
    let layout = ArrangementFixtures.arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      (2, DisplayRect(x: 100, y: -50, width: 100, height: 50)),
    ])
    #expect(ArrangementRules.problems(in: layout) == [.disconnected(2)])

    // One point of span is enough, and that is the whole difference.
    let overlapping = ArrangementFixtures.arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      (2, DisplayRect(x: 100, y: -50, width: 100, height: 51)),
    ])
    #expect(ArrangementRules.problems(in: overlapping).isEmpty)
  }

  @Test func anOverlapIsReportedOncePerPairLowerIDFirst() {
    let pair = ArrangementFixtures.arrangement([
      (7, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      (3, DisplayRect(x: 50, y: 50, width: 100, height: 100)),
    ])
    #expect(ArrangementRules.problems(in: pair) == [.overlap(3, 7)])

    // Three mutually overlapping displays are three pairs, not six, and the
    // pairs come out in a reproducible order.
    let pile = ArrangementFixtures.arrangement([
      (9, DisplayRect(x: 20, y: 20, width: 100, height: 100)),
      (3, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      (5, DisplayRect(x: 10, y: 10, width: 100, height: 100)),
    ])
    #expect(ArrangementRules.problems(in: pile) == [.overlap(3, 5), .overlap(3, 9), .overlap(5, 9)])
  }

  @Test func overlapsSuppressConnectivityReporting() {
    // 1 and 2 overlap; 3 is nowhere near either. Both are real, but the overlap is the
    // cause the user has to fix and reporting both for one drag reads as noise.
    let layout = ArrangementFixtures.arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      (2, DisplayRect(x: 50, y: 0, width: 100, height: 100)),
      (3, DisplayRect(x: 5_000, y: 5_000, width: 100, height: 100)),
    ])
    #expect(ArrangementRules.problems(in: layout) == [.overlap(1, 2)])

    // Separate the overlap and the disconnection surfaces on its own.
    let separated = layout.moving(2, to: DisplayPoint(x: 100, y: 0))
    #expect(ArrangementRules.problems(in: separated) == [.disconnected(3)])
  }

  @Test func aSingleDisplayIsAlwaysValid() {
    #expect(ArrangementRules.problems(in: ArrangementFixtures.arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 3440, height: 1440)),
    ])).isEmpty)
    // Even away from the origin — one display cannot be disconnected from
    // anything, and there is no pair to overlap.
    #expect(ArrangementRules.problems(in: ArrangementFixtures.arrangement([
      (1, DisplayRect(x: -900, y: 700, width: 1470, height: 956)),
    ])).isEmpty)
    #expect(ArrangementRules.isValid(DisplayArrangement(tiles: [])))
  }

  @Test func aThreeDisplayChainIsConnectedEvenThoughTheEndsDoNotTouch() {
    let a = DisplayRect(x: 0, y: 0, width: 100, height: 100)
    let b = DisplayRect(x: 100, y: 0, width: 100, height: 100)
    let c = DisplayRect(x: 200, y: 0, width: 100, height: 100)
    // Without this the suite would pass on a pairwise "everything touches
    // everything" rule, which is not what connectivity means.
    #expect(!a.touches(c))

    #expect(ArrangementRules.problems(in: ArrangementFixtures.arrangement([(1, a), (2, b), (3, c)])).isEmpty)

    // Four long, and through a corner-free staircase, so the fill really is
    // transitive rather than two hops deep.
    let staircase = ArrangementFixtures.arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      (2, DisplayRect(x: 100, y: 50, width: 100, height: 100)),
      (3, DisplayRect(x: 200, y: 100, width: 100, height: 100)),
      (4, DisplayRect(x: 300, y: 150, width: 100, height: 100)),
    ])
    #expect(ArrangementRules.problems(in: staircase).isEmpty)
  }

  @Test func movingTheMiddleDisplayOfARowStrandsTheFarOne() {
    // Connectivity is checked on the whole arrangement, so the display that did not
    // move is named too.
    let row = ArrangementFixtures.arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      (2, DisplayRect(x: 100, y: 0, width: 100, height: 100)),
      (3, DisplayRect(x: 200, y: 0, width: 100, height: 100)),
    ])
    #expect(ArrangementRules.problems(in: row).isEmpty)

    let broken = row.moving(2, to: DisplayPoint(x: 0, y: 5_000))
    #expect(ArrangementRules.problems(in: broken) == [.disconnected(2), .disconnected(3)])
  }

  @Test func theStrandedDisplaysAreTheOnesOutsideTheLargestGroup() {
    // 2 and 3 are joined; 1 is alone — even though 1 is the main display and the
    // lowest id. Blaming the smaller group names the fewest tiles.
    let layout = ArrangementFixtures.arrangement([
      (1, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      (2, DisplayRect(x: 500, y: 0, width: 100, height: 100)),
      (3, DisplayRect(x: 600, y: 0, width: 100, height: 100)),
    ])
    #expect(ArrangementRules.problems(in: layout) == [.disconnected(1)])
  }

  @Test func equalSizedGroupsAreBrokenByTheLowestID() {
    // Two pairs, neither larger. Nothing in the geometry prefers one, so the
    // tie-break is stated rather than left to iteration order.
    let layout = ArrangementFixtures.arrangement([
      (4, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
      (9, DisplayRect(x: 100, y: 0, width: 100, height: 100)),
      (2, DisplayRect(x: 0, y: 500, width: 100, height: 100)),
      (6, DisplayRect(x: 100, y: 500, width: 100, height: 100)),
    ])
    #expect(ArrangementRules.problems(in: layout) == [.disconnected(4), .disconnected(9)])
  }
}
