import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Mirrors `ModePreviewSessionTests` case for case: an arrangement can put the menu bar
/// on a dark display or strand the pointer, and then nobody can click Keep, so the
/// countdown defaults to revert (AR8). What this suite adds is the second interaction,
/// where the mirroring work's worst defect lived: a no-op that reported success forever.
@Suite("Arrangement preview session (AR8)")
struct ArrangementPreviewSessionTests {
  private var pair: DisplayArrangement { ArrangementFixtures.pair }
  /// Display 2 moved below display 1. Gapless and non-overlapping, so
  /// `expectsExactOrigins` holds and the configurator's verification is live.
  private var stacked: DisplayArrangement {
    ArrangementFixtures.pair.moving(2, to: DisplayPoint(x: 0, y: 1080))
  }

  /// The same layout with display 2 at the origin — the change that moves the
  /// menu bar, and a pure translation of everything else.
  private var mainOnTwo: DisplayArrangement { ArrangementFixtures.pair.makingMain(2) }

  private var triple: DisplayArrangement {
    DisplayArrangement(tiles: ArrangementFixtures.pair.tiles + [
      ArrangementFixtures.tile(3, DisplayRect(x: 3840, y: 0, width: 1920, height: 1080)),
    ])
  }

  private func loaded(_ arrangement: DisplayArrangement) -> FakeArrangementConfigurator {
    let fake = FakeArrangementConfigurator()
    fake.arrangement = arrangement
    return fake
  }

