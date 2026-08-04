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

  /// The master went away. There is nothing left to apply the fallback to, and
  /// leaving the preview outstanding would wedge every later `begin()`.
  @Test func discardingTheMastersPreviewAppliesNothing() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    let before = fake.appliedMirroring.count
    #expect(await session.discard(displayID: 2))
    #expect(await session.hasOutstandingPreview == false)
    #expect(fake.appliedMirroring.count == before)
  }

  /// A SLAVE departing invalidates the set just as surely as the master does —
  /// the previewed change list names a display that is no longer there, so
  /// there is nothing left to apply the fallback to either.
  @Test func discardingASlaveOfThePreviewedSetAlsoDropsIt() async {
    let fake = FakeConfigurator()
    let session = makeSession(fake)
    let captured = MirrorTopology(fake.displays())
    _ = await session.begin(engageDecision(captured), from: captured)
    let before = fake.appliedMirroring.count
    #expect(await session.discard(displayID: 1))
    #expect(await session.hasOutstandingPreview == false)
    #expect(fake.appliedMirroring.count == before)
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
    #expect(await session.discard(displayID: 77) == false)
    #expect(await session.hasOutstandingPreview)
    #expect(await session.isCountingDown)
  }
}
