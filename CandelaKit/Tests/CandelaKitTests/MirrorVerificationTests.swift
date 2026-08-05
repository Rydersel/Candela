import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// #53. `CGCompleteDisplayConfiguration` can return `.success` without
/// honouring the request — measured twice on the mirroring hardware pass, with
/// every stage AND the complete returning `.success` in both cases
/// (`docs/spikes/2026-08-04-mirroring-hardware-pass.md` §6.2).
///
/// Neither list is reachable from the shipping policy today:
/// `MirrorTopologyPolicy` emits no duplicates and no cycles. The check exists
/// because `CoreGraphicsDisplayConfigurator.apply` already carries the same
/// lesson for a display MODE, and because this is the one place in the app
/// where the PLATFORM can hand back a success nothing challenges.
@Suite("Mirror apply verification (#53)")
struct MirrorVerificationTests {
  /// Reads like `CGDisplayMirrorsDisplay`: the parent a display ACTUALLY has
  /// now. Anything absent is standalone, which is what CoreGraphics reports.
  private func achieved(
    _ parents: [CGDirectDisplayID: CGDirectDisplayID]
  ) -> (CGDirectDisplayID) -> CGDirectDisplayID {
    { parents[$0] ?? kCGNullDirectDisplay }
  }

  // MARK: - The rule, against the two measured cases

