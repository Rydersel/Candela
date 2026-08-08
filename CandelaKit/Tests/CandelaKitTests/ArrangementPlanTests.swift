import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

enum ArrangementFixtures {
  static func tile(
    _ id: CGDirectDisplayID,
    _ rect: DisplayRect,
    mirroredIDs: [CGDirectDisplayID] = []
  ) -> ArrangementTile {
    ArrangementTile(
      id: id,
      identity: .init(vendor: id, model: id, serial: id, isBuiltIn: false),
      name: "Display \(id)",
      rect: rect,
      mirroredIDs: mirroredIDs
    )
  }

  static func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> DisplayRect {
    DisplayRect(x: x, y: y, width: width, height: height)
  }

  static func arrangement(_ tiles: [(CGDirectDisplayID, DisplayRect)]) -> DisplayArrangement {
    DisplayArrangement(tiles: tiles.map { tile($0.0, $0.1) })
  }

  /// Two 1920×1080 displays sharing their full vertical edge — gapless,
  /// non-overlapping, so `expectsExactOrigins` holds.
  static var pair: DisplayArrangement {
    DisplayArrangement(tiles: [
      tile(1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
      tile(2, DisplayRect(x: 1920, y: 0, width: 1920, height: 1080)),
    ])
  }
}

/// Records what was applied so the tests can assert on scope, and moves its own
/// layout to match — a fake that reported the pre-apply arrangement forever
/// would let every "reconcile after the apply" test pass vacuously.
///
/// `@unchecked Sendable` is justified by confinement: every stored property
/// lives behind `lock` and the accessors below are the only way in. The tests
/// need that because `ArrangementPreviewSession` (Task 10) is an actor — its
/// calls into this fake run on the actor's executor while the test body reads
/// `applied` from its own task.
final class FakeArrangementConfigurator: DisplayArrangementConfiguring, @unchecked Sendable {
  struct Applied: Equatable {
    let plan: ArrangementPlan
    let scope: DisplayConfigScope
  }

  private let lock = NSLock()
  private var _arrangement = DisplayArrangement(tiles: [])
  private var _applied: [Applied] = []
  private var _failWith: DisplayConfigError?
  private var _divergeNextApplyTo: [CGDirectDisplayID: DisplayPoint]?
  private var _onlineDisplays: [ConfiguredDisplay]?

  /// What `currentArrangement()` reports. Settable because a preview captures
  /// the live layout before every apply.
  var arrangement: DisplayArrangement {
    get { lock.withLock { _arrangement } }
    set { lock.withLock { _arrangement = newValue } }
  }

  var applied: [Applied] { lock.withLock { _applied } }

  var failWith: DisplayConfigError? {
    get { lock.withLock { _failWith } }
    set { lock.withLock { _failWith = newValue } }
  }

  /// Accept the plan, commit it, and put the machine somewhere ELSE: the origin
  /// each listed display ends up at, overriding what was requested. Anything
  /// absent from the map follows the plan.
  ///
  /// This is #53 in the shape arrangement takes it — CoreGraphics returning
  /// `.success` from every stage and from the complete while achieving
  /// something else. ONE-SHOT, consumed by the apply it diverts, because the
  /// point of a retry test is that the retry LANDS; a permanently diverting
  /// fake would prove a loop rather than a recovery.
  var divergeNextApplyTo: [CGDirectDisplayID: DisplayPoint]? {
    get { lock.withLock { _divergeNextApplyTo } }
    set { lock.withLock { _divergeNextApplyTo = newValue } }
  }

  /// Online displays this fake reports INSTEAD of the ones its tiles imply.
  /// Settable so a test can express the case the paired read exists for: a
  /// display that is attached and has no tile, which is what an unreadable
  /// `CGDisplayBounds` produces. `nil` derives them from the tiles, which is the
  /// ordinary state and keeps every existing test's fake complete.
  var onlineDisplays: [ConfiguredDisplay]? {
    get { lock.withLock { _onlineDisplays } }
    set { lock.withLock { _onlineDisplays = newValue } }
  }

  func currentArrangement() -> DisplayArrangement { arrangement }

  func currentTopology() -> (displays: [ConfiguredDisplay], arrangement: DisplayArrangement) {
    let live = arrangement
    let derived = live.tiles.map {
      ConfiguredDisplay(id: $0.id, identity: $0.identity, name: $0.name, isBuiltIn: false)
    }
    return (onlineDisplays ?? derived, live)
  }

