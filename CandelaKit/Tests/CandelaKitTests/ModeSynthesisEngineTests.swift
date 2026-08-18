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
      configurator: FakeSynthesisConfigurator(world)
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

  /// The measured create-succeeded-but-stayed-1x case. Nothing was mirrored
  /// yet, so the unwind is a destroy alone.
  @Test func aVirtualDisplayThatDidNotReachTwoTimesIsDestroyedAndReported() async {
    let world = world()
    world.virtualDisplayStaysNonHiDPI = true
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
    world.virtualDisplayStaysNonHiDPI = false
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

  /// The other half of the engage check: a commit that reports success over a
  /// topology it never moved. Nothing is mirroring, so no break is staged (a
  /// transaction of only no-ops fails at the commit), and the destroy stands
  /// alone.
  @Test func aMirrorTheTopologyNeverTookIsCaughtByTheSnapshotCheck() async {
    let world = world()
    world.acceptMirrorButLeaveTopologyUnchanged = true
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.engageNotAchieved))
    #expect(world.calls.last == .destroyVirtualDisplay(slot: 4))
    #expect(world.liveSlots.isEmpty)
  }

  /// A destroy that leaves the display online strands the slot, and the engine
  /// says so rather than reporting the step's own failure and forgetting the
  /// virtual display it can no longer reach. The pairing is RETAINED so a
  /// later disengage can retry and every carve-out keeps treating the set as
  /// synthesis.
  @Test func anIncompleteUnwindOnEngageIsReportedAndThePairingRetained() async {
    let world = world()
    world.virtualDisplayStaysNonHiDPI = true
    world.destroySucceeds = false
    let engine = engine(world)

    let result = await engage(engine, world, size, on: Self.physical)

    #expect(result == .failure(.unwindIncomplete))
    let retained = await engine.pairing(forPhysical: Self.physical)
    #expect(retained?.slot == 4)
    #expect(retained?.virtualDisplayID == FakeSynthesisWorld.virtualDisplayID(slot: 4))
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
