import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// The AR12 claim across a synthesized-size pick, end to end through the real
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
  private static let panelID: CGDirectDisplayID = 2
  private static let secondPanelID: CGDirectDisplayID = 7
  private static let nativeWidth = 3440
  private static let nativeHeight = 1440

  private struct Fixture {
    let modes: DisplayModeCoordinator
    let synthesis: SynthesisCoordinator
    let gate: DisplayReconfigurationGate
    let host: FakeSynthesisVirtualDisplayHost
    let world: FakeDisplayWorld
    let configurator: FakeSynthesisDisplayConfigurator
    let persistenceKey: String
  }

  /// One ultrawide, its ladder generated from a native-flagged mode.
  ///
  /// The opt-in is a real pref write because `SynthesisCoordinator` reads
  /// `DisplayPrefs` directly; the key is unique per call and removed at the end
  /// of the test, so nothing survives the process or collides with a sibling.
  ///
  /// `secondPanel` attaches an identical ultrawide under a second id, which is
  /// what the departure sweep needs: it takes a SECOND engage to reach the
  /// sweep that catches the first display's departure.
  /// `mirroring` gives the first panel a master, which is CoreGraphics' shape
  /// for a mirror slave (the flag and the master id both). `mirrorMaster` is
  /// the other end of that set: the flag with no master id, which is all a
  /// master ever reports about its own mirroring.
  private func fixture(
    optedIn: Bool = true, secondPanel: Bool = false, mirroring: CGDirectDisplayID? = nil,
    mirrorMaster: Bool = false
  ) -> Fixture {
    let world = FakeDisplayWorld()
    let native = DisplayMode(
      ioModeID: 1, logicalWidth: Self.nativeWidth, logicalHeight: Self.nativeHeight,
      pixelWidth: Self.nativeWidth, pixelHeight: Self.nativeHeight, refreshHz: 175, isNative: true
    )
    let smaller = DisplayMode(
      ioModeID: 2, logicalWidth: 2560, logicalHeight: 1080,
      pixelWidth: 2560, pixelHeight: 1080, refreshHz: 175, isNative: false
    )
    world.attach(
      ConfiguredDisplay(
        id: Self.panelID,
        identity: DisplayConfigIdentity(vendor: 0x3669, model: 1, serial: 1, isBuiltIn: false),
        name: "MAG341C", isBuiltIn: false,
        mirrorsDisplay: mirroring ?? kCGNullDirectDisplay,
        isInMirrorSet: mirroring != nil || mirrorMaster
      ),
      modes: [native, smaller], current: native,
      nativePixels: (width: Self.nativeWidth, height: Self.nativeHeight)
    )
    if secondPanel {
      world.attach(
        ConfiguredDisplay(
          id: Self.secondPanelID,
          identity: DisplayConfigIdentity(vendor: 0x3669, model: 2, serial: 2, isBuiltIn: false),
          name: "MAG341C 2", isBuiltIn: false
        ),
        modes: [native, smaller], current: native,
        nativePixels: (width: Self.nativeWidth, height: Self.nativeHeight)
      )
    }

    let gate = DisplayReconfigurationGate()
    let configurator = FakeSynthesisDisplayConfigurator(world)
    let host = FakeSynthesisVirtualDisplayHost(world)
    let synthesis = SynthesisCoordinator(
      virtualDisplays: host, configurator: configurator, gate: gate,
      topologyStore: MirrorTopologyStore()
    )
    let key = "app-tests-synthesis-\(UUID().uuidString)"
    synthesis.persistenceKey = { _ in key }
    DisplayPrefs(persistenceKey: key).setOfferSyntheticSizes(optedIn)

    let modes = DisplayModeCoordinator(gate: gate, configurator: configurator)
    modes.synthesis = synthesis
    modes.refreshCatalog(for: Self.panelID)
    if secondPanel { modes.refreshCatalog(for: Self.secondPanelID) }
    return Fixture(
      modes: modes, synthesis: synthesis, gate: gate, host: host,
      world: world, configurator: configurator, persistenceKey: key
    )
  }

  /// The display as the world reports it right now, which is what every guard
  /// under test is handed.
  private func configured(
    _ fixture: Fixture, _ displayID: CGDirectDisplayID
  ) throws -> ConfiguredDisplay {
    try #require(fixture.configurator.displays().first { $0.id == displayID })
  }

  /// Takes the fixture's pref keys back out of the process's defaults.
  ///
  /// Synchronous and separate from the revert below so every test can `defer`
  /// it at the top: a throwing `#require` skips the rest of the body, and a
  /// cleanup that only runs on the happy path leaks a key on exactly the runs
  /// that failed.
  private func forgetPrefs(_ persistenceKey: String) {
    UserDefaults.standard.removeObject(forKey: "offerSyntheticSizes.\(persistenceKey)")
    UserDefaults.standard.removeObject(forKey: "storedSyntheticSize.\(persistenceKey)")
  }

  /// Reverts whatever preview stands, so no countdown outlives the test. Stays
  /// at the end of the body rather than in a `defer`: it is async, and a
  /// `defer` cannot await.
  private func revertAnyPreview(_ fixture: Fixture) async {
    if let preview = fixture.modes.preview { _ = await fixture.modes.revert(preview) }
  }

  @Test func anOptedInPanelOffersSynthesizedStops() async {
    let fixture = fixture()
    defer { forgetPrefs(fixture.persistenceKey) }
    let stops = fixture.modes.catalogs[Self.panelID]?.syntheticStops ?? []
    #expect(!stops.isEmpty)
    #expect(stops.allSatisfy { $0.logicalWidth <= Self.nativeWidth })
    #expect(fixture.modes.catalogs[Self.panelID]?.rows.contains { $0.mode.isSynthesized } == true)
    await revertAnyPreview(fixture)
  }

  /// SS4: opted out, the picker holds no synthesized row at all. The ladder is
  /// still arithmetically generable from this panel, so this is the opt-in
  /// doing the work rather than a panel with nothing to offer.
  @Test func anOptedOutPanelOffersNoSynthesizedRowAtAll() async {
    let fixture = fixture(optedIn: false)
    defer { forgetPrefs(fixture.persistenceKey) }
    let catalog = fixture.modes.catalogs[Self.panelID]
    #expect(catalog?.syntheticStops.isEmpty == true)
    #expect(catalog?.rows.contains { $0.mode.isSynthesized } == false)
    #expect(catalog?.rows.isEmpty == false, "the published rows must still be there")
    await revertAnyPreview(fixture)
  }

  /// The pin. `create` is the engine's first hardware step and it runs inside
  /// `session.begin`, so a competing claimant refused AT THAT INSTANT is
  /// evidence the claim was taken before the engage and is still held during it.
  @Test func theDisplayModesClaimIsHeldWhileTheEngineIsEngaging() async throws {
    let fixture = fixture()
    defer { forgetPrefs(fixture.persistenceKey) }
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

    await settle(fixture.modes)
    await revertAnyPreview(fixture)
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
    let fixture = fixture()
    defer { forgetPrefs(fixture.persistenceKey) }
    let display = try configured(fixture, Self.panelID)
    let stop = try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)
    let prefs = DisplayPrefs(persistenceKey: fixture.persistenceKey)

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
    // The half that matters most: SS11's ordering is only honoured if a refused
    // teardown leaves both keys exactly as it found them.
    #expect(prefs.offerSyntheticSizes)
    #expect(prefs.storedSyntheticSize == nil)

    proceed.signal()
    await settle(fixture.modes)
    // And the engage really did land, so the refusals above were about a live
    // sequence rather than about one that had already failed.
    #expect(fixture.synthesis.isEngaged(displayID: Self.panelID))
    await revertAnyPreview(fixture)
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
    let fixture = fixture(secondPanel: true)
    defer { forgetPrefs(fixture.persistenceKey) }
    let first = try configured(fixture, Self.panelID)
    let second = try configured(fixture, Self.secondPanelID)
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

  /// SS7 in the direction nothing consulted before: a synthesis engage over a
  /// mirror set the USER built is refused, at the same seam every other refusal
  /// is decided.
  @Test func aUserMirrorSetRefusesASynthesizedSize() throws {
    let fixture = fixture(mirroring: Self.secondPanelID)
    defer { forgetPrefs(fixture.persistenceKey) }
    let display = try configured(fixture, Self.panelID)

    #expect(fixture.synthesis.refusalReason(for: display) == .alreadyMirrored)
  }

  /// The MASTER of the user's mirror set, which the test above cannot reach:
  /// CoreGraphics reports the flag on both ends of a set but names a master
  /// only on the slave, so the master carries `isInMirrorSet` with no
  /// `mirrorsDisplay` at all. A predicate written over the master id instead of
  /// the flag reads that display as standalone and lets a synthesis engage
  /// straight into the user's own mirror.
  @Test func aUserMirrorMasterRefusesASynthesizedSize() throws {
    let fixture = fixture(mirrorMaster: true)
    defer { forgetPrefs(fixture.persistenceKey) }
    let display = try configured(fixture, Self.panelID)

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
    let fixture = fixture()
    defer { forgetPrefs(fixture.persistenceKey) }
    let display = try configured(fixture, Self.panelID)
    let stop = try #require(fixture.modes.catalogs[Self.panelID]?.syntheticStops.first)

    _ = await fixture.synthesis.engage(stop, on: display)
    let engaged = try configured(fixture, Self.panelID)

    // The fixture's own control: the world really does report it mirrored, so
    // the expectation below is the exclusion doing the work.
    #expect(engaged.isInMirrorSet)
    #expect(fixture.synthesis.refusalReason(for: engaged) == nil)
  }

  /// The control for the test above: with nothing selected the gate is free, so
  /// the refusal there is about the operation rather than about a gate that
  /// refuses everything.
  @Test func theGateIsFreeWithNoSelectionOutstanding() async {
    let fixture = fixture()
    defer { forgetPrefs(fixture.persistenceKey) }
    let outcome = await fixture.gate.claim(.mirroring)
    #expect(outcome.isGranted)
    await fixture.gate.release(.mirroring)
    await revertAnyPreview(fixture)
  }

  /// The select is fire-and-forget onto the coordinator's queue; nothing in the
  /// suite may end while it is still reconfiguring a fake world.
  ///
  /// **It GIVES UP after about two seconds and says nothing**, deliberately, and
  /// the silence is the trade. A hang here cannot be cancelled cleanly and would
  /// take the whole suite with it, while every assertion this returns to is
  /// about a state the operation was supposed to have reached: an operation
  /// still running at the deadline fails those assertions on the next line, with
  /// a message about the state rather than about the wait. The bound is three
  /// orders of magnitude past what the fakes need, so it can only be hit by a
  /// real regression, and that regression is reported by the expectation that
  /// follows rather than swallowed.
  private func settle(_ modes: DisplayModeCoordinator) async {
    for _ in 0 ..< 2000 where modes.isApplying {
      try? await Task.sleep(for: .milliseconds(1))
    }
  }
}