  private let failure = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
  private let illegal = DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue)

  // MARK: - The shape `ModePreviewSession` established

  @Test func beginningAPreviewAppliesWithPreviewScopeNotPermanent() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake)
    let previewed = try await session.begin(stacked).get()

    #expect(fake.applied == [.init(plan: previewed.plan, scope: .preview)])
    #expect(previewed.requested == stacked)
    #expect(previewed.achieved == stacked)
  }

  /// `.permanent`, not `.session`: macOS persists the arrangement per display-set, so a
  /// session-scoped commit is lost at logout and reads as the feature not working.
  @Test func confirmingReappliesTheApprovedPlanAtPermanentScope() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake)
    let previewed = try await session.begin(stacked).get()

    #expect(await session.confirm(previewed) == .committed)
    #expect(fake.applied.last == .init(plan: previewed.plan, scope: .permanent))
    #expect(fake.currentArrangement() == stacked)
  }

  /// The safety property: if it inverts, a layout that strands the pointer or the menu
  /// bar becomes permanent with no undo from inside the app.
  @Test func expiryReverts() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 2)
    _ = try await session.begin(stacked).get()

    #expect(await session.tick() == nil) // 1 left
    #expect(await session.tick() == .reverted) // expires
    #expect(fake.currentArrangement() == pair)
    #expect(fake.applied.last?.scope == .permanent)
  }

  @Test func revertingRestoresTheExactPrePreviewLayout() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake)
    let previewed = try await session.begin(mainOnTwo).get()

    #expect(await session.revert(previewed) == .reverted)
    #expect(fake.currentArrangement() == pair)
  }

  @Test func aFailedApplyReportsTheErrorAndAppliesNothing() async {
    let fake = loaded(pair)
    fake.failWith = DisplayConfigError(cgErrorCode: 1001)
    let session = ArrangementPreviewSession(configurator: fake)

    #expect(await session.begin(stacked).failureError == DisplayConfigError(cgErrorCode: 1001))
    #expect(fake.applied.isEmpty)
    #expect(await session.hasOutstandingPreview == false)
    #expect(fake.currentArrangement() == pair)
  }

  /// Never start a preview that cannot be undone: with no readable layout the countdown
  /// expires into a no-op and leaves the machine in an arrangement nobody approved.
  @Test func aPreviewIsRefusedWhenTheLiveLayoutCannotBeRead() async {
    let session = ArrangementPreviewSession(
      configurator: FakeArrangementConfigurator(), countdownSeconds: 1
    )
    #expect(await session.begin(pair).failureError == failure)
    #expect(await session.tick() == nil)
  }

  /// A preview that changes nothing has nothing to confirm, and a countdown over one is
  /// the mirroring defect's shape: a no-op that later reports success.
  @Test func aPreviewIsRefusedWhenThereIsNothingToChange() async {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake)
    #expect(await session.begin(pair).failureError == illegal)
    #expect(fake.applied.isEmpty)
    #expect(await session.hasOutstandingPreview == false)
  }

  @Test func tickingAfterResolutionDoesNothing() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 1)
    let previewed = try await session.begin(stacked).get()
    #expect(await session.confirm(previewed) == .committed)

    let afterConfirm = fake.applied
    #expect(await session.tick() == nil)
    #expect(fake.applied == afterConfirm)
  }

  /// A double-click on "Keep" must not report a reversion that never happened —
  /// the UI would tell the user the opposite of what the displays are doing.
  @Test func answeringTwiceRepeatsTheOutcomeItAlreadyProduced() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake)
    let previewed = try await session.begin(stacked).get()
    #expect(await session.confirm(previewed) == .committed)

    let afterConfirm = fake.applied
    #expect(await session.confirm(previewed) == .committed)
    #expect(await session.revert(previewed) == .committed)
    #expect(fake.applied == afterConfirm)
  }

  /// A failed `begin` establishes nothing, so it must not erase what the session already
  /// reported: a commit then a failed begin would leave it claiming a reversion. Both
  /// failure exits are exercised, the unreadable layout and the throwing apply.
  @Test func aFailedBeginDoesNotEraseTheOutcomeAlreadyReported() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake)
    let previewed = try await session.begin(stacked).get()
    #expect(await session.confirm(previewed) == .committed)

    fake.arrangement = DisplayArrangement(tiles: [])
    #expect(await session.begin(mainOnTwo).failureError == failure)
    #expect(await session.confirm(previewed) == .committed)
    #expect(await session.revert(previewed) == .committed)

    fake.arrangement = stacked
    fake.failWith = DisplayConfigError(cgErrorCode: 1001)
    #expect(await session.begin(stacked.makingMain(2)).failureError
      == DisplayConfigError(cgErrorCode: 1001))
    #expect(await session.confirm(previewed) == .committed)
  }

  /// The shipped default, which every other test overrides with an explicit value.
  /// Thirty seconds is a product decision, matching both siblings.
  @Test func theDefaultCountdownIsThirtySeconds() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake)
    _ = try await session.begin(stacked).get()
    #expect(await session.secondsRemaining == 30)
  }

  @Test func theCountdownStopsBeingReportedOnceResolved() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 15)
    let previewed = try await session.begin(stacked).get()
    #expect(await session.secondsRemaining == 15)
    #expect(await session.tick() == nil)
    #expect(await session.secondsRemaining == 14)
    _ = await session.confirm(previewed)
    #expect(await session.secondsRemaining == 0)
  }

  // MARK: - State a UI rebuilds itself from

  @Test func theSessionReportsWhatIsPreviewedSoAUINeverHasToRemember() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 15)
    #expect(await session.previewedArrangement == nil)
    #expect(await session.isCountingDown == false)

    let previewed = try await session.begin(stacked).get()
    #expect(await session.previewedArrangement == previewed)
    #expect(await session.isCountingDown)

    _ = await session.confirm(previewed)
    #expect(await session.previewedArrangement == nil)
    #expect(await session.isCountingDown == false)
  }

  /// macOS adjusts a requested layout silently, so the session reports what it read
  /// back, never what it asked for. A UI rendering the request disagrees with the screens.
  @Test func anAdjustedLayoutIsReportedAsAchievedRatherThanAssumed() async throws {
    let fake = loaded(pair)
    // A layout with a gap — one macOS is documented to correct, so the
    // configurator's exactness check is deliberately not armed for it.
    let gapped = pair.moving(2, to: DisplayPoint(x: 4000, y: 0))
    fake.divergeNextApplyTo = [2: DisplayPoint(x: 1920, y: 0)] // the gap gets closed
    let session = ArrangementPreviewSession(configurator: fake)

    let previewed = try await session.begin(gapped).get()
    #expect(previewed.requested == gapped)
    #expect(previewed.achieved == pair)
    #expect(previewed.achieved != previewed.requested)
  }

  /// The confirmation goes where the menu bar actually is while the preview stands, the
  /// achieved layout's origin: a panel on the wrong screen is a countdown nobody sees.
  @Test func theConfirmationTargetsTheDisplayTheMenuBarLandedOn() async throws {
    let honoured = loaded(pair)
    let session = ArrangementPreviewSession(configurator: honoured)
    let previewed = try await session.begin(mainOnTwo).get()
    #expect(previewed.plan.requestedMain == 2)
    #expect(previewed.confirmationDisplayID == 2)

    let adjusting = loaded(pair)
    // Requests display 2 at the origin, from a layout with a gap; the system
    // puts display 2 somewhere else and nothing lands at the origin at all.
    let gappyMainOnTwo = pair.moving(2, to: DisplayPoint(x: 4000, y: 0)).makingMain(2)
    adjusting.divergeNextApplyTo = [2: DisplayPoint(x: 4000, y: 0)]
    let adjusted = try await ArrangementPreviewSession(configurator: adjusting)
      .begin(gappyMainOnTwo).get()
    #expect(adjusted.plan.requestedMain == 2)
    #expect(adjusted.confirmationDisplayID == nil) // the caller falls back to the dragged tile
  }

  // MARK: - Failed resolutions are recoverable, not terminal

  @Test func aFailedResolutionKeepsThePreviewOutstanding() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 15)
    let previewed = try await session.begin(stacked).get()

    fake.failWith = DisplayConfigError(cgErrorCode: 1001)
    #expect(await session.confirm(previewed) == .failed(DisplayConfigError(cgErrorCode: 1001)))
    #expect(await session.hasOutstandingPreview)
    // A commit that could not be made permanent leaves the countdown armed: the
    // fallback is still the layout the user can definitely read.
    #expect(await session.isCountingDown)

    fake.failWith = nil
    #expect(await session.revert(previewed) == .reverted)
    #expect(fake.currentArrangement() == pair)
    #expect(await session.hasOutstandingPreview == false)
  }

  @Test func aFailedExpiryRevertStaysRevertibleAndRecovers() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 1)
    let previewed = try await session.begin(stacked).get()
    fake.failWith = DisplayConfigError(cgErrorCode: 1001)

    #expect(await session.tick() == .failed(DisplayConfigError(cgErrorCode: 1001)))
    #expect(await session.hasOutstandingPreview)
    #expect(await session.tick() == nil) // the countdown fires once, not forever

    fake.failWith = nil
    #expect(await session.revert(previewed) == .reverted)
    #expect(fake.currentArrangement() == pair)
  }

  /// A failed expiry disarms the countdown; a failed commit does not. Inferring either
  /// shows a countdown that never fires, or hides one that will.
  @Test func aFailedExpiryStopsCountingDownWhileAFailedCommitKeepsCounting() async throws {
    let expiry = loaded(pair)
    let expirySession = ArrangementPreviewSession(configurator: expiry, countdownSeconds: 1)
    _ = try await expirySession.begin(stacked).get()
    expiry.failWith = DisplayConfigError(cgErrorCode: 1001)
    #expect(await expirySession.tick() == .failed(DisplayConfigError(cgErrorCode: 1001)))
    #expect(await expirySession.hasOutstandingPreview)
    #expect(await expirySession.isCountingDown == false)

    let commit = loaded(pair)
    let commitSession = ArrangementPreviewSession(configurator: commit, countdownSeconds: 15)
    let previewed = try await commitSession.begin(stacked).get()
    commit.failWith = DisplayConfigError(cgErrorCode: 1001)
    #expect(await commitSession.confirm(previewed) == .failed(DisplayConfigError(cgErrorCode: 1001)))
    #expect(await commitSession.isCountingDown)
  }

  /// After a failed commit the confirmation still shows the same preview, so its answer
  /// keeps matching and recovery keeps working.
  @Test func theRetryPathStillMatchesAfterAFailedResolution() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake)
    let previewed = try await session.begin(stacked).get()
    fake.failWith = DisplayConfigError(cgErrorCode: 1001)
    #expect(await session.confirm(previewed) == .failed(DisplayConfigError(cgErrorCode: 1001)))

    fake.failWith = nil
    #expect(await session.confirm(previewed) == .committed)
  }

  /// An empty sweep is every display unreadable at once, not every display departing:
  /// reading it as a departure throws away a good fallback over one bad instant.
  @Test func anUnreadableLayoutLeavesTheRevertRetryableRatherThanDropped() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 15)
    let previewed = try await session.begin(stacked).get()

    fake.arrangement = DisplayArrangement(tiles: [])
    #expect(await session.revert(previewed) == .failed(failure))
    #expect(await session.hasOutstandingPreview)

    fake.arrangement = previewed.achieved
    #expect(await session.revert(previewed) == .reverted)
    #expect(fake.currentArrangement() == pair)
  }

  @Test func anUnreadableLayoutDuringABeginLeavesTheOutstandingPreviewAlone() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 15)
    let previewed = try await session.begin(stacked).get()

    fake.arrangement = DisplayArrangement(tiles: [])
    #expect(await session.begin(mainOnTwo).failureError == failure)
    #expect(await session.previewedArrangement == previewed)
    #expect(await session.isCountingDown)

    fake.arrangement = previewed.achieved
    #expect(await session.revert(previewed) == .reverted)
    #expect(fake.currentArrangement() == pair)
  }

  // MARK: - An answer only resolves the preview it was given for

  /// The worst failure this type can produce: Keep is clicked on one layout, a second
  /// drop lands in between, and the layout nobody saw becomes permanent. Ordering cannot
  /// prevent it, the click runs a turn before the call, so the answer carries its subject.
  @Test func aStaleAnswerResolvesNothing() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 15)
    let first = try await session.begin(stacked).get()
    let second = try await session.begin(stacked.makingMain(2)).get()

    #expect(await session.confirm(first) == .stale)
    #expect(await session.revert(first) == .stale)
    #expect(fake.applied.allSatisfy { $0.scope == .preview }) // nothing committed
    // Untouched and still resolvable: the preview that IS outstanding keeps its
    // countdown and its fallback.
    #expect(await session.previewedArrangement == second)
    #expect(await session.isCountingDown)
    #expect(await session.confirm(second) == .committed)
    #expect(fake.applied.last == .init(plan: second.plan, scope: .permanent))
  }

  // MARK: - The second interaction

  /// One outstanding preview, never two: the second `begin` takes the slot, and the
  /// first is neither stranded with a countdown of its own nor allowed to take its
  /// fallback with it. Mutation that breaks it: give `begin` the live layout as its
  /// fallback instead of keeping `outstanding?.captured`, and the revert restores the
  /// unapproved first preview.
  @Test func aSecondBeginWhileOneIsOutstandingSupersedesRatherThanStrandingIt() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 15)
    let first = try await session.begin(stacked).get()
    #expect(await session.tick() == nil) // 14 left

    let second = try await session.begin(stacked.makingMain(2)).get()
    #expect(await session.previewedArrangement == second)
    #expect(await session.secondsRemaining == 15) // the countdown restarts, it does not stack
    #expect(await session.confirm(first) == .stale)

    #expect(await session.revert(second) == .reverted)
    #expect(fake.currentArrangement() == pair)
    #expect(fake.applied.map(\.scope) == [.preview, .preview, .permanent])
  }

  /// The platform commits, returns success, and puts a display somewhere the plan never
  /// named, so the apply throws over a machine that did move and the next attempt has to
  /// sample it again. The observable is the fallback: a session that kept the failed
  /// attempt's capture would revert to `pair` rather than to what was on screen.
  @Test func theRetryAfterAFailedApplyIsComputedFromLiveStateNotTheStalePlan() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake)
    fake.divergeNextApplyTo = [2: DisplayPoint(x: 4000, y: 0)]

    #expect(await session.begin(stacked).failureError == failure)
    #expect(await session.hasOutstandingPreview == false)
    let diverged = fake.currentArrangement()
    #expect(diverged.tile(2)?.rect.origin == DisplayPoint(x: 4000, y: 0))
    #expect(diverged != pair)

    // The divergence is one-shot, so the retry lands — a fake that diverted
    // forever would prove a loop rather than a recovery.
    let retry = try await session.begin(stacked).get()
    #expect(retry.achieved == stacked)
    #expect(await session.revert(retry) == .reverted)
    #expect(fake.currentArrangement() == diverged)
  }

  /// AR4 through the session: `stacked` names displays 1 and 2 only, so applying it
  /// after a third arrives hands the newcomer's origin to CoreGraphics and moves a
  /// display nobody touched.
  @Test func aLayoutForADisplaySetThatHasSinceChangedIsRefused() async {
    let fake = loaded(triple)
    let session = ArrangementPreviewSession(configurator: fake)
    #expect(await session.begin(stacked).failureError == illegal)
    #expect(fake.applied.isEmpty)
    #expect(await session.hasOutstandingPreview == false)
  }

  /// Without this, one unplug wedges the feature: every later revert builds a plan for a
  /// display set that no longer exists and fails identically forever. It takes no display
  /// argument, since any arrival or departure invalidates a preview about a set.
  @Test func discardOnADepartedDisplayFreesTheSession() async throws {
    let fake = loaded(triple)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 15)
    let previewed = try await session.begin(
      triple.moving(3, to: DisplayPoint(x: 1920, y: -1080))
    ).get()
    #expect(await session.discardIfTopologyChanged() == false) // nothing has changed yet
    let beforeDeparture = fake.applied

    fake.arrangement = DisplayArrangement(tiles: previewed.achieved.tiles.filter { $0.id != 3 })
    #expect(await session.discardIfTopologyChanged())
    #expect(fake.applied == beforeDeparture) // nothing applied to a machine that moved on
    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.isCountingDown == false)
    #expect(await session.tick() == nil)
    // An answer that was already in flight resolves nothing that is being kept.
    #expect(await session.confirm(previewed) == .reverted)

    // Freed: a preview over the display set that is actually present works.
    let next = try await session.begin(stacked).get()
    #expect(next.achieved == stacked)
    #expect(await session.previewedArrangement == next)
  }

  /// The proactive call makes the same distinction the revert paths do: an empty sweep
  /// is every display unreadable at once, not every display departing. A coordinator
  /// calling it on every reconfiguration would otherwise drop a good fallback.
  @Test func discardDoesNotReadAnUnreadableSweepAsADeparture() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 15)
    let previewed = try await session.begin(stacked).get()

    fake.arrangement = DisplayArrangement(tiles: [])
    #expect(await session.discardIfTopologyChanged() == false)
    #expect(await session.previewedArrangement == previewed)
    #expect(await session.isCountingDown)

    fake.arrangement = previewed.achieved
    #expect(await session.revert(previewed) == .reverted)
    #expect(fake.currentArrangement() == pair)
  }

  /// Dragging a display back to where it started while a preview is outstanding. The
  /// plan is computed against live, which is the unconfirmed preview, so this is a real
  /// change; against the captured fallback it would read as nothing to change and be
  /// refused while the screens said otherwise. The capture is still `pair`.
  @Test func aSecondBeginBackToTheStartingLayoutIsAChangeBecauseLiveIsThePreview() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 15)
    _ = try await session.begin(stacked).get()

    let back = try await session.begin(pair).get()
    #expect(back.requested == pair)
    #expect(back.achieved == pair)
    #expect(await session.confirm(back) == .committed)
    #expect(fake.applied.map(\.scope) == [.preview, .preview, .permanent])
    #expect(fake.currentArrangement() == pair)
  }

  /// The same rule reached through the countdown rather than a caller noticing the
  /// departure. One shared predicate, so an early expiry cannot wedge the session.
  @Test func anExpiryAfterADepartureDropsThePreviewInsteadOfWedging() async throws {
    let fake = loaded(triple)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 1)
    let previewed = try await session.begin(
      triple.moving(3, to: DisplayPoint(x: 1920, y: -1080))
    ).get()

    fake.arrangement = DisplayArrangement(tiles: previewed.achieved.tiles.filter { $0.id != 3 })
    let beforeDeparture = fake.applied

    #expect(await session.tick() == .reverted)
    #expect(fake.applied == beforeDeparture)
    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.isCountingDown == false)
  }

  /// The layout is already back, restored from outside the app or by a dropped
  /// app-scoped config, and that is the restoration. `ArrangementPlan` refuses a no-op,
  /// so this is decided before the plan is built; off a nil plan it looks like a failure.
  @Test func aRevertOntoTheLayoutAlreadyRestoredAppliesNothingAndStillResolves() async throws {
    let fake = loaded(pair)
    let session = ArrangementPreviewSession(configurator: fake, countdownSeconds: 15)
    let previewed = try await session.begin(stacked).get()

    fake.arrangement = pair
    let beforeRevert = fake.applied
    #expect(await session.revert(previewed) == .reverted)
    #expect(fake.applied == beforeRevert)
    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.isCountingDown == false)
  }

  /// The display set still matches, but the capture is a layout `ArrangementPlan` will
  /// not express: display 2 mirrors display 1 and holds a tile of its own (AR6). No retry
  /// fixes a fallback that cannot become a request, so it is dropped and reported
  /// `.failed`, never `.reverted`: the previewed layout is still on screen at `.preview`.
  @Test func aFallbackThatCannotBeExpressedAsAPlanIsReportedFailedNotReverted() async throws {
    let fake = loaded(DisplayArrangement(tiles: [
      ArrangementFixtures.tile(
        1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080), mirroredIDs: [2]
      ),
      ArrangementFixtures.tile(2, DisplayRect(x: 1920, y: 0, width: 1920, height: 1080)),
    ]))
    let session = ArrangementPreviewSession(configurator: fake)
    // The wanted layout carries no mirror claim, so the preview's own plan is
    // fine; only the captured fallback is unexpressible.
    let previewed = try await session.begin(stacked).get()

    #expect(await session.revert(previewed) == .failed(illegal))
    #expect(await session.hasOutstandingPreview == false)
    #expect(fake.applied.count == 1) // the failed revert applied nothing
    #expect(fake.applied.allSatisfy { $0.scope == .preview })
  }
}
