import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Arrangement drag policy")
struct ArrangementDragPolicyTests {
  /// Two 1000×1000 displays, abutting. At scale 0.1 one canvas point is ten
  /// display points, so the default 8-point threshold is 80 display points.
  private var pair: DisplayArrangement {
    ArrangementFixtures.arrangement([
      (1, ArrangementFixtures.rect(0, 0, 1_000, 1_000)),
      (2, ArrangementFixtures.rect(1_000, 0, 1_000, 1_000)),
    ])
  }

  private var tenToOne: CanvasTransform {
    CanvasTransform(scale: 0.1, offsetX: 0, offsetY: 0)
  }

  private func originOf(_ proposal: ArrangementProposal?, _ id: CGDirectDisplayID) -> DisplayPoint? {
    proposal?.arrangement.tile(id)?.rect.origin
  }

  @Test func proposingForAnUnknownDisplayReturnsNil() {
    #expect(ArrangementDragPolicy.propose(
      dragging: 99, by: CanvasPoint(x: 50, y: 0), from: pair, transform: tenToOne
    ) == nil)

    // And for any display when the layout is empty — there is nothing to drag.
    #expect(ArrangementDragPolicy.propose(
      dragging: 1, by: .zero, from: DisplayArrangement(tiles: []), transform: tenToOne
    ) == nil)
  }

  @Test func theProposalIsComputedFromTheBaselineNotTheLiveArrangement() {
    let translation = CanvasPoint(x: 50, y: 0)
    let baseline = pair

    let first = ArrangementDragPolicy.propose(
      dragging: 2, by: translation, from: baseline, transform: tenToOne
    )
    let second = ArrangementDragPolicy.propose(
      dragging: 2, by: translation, from: baseline, transform: tenToOne
    )

    #expect(first == second)
    #expect(originOf(first, 2) == DisplayPoint(x: 1_500, y: 0))
    #expect(first?.movedID == 2)
    #expect(first?.baseline == baseline)

    // Positive control: the assertion above has teeth only because feeding the
    // policy its OWN output moves the display a second time. `.onChanged` fires
    // every frame with a translation measured from the drag's start, so a policy
    // that folded its result back in would run away from the pointer.
    let folded = ArrangementDragPolicy.propose(
      dragging: 2, by: translation, from: first!.arrangement, transform: tenToOne
    )
    #expect(originOf(folded, 2) == DisplayPoint(x: 2_000, y: 0))
  }

  @Test func oneRoundingNotTwo() {
    // Far enough apart that nothing is within the snap threshold, so the origin
    // reported is the translation arithmetic and nothing else.
    let baseline = ArrangementFixtures.arrangement([
      (1, ArrangementFixtures.rect(0, 0, 1_000, 1_000)),
      (2, ArrangementFixtures.rect(5_000, 0, 1_000, 1_000)),
    ])
    // A non-integral offset in display points, which is what makes the two
    // routes disagree. `fitting` produces one of these for almost every real
    // arrangement.
    let transform = CanvasTransform(scale: 0.1, offsetX: 0.05, offsetY: 0)
    let translation = CanvasPoint(x: 0.5, y: 0)

    // Positive control for §1.5: converting the gesture's start point and its
    // current point separately and subtracting really does land a point away
    // from converting the translation once. The drag has moved 5 display
    // points; the two-rounding route claims 6.
    let start = CanvasPoint(x: 0, y: 0)
    let twoRoundings = transform.displayPoint(CanvasPoint(x: start.x + translation.x, y: start.y)).x
      - transform.displayPoint(start).x
    #expect(twoRoundings == 6)
    #expect(transform.displayDistance(translation.x) == 5)

    let proposal = ArrangementDragPolicy.propose(
      dragging: 2, by: translation, from: baseline, transform: transform
    )
    #expect(originOf(proposal, 2) == DisplayPoint(x: 5_005, y: 0))

    // And the same total reached in ten increments against the FROZEN baseline
    // lands where one large translation does. A per-call rounding would drift,
    // and the drift never self-corrects over a session.
    var cumulative = 0.0
    var incremental: ArrangementProposal?
    for _ in 0 ..< 10 {
      cumulative += 1.234
      incremental = ArrangementDragPolicy.propose(
        dragging: 2, by: CanvasPoint(x: cumulative, y: 0), from: baseline, transform: transform
      )
      #expect(
        originOf(incremental, 2)?.x == 5_000 + transform.displayDistance(cumulative),
        "increment to \(cumulative) rounded more than once"
      )
    }
    let single = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 12.34, y: 0), from: baseline, transform: transform
    )
    #expect(incremental?.arrangement == single?.arrangement)
  }

  @Test func aProposalThatOverlapsIsReturnedButNotValid() {
    // 50 canvas points left = 500 display points, which buries display 2 halfway
    // into display 1 and is nowhere near a snap candidate.
    let proposal = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: -50, y: 0), from: pair, transform: tenToOne
    )

    // Returned, and carrying the overlapping position: the tile has to render
    // where the pointer is, or the user finds out only on release. AR7 springs
    // it back at the canvas, not here.
    #expect(proposal != nil)
    #expect(originOf(proposal, 2) == DisplayPoint(x: 500, y: 0))
    #expect(proposal?.problems == [.overlap(1, 2)])
    #expect(proposal?.isValid == false)
    #expect(proposal?.changesArrangement == true)
    #expect(proposal?.isCommittable == false)
  }

  @Test func snapLinesAreEmptyWhenNothingIsWithinThreshold() {
    let proposal = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 50, y: 50), from: pair, transform: tenToOne
    )

    #expect(originOf(proposal, 2) == DisplayPoint(x: 1_500, y: 500))
    #expect(proposal?.lines.isEmpty == true)

    // Positive control: the same drag stopped inside the threshold does produce
    // a guide, so the emptiness above is about distance and not about the guides
    // never being built.
    let near = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 7, y: 0), from: pair, transform: tenToOne
    )
    #expect(originOf(near, 2) == DisplayPoint(x: 1_000, y: 0))
    #expect(near?.lines.contains { $0.kind == .abut } == true)
  }

  @Test func theSnapThresholdIsConvertedThroughTheTransform() {
    // §3.3. The same 100-display-point gap snaps on a zoomed-out map and does
    // not on a zoomed-in one, because 8 canvas points is worth 160 display
    // points at one scale and 40 at the other. A hardcoded display-point
    // threshold would answer identically in both.
    let zoomedOut = CanvasTransform(scale: 0.05, offsetX: 0, offsetY: 0)
    let zoomedIn = CanvasTransform(scale: 0.2, offsetX: 0, offsetY: 0)
    #expect(zoomedOut.displayDistance(ArrangementDragPolicy.snapThresholdCanvasPoints) == 160)
    #expect(zoomedIn.displayDistance(ArrangementDragPolicy.snapThresholdCanvasPoints) == 40)

    let out = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 5, y: 0), from: pair, transform: zoomedOut
    )
    let inn = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 20, y: 0), from: pair, transform: zoomedIn
    )

    #expect(originOf(out, 2) == DisplayPoint(x: 1_000, y: 0)) // pulled back into the abut
    #expect(originOf(inn, 2) == DisplayPoint(x: 1_100, y: 0)) // left where it was dropped
  }

  @Test func theConvertedThresholdNeverFallsBelowOnePoint() {
    // Zoomed in past 16 canvas points per display point, 8 canvas points
    // converts to 0 — a threshold that admits an exact hit and nothing either
    // side of it. The floor keeps the single point of tolerance display space
    // has to give.
    let zoomed = CanvasTransform(scale: 20, offsetX: 0, offsetY: 0)
    #expect(zoomed.displayDistance(ArrangementDragPolicy.snapThresholdCanvasPoints) == 0)

    let oneOff = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 20, y: 0), from: pair, transform: zoomed
    )
    #expect(zoomed.displayDistance(20) == 1) // the drag moved exactly one point
    #expect(originOf(oneOff, 2) == DisplayPoint(x: 1_000, y: 0))

    // And a negative threshold, which would otherwise admit nothing at all, is
    // held to the same floor rather than silently disabling snapping.
    let negative = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 0.1, y: 0), from: pair,
      transform: tenToOne, snapThreshold: -100
    )
    #expect(originOf(negative, 2) == DisplayPoint(x: 1_000, y: 0))
  }

  @Test func theTransformIsUsedAsGivenAndNeverRefitted() {
    // AR2. Refitting to the arrangement's bounds mid-drag rescales the whole map
    // under the pointer every frame. The scale below is deliberately not the one
    // `fitting` would produce for this arrangement, so a refit changes the
    // answer.
    let canvas = CanvasSize(width: 560, height: 320)
    let refitted = CanvasTransform.fitting(pair.bounds, in: canvas, margin: 14)
    #expect(refitted.scale != tenToOne.scale)

    let proposal = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 50, y: 0), from: pair, transform: tenToOne
    )

    #expect(originOf(proposal, 2) == DisplayPoint(x: 1_500, y: 0))
    #expect(1_000 + refitted.displayDistance(50) != 1_500)
  }

  @Test func aDragThatEndsWhereItStartedIsValidButNotCommittable() {
    let proposal = ArrangementDragPolicy.propose(
      dragging: 2, by: .zero, from: pair, transform: tenToOne
    )

    #expect(proposal?.arrangement == pair)
    #expect(proposal?.isValid == true)
    #expect(proposal?.changesArrangement == false)
    #expect(proposal?.isCommittable == false)

    // The seam this exists for: `ArrangementPreviewSession.begin` refuses a
    // no-op with `.illegalArgument`, because `ArrangementPlan` cannot be built
    // from one. A caller that asked only `isValid` would send it anyway and read
    // the refusal as a failure.
    #expect(ArrangementPlan(applying: proposal!.arrangement, to: proposal!.baseline) == nil)

    // Display 2 lifted to sit on top of display 1 instead of beside it: a real
    // change, and a legal one.
    let moved = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: -100, y: -100), from: pair, transform: tenToOne
    )
    #expect(originOf(moved, 2) == DisplayPoint(x: 0, y: -1_000))
    #expect(moved?.isCommittable == true)
    #expect(ArrangementPlan(applying: moved!.arrangement, to: moved!.baseline) != nil)
  }

  @Test func aDragThatStrandsADisplayItNeverTouchedNamesThatDisplayToo() {
    // §3.5: connectivity is judged on the WHOLE proposed arrangement. Pulling
    // the middle display out of a row of three disconnects the far one, which
    // the user never touched and has to be shown.
    let row = ArrangementFixtures.arrangement([
      (1, ArrangementFixtures.rect(0, 0, 1_000, 1_000)),
      (2, ArrangementFixtures.rect(1_000, 0, 1_000, 1_000)),
      (3, ArrangementFixtures.rect(2_000, 0, 1_000, 1_000)),
    ])

    let proposal = ArrangementDragPolicy.propose(
      dragging: 2, by: CanvasPoint(x: 0, y: 500), from: row, transform: tenToOne
    )

    #expect(originOf(proposal, 2) == DisplayPoint(x: 1_000, y: 5_000))
    #expect(proposal?.problems == [.disconnected(2), .disconnected(3)])
    #expect(proposal?.isValid == false)
  }
}
