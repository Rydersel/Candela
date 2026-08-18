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
  private static let nativeWidth = 3440
  private static let nativeHeight = 1440

  private struct Fixture {
    let modes: DisplayModeCoordinator
    let synthesis: SynthesisCoordinator
    let gate: DisplayReconfigurationGate
    let host: FakeSynthesisVirtualDisplayHost
    let persistenceKey: String
  }

  /// One ultrawide, its ladder generated from a native-flagged mode.
  ///
  /// The opt-in is a real pref write because `SynthesisCoordinator` reads
  /// `DisplayPrefs` directly; the key is unique per call and removed at the end
  /// of the test, so nothing survives the process or collides with a sibling.
  private func fixture(optedIn: Bool = true) -> Fixture {
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
        name: "MAG341C", isBuiltIn: false
      ),
      modes: [native, smaller], current: native,
      nativePixels: (width: Self.nativeWidth, height: Self.nativeHeight)
    )

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
    return Fixture(modes: modes, synthesis: synthesis, gate: gate, host: host, persistenceKey: key)
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
  private func settle(_ modes: DisplayModeCoordinator) async {
    for _ in 0 ..< 2000 where modes.isApplying {
      try? await Task.sleep(for: .milliseconds(1))
    }
  }
}
