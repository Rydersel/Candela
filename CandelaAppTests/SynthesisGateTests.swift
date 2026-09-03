import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// The reconfiguration-gate claim across a synthesized-size pick, end to end
/// through the real
/// coordinators, the real preview session, the real engine and the real gate.
///
/// `DisplayReconfigurationGateTests` characterises the gate itself and cannot
/// catch what this catches: the ordering lives in `performSynthesisSelect`, so a
/// claim taken AFTER the engage, or released by the stand-down that precedes it,
/// leaves the gate open for the tens of seconds the engine runs and the thirty
/// the countdown stands. Both mistakes pass every pure gate test.
///
/// End to end means the whole sequence, not just its front half: the pin below
/// drives the select through engage, revert and disengage, and asserts the
/// pairing comes down and the gate comes back.
@Suite("Synthesis holds the reconfiguration gate") @MainActor
struct SynthesisGateTests {
  private typealias Fixture = SynthesisFixture
  private static let panelID = SynthesisFixture.panelID
  private static let secondPanelID = SynthesisFixture.secondPanelID
  private static let nativeWidth = SynthesisFixture.nativeWidth

  @Test func anOptedInPanelOffersSynthesizedStops() async {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let stops = fixture.modes.catalogs[Self.panelID]?.syntheticStops ?? []
    #expect(!stops.isEmpty)
    #expect(stops.allSatisfy { $0.logicalWidth <= Self.nativeWidth })
    #expect(fixture.modes.catalogs[Self.panelID]?.rows.contains { $0.mode.isSynthesized } == true)
    await fixture.revertAnyPreview()
  }

  /// Opted out, the picker holds no synthesized row at all. The ladder is
  /// still arithmetically generable from this panel, so this is the opt-in
  /// doing the work rather than a panel with nothing to offer.
  @Test func anOptedOutPanelOffersNoSynthesizedRowAtAll() async {
    let fixture = Fixture(optedIn: false)
    defer { fixture.forgetPrefs() }
    let catalog = fixture.modes.catalogs[Self.panelID]
    #expect(catalog?.syntheticStops.isEmpty == true)
    #expect(catalog?.rows.contains { $0.mode.isSynthesized } == false)
    #expect(catalog?.rows.isEmpty == false, "the published rows must still be there")
    await fixture.revertAnyPreview()
  }