  /// Measured: `[166→167, 167→166]` achieved `166→167, 167→0`. CoreGraphics
  /// took the first change, refused to close the loop, and said `.success`.
  @Test func aCyclicChangeListIsUnhonouredWhenCoreGraphicsBreaksTheCycle() {
    let requested = [
      MirrorChange(display: 166, master: 167),
      MirrorChange(display: 167, master: 166),
    ]
    #expect(
      MirrorVerification.unhonoured(
        in: requested,
        achievedParent: achieved([166: 167, 167: kCGNullDirectDisplay])
      ) == MirrorChange(display: 167, master: 166)
    )
  }

  /// Measured: `[166→167, 166→168]` applied the FIRST change and silently
  /// discarded the second. The list is self-contradictory, which is exactly why
  /// a return code cannot be the evidence — CoreGraphics resolved it by
  /// picking, not by refusing.
  @Test func aChangeListNamingOneDisplayTwiceIsUnhonouredWhenTheSecondIsDiscarded() {
    let requested = [
      MirrorChange(display: 166, master: 167),
      MirrorChange(display: 166, master: 168),
    ]
    #expect(
      MirrorVerification.unhonoured(in: requested, achievedParent: achieved([166: 167]))
        == MirrorChange(display: 166, master: 168)
    )
  }

  /// The null-master direction is checked on the same terms, and it is the one
  /// that matters most in shipped code: a break that CoreGraphics accepts and
  /// only half performs is the partial break `MirrorRefusal.residualMembers`
  /// exists to describe, arriving from the platform instead of from the policy.
  @Test func aBreakThatLeavesADisplayMirroringIsUnhonoured() {
    let requested = [
      MirrorChange(display: 2, master: kCGNullDirectDisplay),
      MirrorChange(display: 3, master: kCGNullDirectDisplay),
    ]
    #expect(
      MirrorVerification.unhonoured(in: requested, achievedParent: achieved([3: 1]))
        == MirrorChange(display: 3, master: kCGNullDirectDisplay)
    )
  }

  /// The negative half, stated so the check cannot be satisfied by a rule that
  /// reports everything. An honoured engage — and an empty batch, which opens
  /// no transaction at all — report nothing.
  @Test func anHonouredChangeListAndAnEmptyOneBothReportNothing() {
    let engage = [
      MirrorChange(display: 1, master: 2),
      MirrorChange(display: 3, master: 2),
    ]
    #expect(
      MirrorVerification.unhonoured(in: engage, achievedParent: achieved([1: 2, 3: 2])) == nil
    )
    #expect(MirrorVerification.unhonoured(in: [], achievedParent: achieved([:])) == nil)
  }

  // MARK: - Through a configurator that accepts and ignores

  private func trio() -> FakeConfigurator {
    let fake = FakeConfigurator()
    fake.configuredDisplays = [
      MirrorFixtures.display(166),
      MirrorFixtures.display(167),
      MirrorFixtures.display(168),
    ]
    return fake
  }

  /// No injection at all: the fake diverges here because its post-state applies
  /// the FIRST change for a display named twice, which is what CoreGraphics was
  /// measured doing. The request said 166 should mirror 168; the machine says
  /// 167; `applyMirroring` must not return normally.
  @Test func applyingAListThatNamesOneDisplayTwiceThrowsRatherThanReturningNormally() {
    let fake = trio()
    #expect(throws: DisplayConfigError(cgErrorCode: CGError.failure.rawValue)) {
      try fake.applyMirroring(
        [MirrorChange(display: 166, master: 167), MirrorChange(display: 166, master: 168)],
        scope: .preview
      )
    }
  }

  @Test func applyingACyclicListThrowsWhenCoreGraphicsBreaksTheCycle() {
    let fake = trio()
    fake.divergeNextMirroringTo = [167: kCGNullDirectDisplay]
    #expect(throws: DisplayConfigError(cgErrorCode: CGError.failure.rawValue)) {
      try fake.applyMirroring(
        [MirrorChange(display: 166, master: 167), MirrorChange(display: 167, master: 166)],
        scope: .preview
      )
    }
  }

  /// The throw says "this is not what you asked for", NOT "nothing happened" —
  /// and the difference is the whole reason the contract note on
  /// `applyMirroring` had to be rewritten. CoreGraphics committed: the batch is
  /// spent and the machine has moved. A test that let the fake unwind here
  /// would enshrine the comfortable version of this failure rather than the
  /// measured one.
  @Test func aDivergentApplyLeavesTheAchievedTopologyStandingAndRecorded() {
    let fake = trio()
    fake.divergeNextMirroringTo = [167: kCGNullDirectDisplay]
    #expect(throws: DisplayConfigError.self) {
      try fake.applyMirroring(
        [MirrorChange(display: 166, master: 167), MirrorChange(display: 167, master: 166)],
        scope: .preview
      )
    }
    #expect(fake.appliedMirroring.count == 1)
    let live = MirrorTopology(fake.displays())
    #expect(live.master(of: 166) == 167)
    #expect(live.master(of: 167) == nil)
    #expect(live.masters == [167])
  }

  /// The guarantee has to hold for everything the app can actually emit, or the
  /// check is a regression waiting to happen rather than a safety net: the
  /// hardware pass measured all four of these honoured, and a check that
  /// rejected one of them would break mirroring outright.
  @Test func everyChangeListTheShippingPolicyEmitsIsHonouredAndDoesNotThrow() throws {
    let fake = FakeConfigurator()
    fake.configuredDisplays = MirrorFixtures.unmirroredPair.displays
    let captured = MirrorTopology(fake.displays())

    guard case let .engage(_, engageChanges) = MirrorTopologyPolicy.engage(captured, master: 2)
    else { Issue.record("engage refused"); return }
    try fake.applyMirroring(engageChanges, scope: .preview)
    #expect(MirrorTopology(fake.displays()).master(of: 1) == 2)

    // The revert of that engage, computed the way the session computes it.
    let backToCapture = MirrorTopologyPolicy.changes(
      from: MirrorTopology(fake.displays()), to: captured
    )
    try fake.applyMirroring(backToCapture, scope: .session)
    #expect(MirrorTopology(fake.displays()) == captured)

    // And a break, over a set built first.
    try fake.applyMirroring(engageChanges, scope: .session)
    guard case let .disengage(breakChanges, _) =
      MirrorTopologyPolicy.disengage(MirrorTopology(fake.displays()), containing: 2)
    else { Issue.record("disengage refused"); return }
    try fake.applyMirroring(breakChanges, scope: .session)
    #expect(MirrorTopology(fake.displays()).masters.isEmpty)
  }

  // MARK: - The second call

  /// **The question the fix has to answer, not just the first press.** A
  /// divergent engage throws with nothing outstanding, so the countdown is not
  /// there to rescue the topology CoreGraphics chose. What must be true is that
  /// the NEXT attempt is computed from that topology rather than from what the
  /// app believed, and therefore lands — the failure this feature has produced
  /// before is a retry that emits a no-op and reports success forever.
  @Test func theRetryAfterADivergentEngageIsComputedFromTheAchievedTopologyAndSucceeds() async {
    let fake = trio()
    let session = MirrorPreviewSession(configurator: fake)
    let captured = MirrorTopology(fake.displays())

    fake.divergeNextMirroringTo = [167: kCGNullDirectDisplay]
    let cyclic = MirrorToggleDecision.engage(
      master: 166,
      changes: [MirrorChange(display: 166, master: 167), MirrorChange(display: 167, master: 166)]
    )
    let first = await session.begin(cyclic, from: captured)
    #expect(first.failureError == DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
    #expect(await session.hasOutstandingPreview == false)

    // Exactly what `MirroringCoordinator.engage` does: sample LIVE, then decide.
    // The live sample is the divergence, not the request.
    let live = MirrorTopology(fake.displays())
    #expect(live.master(of: 166) == 167)
    let decision = MirrorTopologyPolicy.engage(live, master: 168)
    guard case let .engage(_, changes) = decision else {
      Issue.record("the retry was refused: \(decision)")
      return
    }
    #expect(!changes.isEmpty)
    #expect(await session.begin(decision, from: live).failureError == nil)
    let after = MirrorTopology(fake.displays())
    #expect(after.masters == [168])
    #expect(after.slaves(of: 168) == [166, 167])
  }

  /// The other second call, on the path that DOES stay outstanding. A revert
  /// whose apply diverges leaves the preview and its fallback intact, and the
  /// retry recomputes `changes(from:to:)` against the live topology — so the
  /// second batch is a DIFFERENT, smaller list naming only what is still wrong.
  /// Re-sending the first list is what would make the retry a no-op.
  @Test func theRetryAfterADivergentRevertRecomputesFromLiveAndRestoresTheCapture() async throws {
    let fake = FakeConfigurator()
    fake.configuredDisplays = [
      MirrorFixtures.display(1, builtIn: true),
      MirrorFixtures.display(2),
      MirrorFixtures.display(3),
    ]
    let captured = MirrorTopology(fake.displays())
    let session = MirrorPreviewSession(configurator: fake, countdownSeconds: 1)

    guard case let .engage(master, changes) = MirrorTopologyPolicy.engage(captured, master: 2)
    else { Issue.record("engage refused"); return }
    #expect(await session.begin(.engage(master: master, changes: changes), from: captured)
      .failureError == nil)
    let answered = try #require(await session.previewedTopology)

    // The expiry's revert is [1→0, 3→0]; CoreGraphics keeps 3 mirroring anyway.
    fake.divergeNextMirroringTo = [3: 2]
    let expiry = await session.tick()
    #expect(expiry == .failed(DisplayConfigError(cgErrorCode: CGError.failure.rawValue)))
    // Nothing was resolved, so the fallback is still held and still offered.
    #expect(await session.hasOutstandingPreview)

    let batchesBefore = fake.appliedMirroring.count
    #expect(await session.revert(answered) == .reverted)
    let retry = try #require(fake.appliedMirroring.last)
    #expect(fake.appliedMirroring.count == batchesBefore + 1)
    // Recomputed, not replayed: 1 is already unmirrored, so only 3 is named.
    #expect(retry.changes == [MirrorChange(display: 3, master: kCGNullDirectDisplay)])
    #expect(MirrorTopology(fake.displays()) == captured)
    #expect(await session.hasOutstandingPreview == false)
  }
}

