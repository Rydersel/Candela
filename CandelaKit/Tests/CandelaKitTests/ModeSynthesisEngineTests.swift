import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The verified engage/disengage sequence and its reverse unwind (SS1, SS10).
///
/// Everything here runs against the shared fake world, so every step of the
/// sequence is observable: the call log records the ORDER of the mirror change
/// and the virtual-display destroy, which is the part of the contract a call
/// count cannot express.
/// `Result<Void, _>` cannot be `Equatable` because `Void` is not, so the
/// disengage assertions read the failure out instead of comparing the whole
/// result.
extension Result {
  fileprivate var failureValue: Failure? {
    if case let .failure(failure) = self { failure } else { nil }
  }
}

@Suite("Mode synthesis engine (SS1, SS10)")
struct ModeSynthesisEngineTests {
  /// The rig's ultrawide, at the refresh Phase 0 measured the mirror
  /// preserving.
  private static let physical: CGDirectDisplayID = 2
  private static let secondPhysical: CGDirectDisplayID = 3

  private func world() -> FakeSynthesisWorld {
    let world = FakeSynthesisWorld()
    world.addPhysical(
      id: Self.physical, vendor: 0x1462, model: 1, serial: 0,
      logicalWidth: 3440, logicalHeight: 1440, refreshHz: 100
    )
    world.addPhysical(
      id: Self.secondPhysical, vendor: 0x10AC, model: 2, serial: 7,
      logicalWidth: 2160, logicalHeight: 3840, refreshHz: 120
    )
    return world
  }

  private func engine(_ world: FakeSynthesisWorld) -> ModeSynthesisEngine {
    ModeSynthesisEngine(
      virtualDisplays: FakeSynthesisVirtualDisplays(world),
      configurator: FakeSynthesisConfigurator(world),
      // Zero, so the nil-readback retry costs no wall clock here. Production's
      // default is a settling allowance, not a poll for an event.
      readbackRetryDelay: 0
    )
  }

  private var size: SyntheticSize {
    SyntheticSize(logicalWidth: 3268, logicalHeight: 1368, percentOfNative: 95)
  }

  private var secondSize: SyntheticSize {
    SyntheticSize(logicalWidth: 2052, logicalHeight: 3648, percentOfNative: 95)
  }

  private func engage(
    _ engine: ModeSynthesisEngine, _ world: FakeSynthesisWorld,
    _ size: SyntheticSize, on displayID: CGDirectDisplayID
  ) async -> Result<SynthesisPairing, SynthesisFailure> {
    await engine.engage(size, onPhysical: displayID, identityKey: world.identityKey(of: displayID))
  }

  // MARK: - Engage

  @Test func aHappyEngageTakesTheFirstSynthesisSlotAndRecordsThePairing() async throws {
    let world = world()
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    let pairing = try #require(try? result.get())
    #expect(pairing.slot == 4)
    #expect(pairing.physicalDisplayID == Self.physical)
    #expect(pairing.virtualDisplayID == FakeSynthesisWorld.virtualDisplayID(slot: 4))
    #expect(pairing.size == size)
    #expect(pairing.physicalIdentityKey == world.identityKey(of: Self.physical))
    #expect(await engine.pairing(forPhysical: Self.physical) == pairing)
    #expect(await engine.pairings() == [pairing])
  }