  /// The pin. `create` is the engine's first hardware step and it runs inside
  /// `session.begin`, so a competing claimant refused AT THAT INSTANT is
  /// evidence the claim was taken before the engage and is still held during it.
  @Test func theDisplayModesClaimIsHeldWhileTheEngineIsEngaging() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let stop = try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)

    // `create` blocks on the engine's executor until this test lets it go. That
    // is the only way to observe the gate mid-engage: the hook is synchronous
    // and the gate is an actor, so it cannot read the holder itself.
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    fixture.host.onCreate = {
      entered.signal()
      proceed.wait()
    }

    fixture.modes.select(
      SyntheticSizeCatalog.row(for: stop), on: Self.panelID,
      from: .settings, surface: .settingsBanner
    )
    // Off the cooperative pool: `wait()` is unavailable in an async context, and
    // parking a pool thread on a semaphore is what this needs to avoid.
    //
    // DEADLINED, and the result is carried back rather than recorded on the
    // waiting thread. An unbounded wait here would turn "the select never
    // reached the engage" into a hung suite that no cancellation can reach: the
    // thread is blocked in a semaphore, not suspended at an await. Five seconds
    // is three orders of magnitude past what the fakes need, so it can only
    // expire on a real regression.
    let engineEntered: Bool = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
      }
    }
    guard engineEntered else {
      // Signalled anyway: harmless if nothing is waiting, and it keeps a late
      // arrival from parking a thread for the rest of the run.
      proceed.signal()
      Issue.record("the engine never entered `create`: the select did not reach the engage")
      return
    }

    let refusal = await fixture.gate.claim(.mirroring)
    proceed.signal()
    #expect(refusal.refusedBy == .displayModes)

    await fixture.settle()
    await fixture.revertAnyPreview()
    // The far end of the same sequence, and the reason the world had to learn
    // to restore a slave's own mode: the revert reaches the engine's disengage,
    // the panel comes back to its own geometry, and the pairing goes. Without
    // it this answered `unwindIncomplete` and the claim below stayed held.
    #expect(fixture.synthesis.pairings.isEmpty, "the revert must take the pairing down")
    let afterRevert = await fixture.gate.claim(.mirroring)
    #expect(afterRevert.isGranted, "and the gate must come back with it")
    await fixture.gate.release(.mirroring)
  }

  /// A reset issued while an engage is mid-flight refuses and writes NOTHING.
  ///
  /// The pairing snapshot is the state every teardown path reads, and it is
  /// EMPTY for the whole of an engage: the coordinator re-reads the engine's
  /// table only after the operation it performed returns. So the per-display
  /// reset, which is ungated on the hub, used to ask "is anything engaged?",
  /// hear "no", clear both keys, and finish before the engage landed. What was
  /// left was a synthesis set with its opt-in off, which is exactly the state
  /// where nothing on screen offers to take it down.
  ///
  /// The parked `create` is what makes that window observable: it holds the
  /// engine's executor open for as long as this test wants it.
  @Test func aResetDuringAnEngageRefusesAndWritesNothing() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)
    let prefs = fixture.prefs

    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    fixture.host.onCreate = {
      entered.signal()
      proceed.wait()
    }

    fixture.modes.select(
      SyntheticSizeCatalog.row(for: stop), on: Self.panelID,
      from: .settings, surface: .settingsBanner
    )
    // Deadlined for `theDisplayModesClaimIsHeldWhileTheEngineIsEngaging`'s
    // reason: a blocked thread is not a suspended one and no cancellation
    // reaches it.
    let engineEntered: Bool = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
      }
    }
    guard engineEntered else {
      proceed.signal()
      Issue.record("the engine never entered `create`: the select did not reach the engage")
      return
    }

    // The vacuous reading the guard exists for, asserted rather than described:
    // mid-engage the snapshot says nothing is engaged, on a machine that is
    // about to have a synthesis set on it.
    #expect(fixture.synthesis.pairings.isEmpty)
    #expect(fixture.synthesis.isWorking)

    let didReset = await fixture.synthesis.reset(display)
    let didOptOut = await fixture.synthesis.setOptIn(false, on: display)
    let didUnwind = await fixture.synthesis.disengageAllForReset()

    #expect(!didReset, "a per-display reset must refuse over an engage in flight")
    #expect(!didOptOut, "and so must the opt-out, for the same reason")
    #expect(!didUnwind, "and the whole-app teardown, which reports it to its caller")
    #expect(fixture.synthesis.refusal?.reason == .busy)
    // The half that matters most: the ordering is only honoured if a refused
    // teardown leaves both keys exactly as it found them.
    #expect(prefs.offerSyntheticSizes)
    #expect(prefs.storedSyntheticSize == nil)

    proceed.signal()
    await fixture.settle()
    // And the engage really did land, so the refusals above were about a live
    // sequence rather than about one that had already failed.
    #expect(fixture.synthesis.isEngaged(displayID: Self.panelID))
    await fixture.revertAnyPreview()
  }

  /// A departure that reached no sweep is caught by the next engage.
  ///
  /// Every departure sweep keys on the pairing snapshot, and the snapshot is
  /// empty or stale for the whole of an engage, so a panel that leaves inside
  /// that window is skipped by all of them and nothing re-runs them afterwards.
  /// The pairing then survives naming a display that is not attached: it holds
  /// one of two slots, and the reapply pass and the arrangement signature both
  /// read it.
  ///
  /// Driven here by a second engage rather than by a parked one, because that
  /// is the deterministic shape of the same question: the sweep runs when an
  /// engage lands, and what it must find is a departure nothing else saw.
  @Test func anEngageSweepsADepartureNoOtherSweepSaw() async throws {
    let fixture = Fixture(secondPanel: true)
    defer { fixture.forgetPrefs() }
    let first = try fixture.configured(Self.panelID)
    let second = try fixture.configured(Self.secondPanelID)
    let stop = try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)

    _ = await fixture.synthesis.engage(stop, on: first)
    #expect(fixture.synthesis.isEngaged(displayID: Self.panelID))

    // The panel leaves with no notification behind it, which is what a
    // departure landing inside an engage amounts to: no sweep ran, and none
    // will.
    fixture.world.detach(Self.panelID)
    #expect(fixture.synthesis.isEngaged(displayID: Self.panelID), "nothing has swept yet")

    _ = await fixture.synthesis.engage(stop, on: second)

    #expect(fixture.synthesis.isEngaged(displayID: Self.secondPanelID))
    #expect(
      fixture.synthesis.pairing(forPhysical: Self.panelID) == nil,
      "the engage must take down a pairing whose panel has gone"
    )
    #expect(fixture.synthesis.freeSlots == 1, "and give its slot back")
  }

  /// The synthesized-size carve-out in the direction nothing consulted before:
  /// a synthesis engage over a mirror set the USER built is refused, at the
  /// same seam every other refusal is decided.
  @Test func aUserMirrorSetRefusesASynthesizedSize() throws {
    let fixture = Fixture(mirroring: Self.secondPanelID)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)

    #expect(fixture.synthesis.refusalReason(for: display) == .alreadyMirrored)
  }

  /// The MASTER of the user's mirror set, which the test above cannot reach:
  /// CoreGraphics reports the flag on both ends of a set but names a master
  /// only on the slave, so the master carries `isInMirrorSet` with no
  /// `mirrorsDisplay` at all. A predicate written over the master id instead of
  /// the flag reads that display as standalone and lets a synthesis engage
  /// straight into the user's own mirror.
  @Test func aUserMirrorMasterRefusesASynthesizedSize() throws {
    let fixture = Fixture(mirrorMaster: true)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)

    // The state under test, spelled out: no master id, and neither of the two
    // exclusions that make a mirrored display OURS applies.
    #expect(display.isInMirrorSet)
    #expect(display.mirrorsDisplay == kCGNullDirectDisplay)
    #expect(!fixture.synthesis.isEngaged(displayID: Self.panelID))
    #expect(!fixture.synthesis.masterIDs.contains(Self.panelID))

    #expect(fixture.synthesis.refusalReason(for: display) == .alreadyMirrored)
  }

  /// The other half of the same predicate, and the one a raw mirror flag gets
  /// wrong: a display carrying a synthesis set IS mirrored, and refusing it
  /// would be the feature refusing its own work.
  @Test func aSynthesisSetIsNotAUserMirrorSet() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)

    _ = await fixture.synthesis.engage(stop, on: display)
    let engaged = try fixture.configured(Self.panelID)

    // The fixture's own control: the world really does report it mirrored, so
    // the expectation below is the exclusion doing the work.
    #expect(engaged.isInMirrorSet)
    #expect(fixture.synthesis.refusalReason(for: engaged) == nil)
  }

  /// The pref-free teardown refuses a gate it could not claim, as the opt-out
  /// already did. It is the mirror hotkey's unwind, so without this it tore a
  /// set down behind another feature's open reconfiguration and answered true,
  /// leaving its caller to stage a raw mirror change over the result.
  ///
  /// The whole-app reset is the one caller that goes on without the claim, and
  /// only after waiting for it: it is wiping the domain and rebuilding, so a set
  /// left standing there would outlive everything that knows about it. The
  /// window is collapsed to nothing here, which is the never-clears case at test
  /// speed.
  @Test func aRefusedGateStopsTheUnwindAndTheResetProceedsOnlyAfterItsWait() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)

    _ = await fixture.synthesis.engage(stop, on: display)
    #expect(fixture.synthesis.isEngaged(displayID: Self.panelID))

    // Held by another feature across both calls below.
    let held = await fixture.gate.claim(.mirroring)
    #expect(held.isGranted, "the fixture's own control")

    let refused = await fixture.synthesis.disengageAllForReset()
    #expect(!refused)
    #expect(
      fixture.synthesis.isEngaged(displayID: Self.panelID),
      "a refusal must leave the set exactly where it found it"
    )

    let forced = await fixture.synthesis.disengageAllForReset(
      force: true, forcedClaimWait: .zero, forcedClaimRetryDelay: .zero
    )
    #expect(forced)
    #expect(fixture.synthesis.pairings.isEmpty)

    // Still ours: the forced pass never took the claim, so it must not have
    // given one back either.
    #expect(await fixture.gate.holder == .mirroring)
    await fixture.gate.release(.mirroring)
  }

  /// The other half of the same contract: a holder that lets go inside the
  /// window is WAITED for, so the reset's teardown runs under its own claim
  /// rather than alongside somebody else's configuration.
  ///
  /// The flag is what separates a wait from a barge. A barge returns while the
  /// releasing task is still asleep, so it sees the flag unset; only an
  /// implementation that retried until the gate came free can see it set.
  @Test func aResetWaitsOutAGateHolderThatLetsGoInsideTheWindow() async throws {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let stop = try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)

    _ = await fixture.synthesis.engage(stop, on: display)
    #expect(fixture.synthesis.isEngaged(displayID: Self.panelID))

    let held = await fixture.gate.claim(.mirroring)
    #expect(held.isGranted, "the fixture's own control")

    let signal = ReleaseSignal()
    let gate = fixture.gate
    let releaser = Task {
      try? await Task.sleep(for: .milliseconds(150))
      await signal.markReleased()
      await gate.release(.mirroring)
    }

    let forced = await fixture.synthesis.disengageAllForReset(
      force: true, forcedClaimWait: .seconds(5), forcedClaimRetryDelay: .milliseconds(10)
    )
    await releaser.value

    #expect(forced)
    #expect(fixture.synthesis.pairings.isEmpty)
    #expect(
      await signal.released,
      "the forced pass must wait the holder out rather than barge past it"
    )
    // The claim it waited for is now ITS claim. The fixture leaves
    // `releaseClaimIfIdle` unwired, so nothing hands it back here; in the app
    // the reset's rebuild does. A barge would have left the gate free instead,
    // since the releasing task above let go of it.
    #expect(await fixture.gate.holder == .displayModes, "the reset holds the claim it waited for")
    await fixture.gate.release(.displayModes)
  }

  /// Both slots taken, and the attended guard answers what the unattended one
  /// already answered: the reapply pass has skipped on `freeSlots` since it was
  /// written, while the picker offered the stops anyway and let the engine
  /// refuse at the allocation.
  ///
  /// The engaged panel is the half that makes this a slot question rather than a
  /// blanket one: an engage tears its own pairing down before it allocates, so
  /// its slot is free by the time it asks.
  @Test func aThirdDisplayIsRefusedOnceBothSynthesisSlotsAreTaken() async throws {
    let fixture = Fixture(secondPanel: true)
    defer { fixture.forgetPrefs() }
    let first = try fixture.configured(Self.panelID)
    let second = try fixture.configured(Self.secondPanelID)
    let stop = try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)

    _ = await fixture.synthesis.engage(stop, on: first)
    _ = await fixture.synthesis.engage(stop, on: second)
    #expect(fixture.synthesis.freeSlots == 0, "the fixture's own control")

    // Never attached to the world: the guard is asked about the display it is
    // handed, and a third panel on this rig would only be scenery.
    let third = ConfiguredDisplay(
      id: 11,
      identity: DisplayConfigIdentity(vendor: 0x3669, model: 3, serial: 3, isBuiltIn: false),
      name: "MAG341C 3", isBuiltIn: false
    )
    #expect(fixture.synthesis.refusalReason(for: third) == .engine(.noFreeSlot))
    #expect(fixture.synthesis.refusalReason(for: first) == nil)
  }

  /// A hardware sequence that STARTS inside the teardown refuses it, even
  /// though the gate said yes.
  ///
  /// The top-of-function `isWorking` reading is taken before two awaits, the
  /// preview stand-down and the claim, and before the forced path's wait of up
  /// to two seconds. The gate cannot stand in for it: `claim` is re-entrant per
  /// claimant and synthesis claims `.displayModes`, the same claimant the mode
  /// coordinator uses, so a mode preview or apply starting in that window is
  /// GRANTED rather than refused. Only the second reading catches it.
  ///
  /// Driven through the stand-down seam because that is one of the real awaits:
  /// in the app it enters the mode coordinator's serial queue.
  @Test func aSequenceStartingInsideTheTeardownRefusesItEvenWithTheGateGranted() async throws {
    let fixture = Fixture(secondPanel: true)
    defer { fixture.forgetPrefs() }
    let display = try fixture.configured(Self.panelID)
    let second = try fixture.configured(Self.secondPanelID)
    let stop = try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)

    _ = await fixture.synthesis.engage(stop, on: display)
    #expect(fixture.synthesis.isEngaged(displayID: Self.panelID))
    #expect(!fixture.synthesis.isWorking, "the fixture's own control: the teardown starts idle")

    // Parked in `create`, so the interloping engage holds the working depth up
    // for as long as this test wants it. Armed only now: the engage above had to
    // land.
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    fixture.host.onCreate = {
      entered.signal()
      // DEADLINED, unlike the parks above: the release comes after the teardown
      // returns, so a teardown that ran on regardless would block on the engine
      // executor this park is holding. Ten seconds turns that hang into a
      // failing expectation.
      _ = proceed.wait(timeout: .now() + 10)
    }

    let teardownReachedTheSeam = DispatchSemaphore(value: 0)
    let interloper = Task { @MainActor [synthesis = fixture.synthesis] in
      _ = await awaitSignal(teardownReachedTheSeam)
      _ = await synthesis.engage(stop, on: second)
    }
    // Hands the main actor to the interloper and comes back once it is parked in
    // the engine, which is the interleaving under test.
    fixture.synthesis.endOutstandingPreview = {
      teardownReachedTheSeam.signal()
      return await awaitSignal(entered)
    }

    let unwound = await fixture.synthesis.disengageAllForReset()

    #expect(fixture.synthesis.isWorking, "the fixture's own control: a sequence really did start")
    #expect(!unwound, "a sequence that started inside the teardown must refuse it")
    #expect(
      fixture.synthesis.isEngaged(displayID: Self.panelID),
      "and the refusal must leave the set exactly where it found it"
    )
    // The claim is deliberately NOT handed back on this path: the sequence now
    // running shares the `.displayModes` claimant, so a release here would take
    // the gate out from under it.
    #expect(await fixture.gate.holder == .displayModes)

    proceed.signal()
    await interloper.value
    await fixture.settle()
    await fixture.gate.release(.displayModes)
  }

  /// The control for the refusal tests: with nothing selected the gate is free,
  /// so a refusal there is about the operation rather than about a gate that
  /// refuses everything.
  @Test func theGateIsFreeWithNoSelectionOutstanding() async {
    let fixture = Fixture()
    defer { fixture.forgetPrefs() }
    let outcome = await fixture.gate.claim(.mirroring)
    #expect(outcome.isGranted)
    await fixture.gate.release(.mirroring)
    await fixture.revertAnyPreview()
  }

}

/// Waits for a semaphore off the cooperative pool, deadlined: a blocked thread is
/// not a suspended one, so an unbounded wait here would hang the suite past any
/// cancellation. Five seconds is orders of magnitude past what the fakes need.
private func awaitSignal(_ semaphore: DispatchSemaphore) async -> Bool {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
    }
  }
}

/// A one-way flag shared by the releasing task and the assertion that reads it,
/// so "did the reset wait" is something the test observes rather than times.
private actor ReleaseSignal {
  private(set) var released = false
  func markReleased() { released = true }
}