  func apply(_ plan: ArrangementPlan, scope: DisplayConfigScope) throws -> DisplayArrangement {
    try lock.withLock {
      // BEFORE any state change, because every failure production can inject
      // here — a failed begin, a failed stage, a failed complete — cancels the
      // transaction and leaves the machine where it was.
      if let _failWith { throw _failWith }

      let diverted = _divergeNextApplyTo
      _divergeNextApplyTo = nil
      let requested = Dictionary(
        uniqueKeysWithValues: plan.changes.map { ($0.id, $0.origin) }
      )
      _applied.append(Applied(plan: plan, scope: scope))
      _arrangement = DisplayArrangement(tiles: _arrangement.tiles.map { tile in
        guard let origin = diverted?[tile.id] ?? requested[tile.id] else { return tile }
        return ArrangementTile(
          id: tile.id,
          identity: tile.identity,
          name: tile.name,
          rect: tile.rect.moved(to: origin),
          mirroredIDs: tile.mirroredIDs
        )
      })

      // THE SAME post-commit check production runs, on the same rule, and
      // deliberately LAST: CoreGraphics committed, so the apply is recorded and
      // the layout has moved before this throws. A fake that unwound here would
      // let a session test "prove" that a divergent apply changed nothing,
      // which is the one thing #53 established it does not.
      if ArrangementVerification.unhonoured(plan: plan, achieved: _arrangement) != nil {
        throw DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
      }
      return _arrangement
    }
  }
}

@Suite("Arrangement plan (AR4, AR6)")
struct ArrangementPlanTests {
  // MARK: - What refuses to become a plan

