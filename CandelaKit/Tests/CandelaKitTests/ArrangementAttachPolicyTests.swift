import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Arrangement attach policy")
struct ArrangementAttachPolicyTests {
  private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> DisplayRect {
    ArrangementFixtures.rect(x, y, w, h)
  }

  private var pair: DisplayArrangement {
    ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(1_000, 0, 1_000, 1_000)),
    ])
  }

  /// Optionals are bound with `#require` rather than force-unwrapped, and that
  /// is a rule for the whole file: a force-unwrap trap signal-kills the runner,
  /// so the failure came back as a crash with no test name and every suite that
  /// had not run yet reported nothing. `#require` gives one named failure and
  /// lets the run finish.
  @Test func aDropInOpenSpaceLandsOnTheNearestLegalEdge() throws {
    let attachment = try #require(ArrangementAttachPolicy.attach(
      rect(2_000, -3_000, 1_000, 1_000), id: 2, in: pair, threshold: 80
    ))

    // Up and to the right, but further up than right, so the top edge wins.
    #expect(attachment.rect == rect(0, -1_000, 1_000, 1_000))
    #expect(attachment.line.axis == .y)
    #expect(attachment.line.position == 0)
    #expect(attachment.line.kind == .abut)
    #expect(attachment.line.otherDisplayID == 1)

    // Positive control: leaving display 2 where the pointer left it strands it,
    // which is what the attachment replaces.
    #expect(!ArrangementRules.problems(
      in: pair.moving(2, to: DisplayPoint(x: 2_000, y: -3_000))
    ).isEmpty)
    #expect(ArrangementRules.problems(
      in: pair.moving(2, to: attachment.rect.origin)
    ).isEmpty)
  }

  @Test func aDropPastAnEdgeGoesFlushRatherThanClippingOneCorner() throws {
    // Well below and to the right of display 1. The nearest position keeping any
    // shared edge is y = 999, where the two displays meet over a single point:
    // legal, and it looks like a misfire. Going flush with the nearer end gives
    // the whole edge. This is why the attach rule says NEAR rather than nearest, and the
    // landing here is 999 points off the strictly nearest legal position.
    let attachment = try #require(ArrangementAttachPolicy.attach(
      rect(5_000, 3_000, 1_000, 1_000), id: 2, in: pair, threshold: 80
    ))

    #expect(attachment.rect == rect(1_000, 0, 1_000, 1_000))
    #expect(attachment.rect.y != 999)
  }

  @Test func theNearestPositionIsSkippedWhenSomethingIsAlreadyThere() throws {
    let row = ArrangementFixtures.arrangement([
      (1, rect(0, 0, 1_000, 1_000)),
      (2, rect(1_000, 0, 1_000, 1_000)),
      (3, rect(3_000, 3_000, 1_000, 1_000)),
    ])

    let attachment = try #require(ArrangementAttachPolicy.attach(
      rect(1_100, 100, 1_000, 1_000), id: 3, in: row, threshold: 80
    ))

    // Nearest by a wide margin is display 1's right edge, 100 points away. It
    // is where display 2 already is, so it is skipped and the search continues.
    #expect(ArrangementRules.problems(
      in: row.moving(3, to: DisplayPoint(x: 1_000, y: 100))
    ).contains(.overlap(2, 3)))

    #expect(attachment.rect == rect(2_000, 100, 1_000, 1_000))
    #expect(attachment.line.otherDisplayID == 2)
    #expect(attachment.line.axis == .x)
    #expect(attachment.line.position == 2_000)
    #expect(ArrangementRules.problems(
      in: row.moving(3, to: attachment.rect.origin)
    ).isEmpty)
  }

  @Test func anAttachmentAlreadyNearALinedUpEdgeTidiesOntoIt() throws {
    let tidied = try #require(ArrangementAttachPolicy.attach(
      rect(5_000, 30, 1_000, 1_000), id: 2, in: pair, threshold: 80
    ))
    #expect(tidied.rect == rect(1_000, 0, 1_000, 1_000))

    // Positive control: the tidying is the threshold's doing, not the clamp's.
    // Below the threshold the same drop keeps the 30 points the user left.
    let untidied = try #require(ArrangementAttachPolicy.attach(
      rect(5_000, 30, 1_000, 1_000), id: 2, in: pair, threshold: 10
    ))
    #expect(untidied.rect == rect(1_000, 30, 1_000, 1_000))
  }

  @Test func thereIsNothingToAttachToInALayoutOfOne() {
    let single = ArrangementFixtures.arrangement([(1, rect(0, 0, 1_000, 1_000))])
    #expect(ArrangementAttachPolicy.attach(
      rect(5_000, 5_000, 1_000, 1_000), id: 1, in: single, threshold: 80
    ) == nil)
  }
}