/// The other platform fact from the same pass (§4.2), audited rather than
/// worked around: every `CGDisplayIsBuiltin` call in CandelaKit reads an ID it
/// just took from `CGGetOnlineDisplayList`, so none of them can be handed an
/// unknown one. This pins the hazard that makes that a rule worth keeping.
@Suite("CGDisplayIsBuiltin over an unknown display id (#53)")
struct BuiltInDisplayProbeTests {
  /// Measured: `-1`, not `0`. Asserted as "not zero" rather than as `-1`
  /// because the hazard is the polarity, not the magnitude — any non-zero
  /// return makes a `!= 0` test call an unknown ID the laptop panel, which is
  /// how the hardware pass's own safety guard refused a probe.
  ///
  /// Safe to call: reading a nonexistent display ID configures nothing.
  @Test func anUnknownIdIsNotReportedZeroSoANotEqualZeroTestWouldCallItBuiltIn() {
    #expect(CGDisplayIsBuiltin(0xDEAD_BEEF) != 0)
  }

  /// …and the form `IntelDDC.ioFramebufferPortFromDisplayId` uses — equality
  /// with 1, on the only ID in the package whose provenance is a caller rather
  /// than the online list — is what makes that site safe. If this ever fails,
  /// that call site is misclassifying unknown IDs as the built-in.
  @Test func anUnknownIdDoesNotEqualTrueSoTheEqualityFormIsSafe() {
    #expect(CGDisplayIsBuiltin(0xDEAD_BEEF) != boolean_t(truncating: true))
  }
}