  /// The proposal type is Task 6 and does not exist yet, so "a no-op proposal"
  /// is expressed as the arrangement a no-op proposal would carry: one equal to
  /// the baseline.
  @Test func aNoOpProposalProducesNoPlan() {
    #expect(ArrangementPlan(applying: ArrangementFixtures.pair, to: ArrangementFixtures.pair) == nil)
    // …including the degenerate one, which is what keeps `changes` non-empty for
    // every plan that exists: an empty arrangement can only pair with an empty
    // baseline, since the display sets must match.
    #expect(ArrangementPlan(
      applying: DisplayArrangement(tiles: []), to: DisplayArrangement(tiles: [])
    ) == nil)
  }

  /// Equality is exact and NOT up to translation. `makingMain` moves nothing
  /// relative to anything, and is still the change that moves the menu bar.
  @Test func aPureTranslationOfTheBaselineIsStillAPlan() throws {
    let baseline = ArrangementFixtures.pair
    let plan = try #require(ArrangementPlan(applying: baseline.makingMain(2), to: baseline))
    #expect(plan.requestedMain == 2)
    #expect(plan.changes == [
      DisplayOriginChange(id: 1, origin: DisplayPoint(x: -1920, y: 0)),
      DisplayOriginChange(id: 2, origin: .zero),
    ])
  }

  @Test func aPlanForADifferentDisplaySetIsRefused() {
    let baseline = ArrangementFixtures.pair
    let arrived = DisplayArrangement(tiles: baseline.tiles + [
      ArrangementFixtures.tile(3, DisplayRect(x: 3840, y: 0, width: 1920, height: 1080)),
    ])
    #expect(ArrangementPlan(applying: arrived, to: baseline) == nil)
    #expect(ArrangementPlan(applying: baseline, to: arrived) == nil)
  }

  /// `CGConfigureDisplayOrigin` takes `int32_t`. An origin that does not fit is
  /// not a request that can be made, so it is refused where it is expressible
  /// rather than trapped on at the boundary.
  @Test func anOriginOutsideInt32IsRefused() {
    let baseline = DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: 0, y: 0, width: 100, height: 100)),
    ])
    let tooFar = DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: Int(Int32.max) + 1, y: 0, width: 100, height: 100)),
    ])
    #expect(ArrangementPlan(applying: tooFar, to: baseline) == nil)
  }

  // MARK: - Moving the main display (the anchoring rule)

  /// Measured live on CoreGraphics (2026-08-07): a layout with no tile at
  /// (0,0) is not a request CG can honour. The global space is anchored on the
  /// main display, so a write to the main display's own origin is silently
  /// dropped; every stage and the complete return success and nothing moves
  /// (the #53 accept-and-ignore class). Moving the main display must therefore
  /// be expressed re-anchored on the baseline's main: the same relative
  /// layout, with every OTHER display moved by the inverse delta.
  @Test func movingTheMainDisplayReanchorsThePlanOnTheBaselineMain() throws {
    let baseline = ArrangementFixtures.pair
    // The user drags the main display up; nothing sits at (0,0) any more.
    let dragged = baseline.moving(1, to: DisplayPoint(x: 0, y: -1080))
    let plan = try #require(ArrangementPlan(applying: dragged, to: baseline))
    #expect(plan.requestedMain == 1)
    #expect(plan.changes == [
      DisplayOriginChange(id: 1, origin: .zero),
      DisplayOriginChange(id: 2, origin: DisplayPoint(x: 1920, y: 1080)),
    ])
    #expect(plan.arrangement.relativeLayout == dragged.relativeLayout)
  }

  /// An unanchored translation of the whole layout moves nothing relative to
  /// anything and names no new main, so once it is re-anchored it IS the
  /// baseline: no plan. Contrast with `aPureTranslationOfTheBaselineIsStillAPlan`,
  /// whose translation puts a DIFFERENT display at (0,0) and so asks for a main
  /// change.
  @Test func anUnanchoredTranslationOfTheBaselineIsANoOp() {
    let baseline = ArrangementFixtures.pair
    #expect(ArrangementPlan(applying: baseline.translated(dx: 640, dy: -480), to: baseline) == nil)
  }

  /// No tile at (0,0) on either side: there is nothing to anchor the request
  /// on, so it cannot be expressed to CG at all. A baseline like this comes
  /// from a read that skipped the main display's unreadable bounds.
  @Test func aRequestThatCannotBeAnchoredIsRefused() {
    let baseline = ArrangementFixtures.arrangement([
      (1, ArrangementFixtures.rect(100, 0, 1920, 1080)),
      (2, ArrangementFixtures.rect(2020, 0, 1920, 1080)),
    ])
    let wanted = baseline.moving(2, to: DisplayPoint(x: 2020, y: 1080))
    #expect(ArrangementPlan(applying: wanted, to: baseline) == nil)
  }

  /// The invariant over randomized main-display moves: every plan that exists
  /// names a tile at (0,0) and preserves the requested relative layout. This is
  /// the property the live apply needs; a plan violating the first half is one
  /// CoreGraphics accepts and ignores.
  @Test func everyPlanForAMovedMainDisplayIsAnchoredAndPreservesTheRelativeLayout() throws {
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func next(_ bound: Int) -> Int {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Int(seed >> 33) % bound
    }
    for _ in 0 ..< 2000 {
      let baseline = ArrangementFixtures.arrangement([
        (1, ArrangementFixtures.rect(0, 0, 1800, 1169)),
        (2, ArrangementFixtures.rect(1800, next(2400) - 1200, 1296, 2304)),
        (3, ArrangementFixtures.rect(3096, next(2000) - 1000, 3440, 1440)),
      ])
      let dragged = baseline.moving(
        1, to: DisplayPoint(x: next(8000) - 4000, y: next(6000) - 3000)
      )
      guard let plan = ArrangementPlan(applying: dragged, to: baseline) else { continue }
      #expect(plan.requestedMain != nil)
      #expect(plan.arrangement.relativeLayout == dragged.relativeLayout)
    }
  }

  // MARK: - AR4: a plan cannot be partial

  @Test func aPlanCoversEveryDisplay() throws {
    let baseline = DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
      ArrangementFixtures.tile(2, DisplayRect(x: 1920, y: 0, width: 1920, height: 1080)),
      ArrangementFixtures.tile(3, DisplayRect(x: 3840, y: 0, width: 1920, height: 1080)),
    ])
    // ONE display moves. All three origins are still stated, because a display
    // whose origin is not set is repositioned by CoreGraphics (§4.2).
    let moved = baseline.moving(3, to: DisplayPoint(x: 1920, y: -1080))
    let plan = try #require(ArrangementPlan(applying: moved, to: baseline))
    #expect(plan.changes.map(\.id) == [1, 2, 3])
    #expect(plan.changes == moved.tiles.map { DisplayOriginChange(id: $0.id, origin: $0.rect.origin) })
  }

  // MARK: - AR6: mirror slaves never appear in a plan

  @Test func mirrorSlavesNeverAppearInAPlan() throws {
    let baseline = DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080), mirroredIDs: [9]),
      ArrangementFixtures.tile(2, DisplayRect(x: 1920, y: 0, width: 1920, height: 1080)),
    ])
    let plan = try #require(ArrangementPlan(applying: baseline.makingMain(2), to: baseline))
    #expect(plan.changes.map(\.id) == [1, 2])
    #expect(!plan.changes.contains { $0.id == 9 })
  }

  /// A slave that ALSO holds a tile is refused outright rather than filtered
  /// out. Filtering would leave display 9's origin unstated, which is the
  /// partial plan AR4 exists to make unrepresentable — one invariant cannot be
  /// bought by breaking the other.
  @Test func anArrangementGivingAMirrorSlaveATileIsRefused() {
    let baseline = DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080), mirroredIDs: [9]),
      ArrangementFixtures.tile(9, DisplayRect(x: 1920, y: 0, width: 1920, height: 1080)),
    ])
    #expect(ArrangementPlan(applying: baseline.makingMain(9), to: baseline) == nil)
  }

  // MARK: - The exactness gate

  @Test func aGaplessLayoutExpectsExactOriginsAndAGappyOneDoesNot() throws {
    let baseline = ArrangementFixtures.pair
    let exact = try #require(ArrangementPlan(applying: baseline.makingMain(2), to: baseline))
    #expect(exact.expectsExactOrigins)

    let gapped = baseline.moving(2, to: DisplayPoint(x: 4000, y: 0))
    let adjustable = try #require(ArrangementPlan(applying: gapped, to: baseline))
    #expect(!adjustable.expectsExactOrigins)
  }

  // MARK: - Verification of what was achieved

  @Test func anExactlyHonouredPlanReportsNothingUnhonoured() throws {
    let baseline = ArrangementFixtures.pair
    let plan = try #require(ArrangementPlan(applying: baseline.makingMain(2), to: baseline))
    #expect(ArrangementVerification.unhonoured(plan: plan, achieved: plan.arrangement) == nil)
  }

  /// The renormalisation case, and the reason the comparison is on the relative
  /// layout: macOS re-anchors the space on whichever display ends up at (0,0),
  /// so a correct apply routinely reads back translated.
  @Test func aTranslatedResultIsNotUnhonoured() throws {
    let baseline = ArrangementFixtures.pair
    let plan = try #require(ArrangementPlan(applying: baseline.makingMain(2), to: baseline))
    #expect(ArrangementVerification.unhonoured(
      plan: plan, achieved: plan.arrangement.translated(dx: 640, dy: -480)
    ) == nil)
  }

  /// #53's shape: the platform commits, returns success, and puts a display
  /// somewhere the plan never named.
  @Test func aDisplayTheSystemPutSomewhereElseIsReportedUnhonoured() throws {
    let baseline = ArrangementFixtures.pair
    let requested = baseline.moving(2, to: DisplayPoint(x: 0, y: 1080)).makingMain(1)
    let plan = try #require(ArrangementPlan(applying: requested, to: baseline))
    #expect(ArrangementVerification.unhonoured(plan: plan, achieved: baseline)
      == DisplayOriginChange(id: 2, origin: DisplayPoint(x: 0, y: 1080)))
  }

  @Test func aDisplayMissingFromTheReadBackIsReportedUnhonoured() throws {
    let baseline = ArrangementFixtures.pair
    let plan = try #require(ArrangementPlan(applying: baseline.makingMain(2), to: baseline))
    let achieved = DisplayArrangement(tiles: plan.arrangement.tiles.filter { $0.id == 2 })
    #expect(ArrangementVerification.unhonoured(plan: plan, achieved: achieved)?.id == 1)
  }

  /// A display that arrived between the commit and the read-back must not make
  /// every change look unhonoured — it moves the achieved bounding box, and the
  /// normalisation is anchored on that box.
  @Test func aDisplayThatArrivedAfterTheCommitDoesNotUnhonourTheWholePlan() throws {
    let baseline = ArrangementFixtures.pair
    let plan = try #require(ArrangementPlan(applying: baseline.makingMain(2), to: baseline))
    let achieved = DisplayArrangement(tiles: plan.arrangement.tiles + [
      ArrangementFixtures.tile(3, DisplayRect(x: -3840, y: -1080, width: 1920, height: 1080)),
    ])
    #expect(ArrangementVerification.unhonoured(plan: plan, achieved: achieved) == nil)
  }

  /// A plan that asked macOS to close a gap gets no divergence report: the
  /// adjustment is the documented behaviour (§4.1), and
  /// `ArrangementOutcomePolicy` is what tells the user about it.
  @Test func anAdjustmentToAGappyPlanIsNotReportedUnhonoured() throws {
    let baseline = ArrangementFixtures.pair
    let gapped = baseline.moving(2, to: DisplayPoint(x: 4000, y: 0))
    let plan = try #require(ArrangementPlan(applying: gapped, to: baseline))
    #expect(ArrangementVerification.unhonoured(plan: plan, achieved: baseline) == nil)
  }

  // MARK: - Through the fake

  @Test func theFakeAppliesEveryOriginAndReportsTheLayoutItAchieved() throws {
    let fake = FakeArrangementConfigurator()
    fake.arrangement = ArrangementFixtures.pair
    let plan = try #require(
      ArrangementPlan(applying: ArrangementFixtures.pair.makingMain(2), to: fake.arrangement)
    )

    let achieved = try fake.apply(plan, scope: .preview)
    #expect(achieved == plan.arrangement)
    #expect(fake.currentArrangement() == plan.arrangement)
    #expect(fake.applied == [.init(plan: plan, scope: .preview)])
  }

  @Test func aFailedApplyChangesNothing() throws {
    let fake = FakeArrangementConfigurator()
    fake.arrangement = ArrangementFixtures.pair
    fake.failWith = DisplayConfigError(cgErrorCode: CGError.cannotComplete.rawValue)
    let plan = try #require(
      ArrangementPlan(applying: ArrangementFixtures.pair.makingMain(2), to: fake.arrangement)
    )

    #expect(throws: DisplayConfigError(cgErrorCode: CGError.cannotComplete.rawValue)) {
      try fake.apply(plan, scope: .preview)
    }
    #expect(fake.currentArrangement() == ArrangementFixtures.pair)
    #expect(fake.applied.isEmpty)
  }

  /// The throw says "this is not what you asked for", NOT "nothing happened".
  /// The divergent layout is standing and recorded — a test that let the fake
  /// unwind here would enshrine the comfortable version of this failure rather
  /// than the measured one.
  @Test func aDivergentApplyThrowsAndLeavesTheAchievedLayoutStanding() throws {
    let fake = FakeArrangementConfigurator()
    fake.arrangement = ArrangementFixtures.pair
    let plan = try #require(
      ArrangementPlan(
        applying: ArrangementFixtures.pair.moving(2, to: DisplayPoint(x: 0, y: 1080)),
        to: fake.arrangement
      )
    )
    fake.divergeNextApplyTo = [2: DisplayPoint(x: 1920, y: 0)]

    #expect(throws: DisplayConfigError(cgErrorCode: CGError.failure.rawValue)) {
      try fake.apply(plan, scope: .session)
    }
    #expect(fake.applied.count == 1)
    #expect(fake.currentArrangement() == ArrangementFixtures.pair)
  }

  /// The second interaction, not just the first: the divergence is one-shot, so
  /// a retry computed from the LIVE layout lands. A retry that replayed the
  /// plan that diverged is the failure this family of checks has produced
  /// before — a no-op that reports success forever.
  @Test func theRetryAfterADivergentApplyIsComputedFromLiveAndLands() throws {
    let fake = FakeArrangementConfigurator()
    fake.arrangement = ArrangementFixtures.pair
    let wanted = ArrangementFixtures.pair.moving(2, to: DisplayPoint(x: 0, y: 1080))
    let first = try #require(ArrangementPlan(applying: wanted, to: fake.arrangement))
    fake.divergeNextApplyTo = [2: DisplayPoint(x: 1920, y: 0)]
    #expect(throws: DisplayConfigError.self) { try fake.apply(first, scope: .session) }

    let live = fake.currentArrangement()
    let retry = try #require(ArrangementPlan(applying: wanted, to: live))
    #expect(try fake.apply(retry, scope: .session) == wanted)
  }
}
