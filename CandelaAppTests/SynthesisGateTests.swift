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

  /// Reverts whatever preview stands, so no countdown outlives the test, and
  /// takes the pref keys back out of the process's defaults.
  private func tearDown(_ fixture: Fixture) async {
    if let preview = fixture.modes.preview { _ = await fixture.modes.revert(preview) }
    UserDefaults.standard.removeObject(forKey: "offerSyntheticSizes.\(fixture.persistenceKey)")
    UserDefaults.standard.removeObject(forKey: "storedSyntheticSize.\(fixture.persistenceKey)")
  }

  @Test func anOptedInPanelOffersSynthesizedStops() async {
    let fixture = fixture()
    let stops = fixture.modes.catalogs[Self.panelID]?.syntheticStops ?? []
    #expect(!stops.isEmpty)
    #expect(stops.allSatisfy { $0.logicalWidth <= Self.nativeWidth })
    #expect(fixture.modes.catalogs[Self.panelID]?.rows.contains { $0.mode.isSynthesized } == true)
    await tearDown(fixture)
  }

  /// SS4: opted out, the picker holds no synthesized row at all. The ladder is
  /// still arithmetically generable from this panel, so this is the opt-in
  /// doing the work rather than a panel with nothing to offer.
  @Test func anOptedOutPanelOffersNoSynthesizedRowAtAll() async {
    let fixture = fixture(optedIn: false)
    let catalog = fixture.modes.catalogs[Self.panelID]
    #expect(catalog?.syntheticStops.isEmpty == true)
    #expect(catalog?.rows.contains { $0.mode.isSynthesized } == false)
    #expect(catalog?.rows.isEmpty == false, "the published rows must still be there")
    await tearDown(fixture)
  }

  /// The pin. `create` is the engine's first hardware step and it runs inside
  /// `session.begin`, so a competing claimant refused AT THAT INSTANT is
  /// evidence the claim was taken before the engage and is still held during it.
  @Test func theDisplayModesClaimIsHeldWhileTheEngineIsEngaging() async throws {
    let fixture = fixture()
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
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        entered.wait()
        continuation.resume()
      }
    }

    let refusal = await fixture.gate.claim(.mirroring)
    proceed.signal()
    #expect(refusal.refusedBy == .displayModes)

    await settle(fixture.modes)
    await tearDown(fixture)
  }

  /// The control for the test above: with nothing selected the gate is free, so
  /// the refusal there is about the operation rather than about a gate that
  /// refuses everything.
  @Test func theGateIsFreeWithNoSelectionOutstanding() async {
    let fixture = fixture()
    let outcome = await fixture.gate.claim(.mirroring)
    #expect(outcome.isGranted)
    await fixture.gate.release(.mirroring)
    await tearDown(fixture)
  }

  /// The select is fire-and-forget onto the coordinator's queue; nothing in the
  /// suite may end while it is still reconfiguring a fake world.
  private func settle(_ modes: DisplayModeCoordinator) async {
    for _ in 0 ..< 2000 where modes.isApplying {
      try? await Task.sleep(for: .milliseconds(1))
    }
  }
}
