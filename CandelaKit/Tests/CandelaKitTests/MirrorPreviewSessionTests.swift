import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Mirror preview session (DT19)")
struct MirrorPreviewSessionTests {
  private func unmirroredPair() -> [ConfiguredDisplay] {
    [MirrorFixtures.display(1, builtIn: true), MirrorFixtures.display(2)]
  }

  private func makeSession(_ fake: FakeConfigurator, seconds: Int = 15) -> MirrorPreviewSession {
    fake.configuredDisplays = unmirroredPair()
    return MirrorPreviewSession(configurator: fake, countdownSeconds: seconds)
  }

  private func engageDecision(_ topology: MirrorTopology) -> MirrorToggleDecision {
    MirrorTopologyPolicy.engage(topology, master: 2)
  }

  @Test func beginningAPreviewAppliesTheChangesAtPreviewScope() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    #expect(fake.appliedMirroring == [
      .init(changes: [MirrorChange(display: 1, master: 2)], scope: .preview),
    ])
  }

  /// The confirmation window goes on the MASTER, and the answer carries it. The
  /// display named in the request is a slave from the instant the preview
  /// applies, so it has no `NSScreen` and the window would dismiss itself.
  @Test func thePreviewedValueNamesTheMasterAsTheConfirmationDisplay() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    #expect(await session.previewedTopology?.confirmationDisplayID == 2)
  }

  /// THE safety property. Timing out must restore the topology that was
  /// captured before the preview — computed against the LIVE list, so a
  /// display that moved in the meantime is not stranded.
  @Test func theCountdownDefaultsToRevertingNotKeeping() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake, seconds: 2)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)

    #expect(await session.tick() == nil)
    #expect(await session.tick() == .reverted)
    #expect(fake.appliedMirroring.last == .init(
      changes: [MirrorChange(display: 1, master: kCGNullDirectDisplay)], scope: .session
    ))
    #expect(await session.hasOutstandingPreview == false)
  }

  /// Confirming commits the changes that were PREVIEWED, at session scope —
  /// not whatever the topology reports at confirm time. The two differ exactly
  /// when something went wrong, and committing the drifted value would make an
  /// unapproved topology outlive the process while reporting success.
  @Test func confirmingCommitsWhatWasPreviewedRatherThanWhatIsLive() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    guard let answered = await session.previewedTopology else {
      Issue.record("no outstanding preview")
      return
    }
    // Something else moves the topology under us between preview and confirm.
    fake.configuredDisplays = [MirrorFixtures.display(1, builtIn: true), MirrorFixtures.display(2)]

    #expect(await session.confirm(answered) == .committed)
    #expect(fake.appliedMirroring.last == .init(
      changes: [MirrorChange(display: 1, master: 2)], scope: .session
    ))
  }

  /// Disengage commits directly and never enters the session: a countdown there
  /// would re-mirror a rig the user just un-mirrored, while they were still
  /// looking for the confirmation window on a screen that had only just come
  /// back.
  @Test func onlyAnEngageDecisionCanBePreviewed() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    let disengage = MirrorToggleDecision.disengage(
      changes: [MirrorChange(display: 1, master: kCGNullDirectDisplay)],
      residualMembers: []
    )
    #expect(await session.begin(disengage, from: captured).failureError != nil)
    #expect(await session.begin(.refused(.onlyOneDisplay), from: captured).failureError != nil)
    #expect(fake.appliedMirroring.isEmpty)
  }

  /// A PARTIAL break is refused on exactly the same terms as a total one, and
  /// that is the point: `.disengage` carries `residualMembers` because a set
  /// containing a locked slave only partly breaks, and the outcome has to say
  /// what survived. A `begin` that took the disengage path would have to either
  /// carry that residue through the countdown or drop it — and dropping it is
  /// the T3 defect, success reported over a set still on screen, re-created one
  /// layer out. Refusing leaves the residue with the caller, which is the only
  /// place it can be reported.
  @Test func aPartialDisengageIsRefusedRatherThanPreviewedWithItsResidueDropped() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    let partial = MirrorToggleDecision.disengage(
      changes: [MirrorChange(display: 1, master: kCGNullDirectDisplay)],
      residualMembers: [2, 3]
    )
    #expect(await session.begin(partial, from: captured).failureError != nil)
    #expect(await session.hasOutstandingPreview == false)
    #expect(fake.appliedMirroring.isEmpty)
  }

  /// A preview never begins unless the topology to fall back to was read first.
  /// Without it the countdown expires into a no-op, which is the failure this
  /// whole type exists to prevent.
  @Test func aPreviewRefusesToBeginWithoutAFallbackToRestore() async {
    let fake = FakeConfigurator()
    fake.configuredDisplays = unmirroredPair()
    let session = MirrorPreviewSession(configurator: fake)
    let decision = MirrorTopologyPolicy.engage(MirrorTopology(fake.displays()), master: 2)
    #expect(await session.begin(decision, from: MirrorTopology([])).failureError != nil)
    #expect(fake.appliedMirroring.isEmpty)
  }

  @Test func aFailedApplyEstablishesNoPreviewAndReportsTheError() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    fake.failMirroringWith = DisplayConfigError(cgErrorCode: 1001)
    let captured = MirrorTopology(fake.displays())
    let result = await session.begin(engageDecision(captured), from: captured)
    #expect(result.failureError == DisplayConfigError(cgErrorCode: 1001))
    #expect(await session.hasOutstandingPreview == false)
  }

  /// A revert that threw left the topology where it was, so the record of how
  /// to move it back is still the truth — and trying again is the whole
  /// recovery path.
  ///
  /// The injected failure lands on a NON-empty batch, deliberately: the fake
  /// checks its empty-batch guard before its injection point precisely so a
  /// test cannot enshrine a "revert failed" branch that shipped code cannot
  /// reach. Here the live topology really is mirrored and the capture really is
  /// not, so `changes(from:to:)` stages one change and the failure is real.
  @Test func aFailedRevertKeepsThePreviewOutstandingSoItCanBeRetried() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    guard let answered = await session.previewedTopology else {
      Issue.record("no outstanding preview")
      return
    }
    fake.failMirroringWith = DisplayConfigError(cgErrorCode: 1002)
    #expect(await session.revert(answered) == .failed(DisplayConfigError(cgErrorCode: 1002)))
    #expect(await session.hasOutstandingPreview)

    fake.failMirroringWith = nil
    #expect(await session.revert(answered) == .reverted)
    #expect(await session.hasOutstandingPreview == false)
  }

  /// An answer about a preview that is no longer outstanding resolves nothing.
  @Test func anAnswerAboutADifferentPreviewIsStale() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    let wrong = PreviewedMirrorTopology(
      confirmationDisplayID: 99,
      applied: [MirrorChange(display: 9, master: 99)],
      capturedTopology: captured
    )
    #expect(await session.confirm(wrong) == .stale)
    #expect(await session.hasOutstandingPreview)
  }

  /// The MASTER went away. The preview is REVERTED, not dropped — and the
  /// departed master needs no special case: `changes(from:to:)` iterates the
  /// LIVE list, so the surviving slave is staged back to unmirrored and the
  /// master that is gone is never staged at all.
  @Test func theMastersDepartureRevertsTheMembersThatRemain() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    fake.configuredDisplays = fake.displays().filter { $0.id != 2 }

    #expect(await session.revertOnDeparture(displayID: 2) == .reverted)
    #expect(await session.hasOutstandingPreview == false)
    #expect(fake.appliedMirroring.last == .init(
      changes: [MirrorChange(display: 1, master: kCGNullDirectDisplay)], scope: .session
    ))
  }

  /// A SLAVE departing resolves the preview rather than abandoning it. With a
  /// single slave the distinction is invisible — losing it un-mirrors the set
  /// anyway, so the revert stages nothing and succeeds as a no-op. The two-slave
  /// case below is the one that makes the difference visible.
  @Test func aSlavesDepartureResolvesThePreviewRatherThanAbandoningIt() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    fake.configuredDisplays = fake.displays().filter { $0.id != 1 }

    #expect(await session.revertOnDeparture(displayID: 1) == .reverted)
    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.isCountingDown == false)
  }

  /// THE case this behaviour exists for. Preview `{1→2, 3→2}`, and display 3 is
  /// unplugged inside the countdown window.
  ///
  /// Dropping the preview here would leave display 1 STILL mirroring 2 at
  /// `.preview` scope, with the countdown cancelled and the confirmation window
  /// dismissed — a topology the user never approved, with no UI and no timer,
  /// recoverable only by quitting the app. Reverting puts display 1 back and
  /// stages nothing for the display that left.
  @Test func aDepartureFromATwoSlaveSetRevertsTheSlaveThatRemains() async {
    let fake = FakeConfigurator()
    fake.configuredDisplays = [
      MirrorFixtures.display(1, builtIn: true), MirrorFixtures.display(2),
      MirrorFixtures.display(3),
    ]
    let session = MirrorPreviewSession(configurator: fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    #expect(fake.appliedMirroring.last?.changes == [
      MirrorChange(display: 1, master: 2), MirrorChange(display: 3, master: 2),
    ])
    fake.configuredDisplays = fake.displays().filter { $0.id != 3 }

    #expect(await session.revertOnDeparture(displayID: 3) == .reverted)
    #expect(await session.hasOutstandingPreview == false)
    #expect(fake.appliedMirroring.last == .init(
      changes: [MirrorChange(display: 1, master: kCGNullDirectDisplay)], scope: .session
    ))
    #expect(MirrorTopology(fake.displays()).masters.isEmpty)
  }

  /// A departure whose revert throws keeps the preview outstanding AND the
  /// countdown armed, so the expiry is a free retry. Dropping on a failed apply
  /// would abandon a topology that demonstrably did not move.
  @Test func aDepartureWhoseRevertFailsKeepsThePreviewOutstanding() async {
    let fake = FakeConfigurator()
    fake.configuredDisplays = [
      MirrorFixtures.display(1, builtIn: true), MirrorFixtures.display(2),
      MirrorFixtures.display(3),
    ]
    let session = MirrorPreviewSession(configurator: fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    fake.configuredDisplays = fake.displays().filter { $0.id != 3 }
    fake.failMirroringWith = DisplayConfigError(cgErrorCode: 1003)

    #expect(
      await session.revertOnDeparture(displayID: 3)
        == .failed(DisplayConfigError(cgErrorCode: 1003))
    )
    #expect(await session.hasOutstandingPreview)
    #expect(await session.isCountingDown)
  }

  // MARK: - Breaking a set while a preview is outstanding

  /// The rig the supersede rule exists for: a set ALREADY EXISTS (1 mirroring
  /// 3), so the topology a preview captures contains it. Reverting that capture
  /// re-mirrors 1 onto 3 — which is exactly what must not happen when the user
  /// has just asked for the mirroring to stop.
  private func preexistingSetTrio() -> [ConfiguredDisplay] {
    [
      MirrorFixtures.display(1, mirrors: 3, builtIn: true),
      MirrorFixtures.display(2),
      MirrorFixtures.display(3, inSet: true),
    ]
  }

  /// Drives the real sequence: a set exists, a preview builds a different one
  /// around display 2, and the user then stops the set they can see. The break's
  /// change list is DECIDED from the live topology exactly as the app decides
  /// it, so the test pins the list that actually ships.
  private func breakChanges(_ fake: FakeConfigurator, containing member: CGDirectDisplayID)
    -> [MirrorChange]
  {
    guard case let .disengage(changes, _) = MirrorTopologyPolicy.disengage(
      MirrorTopology(fake.displays()), containing: member
    ) else {
      Issue.record("expected a disengage decision")
      return []
    }
    return changes
  }

  /// THE defect. A break resolves the outstanding preview WITHOUT reverting it:
  /// the capture describes a topology the user has just contradicted, and
  /// re-applying it would fight an explicit choice. Nothing is applied by the
  /// supersede itself — the only two batches are the preview and the break.
  @Test func breakingASetSupersedesTheOutstandingPreviewRatherThanRevertingIt() async {
    let fake = FakeConfigurator()
    fake.configuredDisplays = preexistingSetTrio()
    let session = MirrorPreviewSession(configurator: fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    #expect(await session.hasOutstandingPreview)

    let changes = breakChanges(fake, containing: 1)
    #expect(await session.applyDisengage(changes).failureError == nil)

    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.isCountingDown == false)
    // Two batches and no third: the preview, then the break. A revert would sit
    // between them and would name `MirrorChange(display: 1, master: 3)`.
    #expect(fake.appliedMirroring.count == 2)
    #expect(fake.appliedMirroring.last?.scope == .session)
    #expect(fake.appliedMirroring.last?.changes == changes)
    // The pre-existing set is GONE, not restored.
    #expect(MirrorTopology(fake.displays()).masters.isEmpty)
    #expect(MirrorTopology(fake.displays()).master(of: 1) == nil)
  }

  /// The harm as the user meets it: the countdown expires fifteen seconds after
  /// the set was stopped and brings it back, undoing an explicit action with no
  /// further interaction. A superseded preview has nothing left to expire.
  @Test func aSupersededPreviewsCountdownCanNeverBringTheOldSetBack() async {
    let fake = FakeConfigurator()
    fake.configuredDisplays = preexistingSetTrio()
    let session = MirrorPreviewSession(configurator: fake, countdownSeconds: 2)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    _ = await session.applyDisengage(breakChanges(fake, containing: 1))

    for _ in 0 ..< 5 { #expect(await session.tick() == nil) }
    #expect(fake.appliedMirroring.count == 2)
    #expect(MirrorTopology(fake.displays()).masters.isEmpty)
  }

  /// The second, more reachable path to the same harm: the confirmation card is
  /// still on screen when the break lands, and Keep is the obvious answer to a
  /// window that still appears to be asking. It must commit NOTHING — committing
  /// re-mirrors the rig at session scope with no countdown left to undo it.
  ///
  /// The app also dismisses the card, and its queue orders a click behind the
  /// break; this is the backstop under both, and the only one a test can reach.
  @Test func answeringASupersededPreviewCommitsNothing() async {
    let fake = FakeConfigurator()
    fake.configuredDisplays = preexistingSetTrio()
    let session = MirrorPreviewSession(configurator: fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    guard let answered = await session.previewedTopology else {
      Issue.record("no outstanding preview")
      return
    }
    _ = await session.applyDisengage(breakChanges(fake, containing: 1))

    #expect(await session.confirm(answered) == .stale)
    #expect(await session.revert(answered) == .stale)
    #expect(fake.appliedMirroring.count == 2)
    #expect(MirrorTopology(fake.displays()).masters.isEmpty)
  }

  /// The mirror image of `begin` refusing a `.disengage`. Every change a break
  /// stages names `kCGNullDirectDisplay`; an ENGAGE arriving here would apply at
  /// session scope with no preview, no countdown and no fallback — and would
  /// supersede the outstanding preview on its way past.
  @Test func onlyABreakCanBeAppliedThroughTheDisengagePath() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)

    let engage = [MirrorChange(display: 1, master: 2)]
    #expect(await session.applyDisengage(engage).failureError != nil)
    #expect(fake.appliedMirroring.count == 1)
    #expect(await session.hasOutstandingPreview)
    #expect(await session.isCountingDown)
  }

  /// The ordinary case — no preview outstanding — still applies at session
  /// scope, unchanged from applying straight through the configurator.
  @Test func breakingASetWithNoPreviewOutstandingAppliesAtSessionScope() async {
    let fake = FakeConfigurator()
    fake.configuredDisplays = preexistingSetTrio()
    let session = MirrorPreviewSession(configurator: fake)
    let changes = breakChanges(fake, containing: 1)

    #expect(await session.applyDisengage(changes).failureError == nil)
    #expect(fake.appliedMirroring == [.init(changes: changes, scope: .session)])
    #expect(MirrorTopology(fake.displays()).masters.isEmpty)
  }

  /// The DELIBERATE cost of superseding before applying, pinned so it is a
  /// decision rather than a surprise: a break that throws has already resolved
  /// the preview, so the previewed topology stands with no countdown left to
  /// take it back. It is still at `.preview` scope, the caller surfaces the
  /// error, and pressing the button again is the retry. The alternative ordering
  /// buys this back at the price of a window in which the expiry re-mirrors the
  /// set the break just dissolved.
  @Test func aBreakThatThrowsHasStillSupersededThePreview() async {
    let fake = FakeConfigurator()
    fake.configuredDisplays = preexistingSetTrio()
    let session = MirrorPreviewSession(configurator: fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    let changes = breakChanges(fake, containing: 1)
    fake.failMirroringWith = DisplayConfigError(cgErrorCode: 1004)

    #expect(
      await session.applyDisengage(changes).failureError == DisplayConfigError(cgErrorCode: 1004)
    )
    #expect(await session.hasOutstandingPreview == false)
    #expect(await session.isCountingDown == false)
    // Nothing was applied by the failed break, and nothing by the supersede.
    #expect(fake.appliedMirroring.count == 1)
  }

  /// A display that was never in the previewed set leaves the preview — and its
  /// countdown — exactly where they were. Otherwise any unrelated unplug would
  /// silently strand a rig in an unapproved topology with nothing left to take
  /// it back.
  @Test func discardingAnUnrelatedDisplayLeavesThePreviewOutstanding() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    #expect(await session.revertOnDeparture(displayID: 77) == nil)
    #expect(await session.hasOutstandingPreview)
    #expect(await session.isCountingDown)
  }
}