  /// The whole sequence, in order, with the mirror named in the direction that
  /// makes the PHYSICAL the slave of the virtual master: that is the direction
  /// `VirtualDisplayHost.breakMasteredMirrors` already unwinds.
  @Test func theEngageSequenceIsCreateThenMirrorInThatOrderAndNothingElse() async {
    let world = world()
    let engine = engine(world)

    _ = await engage(engine, world, size, on: Self.physical)

    #expect(world.calls == [
      .createVirtualDisplay(
        slot: 4, name: "Candela Scaled Size",
        logicalWidth: 3268, logicalHeight: 1368, hiDPI: true
      ),
      .applyMirroring(
        [MirrorChange(display: Self.physical, master: FakeSynthesisWorld.virtualDisplayID(slot: 4))],
        scope: .session
      ),
    ])
    #expect(world.mirrors[Self.physical] == FakeSynthesisWorld.virtualDisplayID(slot: 4))
  }

  @Test func aSecondEngageOnAnotherDisplayTakesTheSecondSynthesisSlot() async {
    let world = world()
    let engine = engine(world)

    _ = await engage(engine, world, size, on: Self.physical)
    let second = await engage(engine, world, secondSize, on: Self.secondPhysical)

    #expect((try? second.get())?.slot == 5)
    #expect(await engine.pairings().map(\.slot) == [4, 5])
  }

  /// The family is two slots wide (SS6), so a third physical has nowhere to go.
  /// It must be told that, not handed a slot outside the range.
  @Test func aThirdEngageIsRefusedForWantOfASlot() async {
    let world = world()
    world.addPhysical(id: 4, model: 3, logicalWidth: 1920, logicalHeight: 1080, refreshHz: 60)
    let engine = engine(world)

    _ = await engage(engine, world, size, on: Self.physical)
    _ = await engage(engine, world, secondSize, on: Self.secondPhysical)
    let third = await engage(
      engine, world, SyntheticSize(logicalWidth: 1824, logicalHeight: 1026, percentOfNative: 95),
      on: 4
    )

    #expect(third == .failure(.noFreeSlot))
    #expect(await engine.pairing(forPhysical: 4) == nil)
  }

  /// A slot the host refuses for a reason the pairing table cannot see: a
  /// display that did not depart strands slot 4 for the whole session. Without
  /// the fall-through that one stranding refuses every synthesis request from
  /// then on while slot 5 sits free.
  @Test func aSlotSpecificRefusalFallsThroughToTheNextSlot() async throws {
    let world = world()
    world.createFailure = .identityInUse
    world.createFailureSlots = [4]
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(try #require(try? result.get()).slot == 5)
    #expect(world.calls.first == .createVirtualDisplay(
      slot: 4, name: "Candela Scaled Size",
      logicalWidth: 3268, logicalHeight: 1368, hiDPI: true
    ))
  }

  /// A refusal about the SPEC rather than about the slot is reported at once.
  /// Retrying it on the next slot would burn the second slot's create on a
  /// request that is going to be refused the same way.
  @Test func aSpecRefusalIsReportedWithoutTryingTheOtherSlot() async {
    let world = world()
    world.createFailure = .settingsRejected
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.createFailed(.settingsRejected)))
    #expect(world.calls.count == 1)
  }

  /// Both slots stranded is not a free slot at all, and the last refusal is
  /// what the caller is told: it is the only thing that says why.
  @Test func aFamilyOfStrandedSlotsSurfacesTheHostsOwnRefusal() async {
    let world = world()
    world.createFailure = .identityInUse
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.createFailed(.identityInUse)))
    #expect(world.calls.count == 2)
  }

  @Test func anAbsentClassFamilyIsReportedRatherThanAttempted() async {
    let world = world()
    world.isAvailable = false
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.unavailable))
    #expect(world.calls.isEmpty)
  }

  // MARK: - Engage failures and their unwinds

  /// A create that failed never took a slot, so there is nothing to destroy.
  /// A destroy here would be the engine cleaning up after a display that does
  /// not exist.
  @Test func aFailedCreateSurfacesItsReasonAndDestroysNothing() async {
    let world = world()
    world.createFailure = .settingsRejected
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.createFailed(.settingsRejected)))
    #expect(world.calls == [
      .createVirtualDisplay(
        slot: 4, name: "Candela Scaled Size",
        logicalWidth: 3268, logicalHeight: 1368, hiDPI: true
      ),
    ])
    #expect(await engine.pairings().isEmpty)
  }

  /// The measured create-succeeded-but-stayed-1x case, reported the way the
  /// host reports it: the ENGAGE HELPER's verdict, recorded at creation. The
  /// creating process cannot read the display back, so a gate built on a live
  /// read would fail every engage on hardware and pass here. Nothing was
  /// mirrored yet, so the unwind is a destroy alone.
  @Test func aVirtualDisplayWhoseEngageHelperReportedFailureIsDestroyedAndReported() async {
    let world = world()
    world.hiDPIEngageVerdict = false
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.virtualModeNotAchieved))
    #expect(world.calls == [
      .createVirtualDisplay(
        slot: 4, name: "Candela Scaled Size",
        logicalWidth: 3268, logicalHeight: 1368, hiDPI: true
      ),
      .destroyVirtualDisplay(slot: 4),
    ])
    #expect(world.liveSlots.isEmpty)
    #expect(await engine.pairings().isEmpty)
    // The slot is free again, so the next attempt takes 4 rather than 5.
    world.hiDPIEngageVerdict = true
    #expect((try? await engage(engine, world, size, on: Self.physical).get())?.slot == 4)
  }

  @Test func aRefusedMirrorDestroysTheVirtualDisplayItCreated() async {
    let world = world()
    world.mirrorFailure = DisplayConfigError(cgErrorCode: 1001)
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.mirrorRefused))
    #expect(world.calls.last == .destroyVirtualDisplay(slot: 4))
    #expect(world.liveSlots.isEmpty)
    #expect(await engine.pairings().isEmpty)
  }

  /// The topology says mirrored and the panel did not follow: exactly the
  /// class of divergence a success return cannot rule out. The unwind must
  /// break the mirror BEFORE destroying the master, and the log is what proves
  /// the order rather than the mere fact of both.
  @Test func aPanelThatKeepsItsOwnGeometryBreaksTheMirrorThenDestroysTheVirtualDisplay() async {
    let world = world()
    world.physicalKeepsOwnModeWhileMirrored = true
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.engageNotAchieved))
    #expect(world.calls == [
      .createVirtualDisplay(
        slot: 4, name: "Candela Scaled Size",
        logicalWidth: 3268, logicalHeight: 1368, hiDPI: true
      ),
      .applyMirroring(
        [MirrorChange(display: Self.physical, master: FakeSynthesisWorld.virtualDisplayID(slot: 4))],
        scope: .session
      ),
      .applyMirroring(
        [MirrorChange(display: Self.physical, master: kCGNullDirectDisplay)], scope: .session
      ),
      .destroyVirtualDisplay(slot: 4),
    ])
    #expect(world.mirrors.isEmpty)
    #expect(await engine.pairings().isEmpty)
  }

  /// A commit that reports success over a topology it never moved is caught by
  /// `MirrorVerification` inside the apply, exactly as production catches it,
  /// so it reaches the engine as a REFUSAL rather than as a divergent topology.
  /// Nothing is mirroring, so no break is staged (a transaction of only no-ops
  /// fails at the commit) and the destroy stands alone.
  @Test func aCommitThatDidNotHonourTheBatchIsRefusedByTheApplyItself() async {
    let world = world()
    world.acceptMirrorButLeaveTopologyUnchanged = true
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.mirrorRefused))
    #expect(world.calls.last == .destroyVirtualDisplay(slot: 4))
    #expect(world.liveSlots.isEmpty)
  }

  /// The topology half of the engage check, isolated. The apply IS honoured, so
  /// `MirrorVerification` passes and the panel really does report the master's
  /// geometry; only the snapshot the engine takes afterwards disagrees. Deleting
  /// the `mirrorsDisplay` half of `engageLanded` is what this test exists to
  /// catch.
  @Test func aTopologySnapshotThatDoesNotShowTheMirrorFailsTheEngage() async {
    let world = world()
    let engine = engine(world)
    world.displaysHidesTheMirror = true

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.engageNotAchieved))
    #expect(world.calls.last == .destroyVirtualDisplay(slot: 4))
    #expect(await engine.pairings().isEmpty)
  }

  /// A destroy that leaves the display online strands the slot, and the engine
  /// says so rather than reporting the step's own failure and forgetting the
  /// virtual display it can no longer reach. The pairing is RETAINED so a
  /// later disengage can retry and every carve-out keeps treating the set as
  /// synthesis.
  @Test func anIncompleteUnwindOnEngageIsReportedAndThePairingRetained() async {
    let world = world()
    world.hiDPIEngageVerdict = false
    world.destroySucceeds = false
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.unwindIncomplete))
    let retained = await engine.pairing(forPhysical: Self.physical)
    #expect(retained?.slot == 4)
    #expect(retained?.virtualDisplayID == FakeSynthesisWorld.virtualDisplayID(slot: 4))
    // The host drops the slot before it releases, so the display is stranded
    // ONLINE while the slot reads free. The destroy's return value is the only
    // thing that could have told the engine, which is why discarding it would
    // report a clean unwind over a display nothing can destroy again.
    #expect(world.liveSlots.isEmpty)
    #expect(world.onlineVirtualDisplayIDs == [FakeSynthesisWorld.virtualDisplayID(slot: 4)])
  }

  // MARK: - Disengage

  @Test func disengageBreaksTheMirrorThenDestroysTheVirtualDisplay() async {
    let world = world()
    let engine = engine(world)
    _ = await engage(engine, world, size, on: Self.physical)

    let result = await engine.disengage(fromPhysical: Self.physical)

    #expect(result.failureValue == nil)
    #expect(Array(world.calls.suffix(2)) == [
      .applyMirroring(
        [MirrorChange(display: Self.physical, master: kCGNullDirectDisplay)], scope: .session
      ),
      .destroyVirtualDisplay(slot: 4),
    ])
    #expect(world.mirrors.isEmpty)
    #expect(world.liveSlots.isEmpty)
    #expect(await engine.pairings().isEmpty)
  }

  @Test func disengagingADisplayThatWasNeverEngagedIsRefusedByName() async {
    let world = world()
    let engine = engine(world)

    let result = await engine.disengage(fromPhysical: Self.physical)

    #expect(result.failureValue == .notEngaged)
    #expect(world.calls.isEmpty)
  }

  @Test func aDestroyThatDoesNotDepartLeavesTheDisengageIncompleteAndThePairingStanding() async {
    let world = world()
    let engine = engine(world)
    _ = await engage(engine, world, size, on: Self.physical)
    world.destroySucceeds = false

    let result = await engine.disengage(fromPhysical: Self.physical)

    #expect(result.failureValue == .unwindIncomplete)
    #expect(await engine.pairing(forPhysical: Self.physical)?.slot == 4)
    // The mirror still came off first: an incomplete unwind is not a skipped
    // one.
    #expect(world.mirrors.isEmpty)
  }

  /// The RETRY after a stranded destroy, which is the whole point of retaining
  /// the pairing. The first attempt dropped the slot entry before releasing the
  /// token, so the second one reaches the host's "no such slot" arm while the
  /// virtual display is still online. Answering true there would report a clean
  /// revert over a display nothing can destroy again, and take the pairing that
  /// is its only record with it: SS10's departure check is this return value
  /// and nothing else.
  @Test func aRetriedDisengageOverAStrandedSlotIsStillIncomplete() async {
    let world = world()
    let engine = engine(world)
    _ = await engage(engine, world, size, on: Self.physical)
    world.destroySucceeds = false

    let first = await engine.disengage(fromPhysical: Self.physical)
    #expect(first.failureValue == .unwindIncomplete)
    #expect(world.liveSlots.isEmpty)
    #expect(world.onlineVirtualDisplayIDs == [FakeSynthesisWorld.virtualDisplayID(slot: 4)])

    let retry = await engine.disengage(fromPhysical: Self.physical)

    #expect(retry.failureValue == .unwindIncomplete)
    #expect(await engine.pairing(forPhysical: Self.physical)?.slot == 4)
    #expect(world.onlineVirtualDisplayIDs == [FakeSynthesisWorld.virtualDisplayID(slot: 4)])
  }

  /// SS10's last disengage step. The mirror came off, the virtual display went
  /// away, and the panel is still on the synthesized geometry: the size is
  /// still on the glass, so the teardown did not finish whatever the topology
  /// now says.
  @Test func aPanelStillOnTheMasterGeometryAfterTheBreakLeavesTheDisengageIncomplete() async {
    let world = world()
    let engine = engine(world)
    _ = await engage(engine, world, size, on: Self.physical)
    world.panelStaysOnMasterGeometryAfterUnmirror = true

    let result = await engine.disengage(fromPhysical: Self.physical)

    #expect(result.failureValue == .unwindIncomplete)
    #expect(await engine.pairing(forPhysical: Self.physical)?.slot == 4)
    // The break and the destroy both ran and both landed: the panel is the only
    // thing that did not come back.
    #expect(world.mirrors.isEmpty)
    #expect(world.liveSlots.isEmpty)
    #expect(Array(world.calls.suffix(2)) == [
      .applyMirroring(
        [MirrorChange(display: Self.physical, master: kCGNullDirectDisplay)], scope: .session
      ),
      .destroyVirtualDisplay(slot: 4),
    ])
  }

  /// The half of SS10's last step the rendered-size comparison alone cannot
  /// see, and the reason that comparison stopped being enough: the engage tail
  /// re-times the slave onto its own mode, so from two seconds after an engage
  /// the panel already reports its own geometry and a check that only asked
  /// "is this still the rendered size" could no longer be entered by any input.
  ///
  /// Here the break returns success, the panel is off the rendered size, and it
  /// is reporting a descriptor that appears in no enumeration of its own. That
  /// is a display that did not come back, and the teardown has to say so.
  @Test func aPanelReportingAModeItDoesNotPublishLeavesTheDisengageIncomplete() async {
    let world = world()
    let engine = engine(world)
    _ = await engage(engine, world, size, on: Self.physical)
    world.panelReportsAnUnlistedModeAfterUnmirror = true

    let result = await engine.disengage(fromPhysical: Self.physical)

    #expect(result.failureValue == .unwindIncomplete)
    #expect(await engine.pairing(forPhysical: Self.physical)?.slot == 4)
    // The control: the descriptor it reports is NOT the rendered size, so the
    // old comparison would have passed this teardown.
    let reported = FakeSynthesisConfigurator(world).currentMode(for: Self.physical)
    #expect(reported?.logicalWidth != size.logicalWidth)
    #expect(world.mirrors.isEmpty)
    #expect(world.liveSlots.isEmpty)
  }

  /// A panel that will not say what it is running is NOT a failed teardown.
  ///
  /// This runs immediately after breaking a mirror and destroying the display
  /// the panel was scanning, so a nil readback is the ordinary shape of a
  /// display mid-reconfiguration rather than evidence about the glass. Judged
  /// as a failure it would retain the pairing: one of two slots held for the
  /// session, the opt-out refusing, and an engine failure shown to somebody
  /// whose teardown worked.
  @Test func aPanelThatWillNotReportItsModeStillCompletesTheDisengage() async {
    let world = world()
    let engine = engine(world)
    _ = await engage(engine, world, size, on: Self.physical)
    world.panelReadbackIsUnreadable = true

    let result = await engine.disengage(fromPhysical: Self.physical)

    // The control: the display really is still attached, so this is not the
    // departed-panel case one test above.
    #expect(world.configuredDisplays().contains { $0.id == Self.physical })
    #expect(result.failureValue == nil)
    #expect(await engine.pairing(forPhysical: Self.physical) == nil)
    #expect(world.liveSlots.isEmpty, "and the slot goes back")
  }

  /// The positive control for both failure tests above: with the panel back on
  /// a mode it publishes, the same last step passes and the pairing goes.
  @Test func aPanelBackOnAModeItPublishesCompletesTheDisengage() async {
    let world = world()
    let engine = engine(world)
    _ = await engage(engine, world, size, on: Self.physical)

    let result = await engine.disengage(fromPhysical: Self.physical)

    #expect(result.failureValue == nil)
    #expect(await engine.pairing(forPhysical: Self.physical) == nil)
  }

  /// A departed panel is not a failed teardown. The last step has no glass to
  /// ask about, and answering "incomplete" would RETAIN the pairing for
  /// hardware that is not attached, holding one of two slots for the rest of
  /// the session.
  @Test func aDepartedPanelStillCompletesItsDisengage() async {
    let world = world()
    let engine = engine(world)
    _ = await engage(engine, world, size, on: Self.physical)
    world.removePhysical(Self.physical)

    let result = await engine.disengage(fromPhysical: Self.physical)

    #expect(result.failureValue == nil)
    #expect(await engine.pairings().isEmpty)
  }

  /// The virtual display is minted at the fixed LOW rate no matter what the
  /// panel runs: the glass rate belongs to the engage tail's retime, and a
  /// master minted at the panel's 175 Hz drove WindowServer to composite the
  /// 2x surface at that rate, with a lagging cursor and stalls on other
  /// displays [MEASURED 2026-08-18].
  @Test func theVirtualDisplayIsCreatedAtTheFixedLowRefresh() async throws {
    let world = world()
    let engine = engine(world)

    let pairing = try #require(try? await engage(engine, world, size, on: Self.physical).get())

    let handle = try #require(world.liveHandles().first { $0.slot == pairing.slot })
    #expect(handle.spec.refreshHz == 60)
  }

  /// The same fixed rate when the panel reports no usable rate: a spec
  /// carrying zero hertz is a spec macOS has no reason to honour.
  @Test func aPanelWithNoUsableRateMintsTheVirtualDisplayAtTheFallbackRate() async throws {
    let world = FakeSynthesisWorld()
    world.addPhysical(
      id: Self.physical, vendor: 0x1462, model: 1, serial: 0,
      logicalWidth: 3440, logicalHeight: 1440, refreshHz: 0
    )
    let engine = engine(world)

    let pairing = try #require(try? await engage(engine, world, size, on: Self.physical).get())

    let handle = try #require(world.liveHandles().first { $0.slot == pairing.slot })
    #expect(handle.spec.refreshHz == 60)
  }

  /// A break that fails still destroys, because a virtual display nothing can
  /// reach is worse than a set that outlived its master; the result says the
  /// unwind did not complete either way.
  @Test func aBreakThatFailsStillDestroysAndIsReportedIncomplete() async {
    let world = world()
    let engine = engine(world)
    _ = await engage(engine, world, size, on: Self.physical)
    world.mirrorFailure = DisplayConfigError(cgErrorCode: 1001)

    let result = await engine.disengage(fromPhysical: Self.physical)

    #expect(result.failureValue == .unwindIncomplete)
    #expect(Array(world.calls.suffix(2)) == [
      .applyMirroring(
        [MirrorChange(display: Self.physical, master: kCGNullDirectDisplay)], scope: .session
      ),
      .destroyVirtualDisplay(slot: 4),
    ])
    #expect(world.liveSlots.isEmpty)
  }

  /// Re-engaging a display that is already paired must tear the old set down
  /// first. Without it the previous slot leaves the pairing table and nothing
  /// can ever destroy the display standing in it.
  @Test func engagingASecondSizeOnAnEngagedDisplayTearsTheFirstSetDownFirst() async {
    let world = world()
    let engine = engine(world)
    _ = await engage(engine, world, size, on: Self.physical)

    let smaller = SyntheticSize(logicalWidth: 3096, logicalHeight: 1296, percentOfNative: 90)
    let result = await engage(engine, world, smaller, on: Self.physical)

    #expect((try? result.get())?.size == smaller)
    #expect(await engine.pairings().count == 1)
    #expect(world.liveSlots == [4])
    #expect(Array(world.calls.dropFirst(2)) == [
      .applyMirroring(
        [MirrorChange(display: Self.physical, master: kCGNullDirectDisplay)], scope: .session
      ),
      .destroyVirtualDisplay(slot: 4),
      .createVirtualDisplay(
        slot: 4, name: "Candela Scaled Size",
        logicalWidth: 3096, logicalHeight: 1296, hiDPI: true
      ),
      .applyMirroring(
        [MirrorChange(display: Self.physical, master: FakeSynthesisWorld.virtualDisplayID(slot: 4))],
        scope: .session
      ),
    ])
  }

  /// Synthesis applies no mode and rotates nothing: the size comes from the
  /// virtual display's own geometry, reached through the mirror. A stray
  /// `apply` would be a configuration transaction over a `.synthesized` row,
  /// which no configurator accepts.
  @Test func theEngineNeverAppliesAModeOrARotation() async {
    let world = world()
    let engine = engine(world)

    _ = await engage(engine, world, size, on: Self.physical)
    _ = await engine.disengage(fromPhysical: Self.physical)

    #expect(!world.calls.contains { if case .unexpected = $0 { true } else { false } })
  }
}
