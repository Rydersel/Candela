import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// Reconciliation at the level the Kit test cannot reach: not "does the rule
/// classify correctly" but "does a refresh pass rebuild the controllers".
///
/// This case cannot be produced by hand. Every physical unplug fires its own
/// reconfiguration, so a same-port swap always splits into a departure pass and
/// an arrival pass, and the branch under test is never entered. Measured on the
/// rig 2026-08-17: a sleep, cable swap and wake produced "DELL departed" then
/// "MAG arrived", two passes, so the display arrived as an ordinary new one.
/// The scripted topology below is the only way in.
@Suite("Panel swap reconciliation")
@MainActor
struct PanelSwapReconciliationTests {
  // The seam driver lives in `Fakes`: several suites drive the same one, and
  // two copies would be free to disagree on what a scripted topology means.
  private func model(_ discovery: ScriptedDiscovery) -> AppModel {
    TestFixtures.appModel(discovery: discovery)
  }

  /// The positive control, and it has to come first: if a steady topology did
  /// NOT reuse its controllers, every assertion below would pass for the wrong
  /// reason, because "always rebuild" also never inherits anything.
  @Test("an unchanged panel keeps the very same controllers")
  func steadyTopologyReusesControllers() async {
    let discovery = ScriptedDiscovery()
    discovery.topology = [(id: 2, key: "panel-A", name: "Panel A")]
    let model = model(discovery)
    await model.refresh()
    let first = model.displays.first?.controller
    let firstVolume = model.displays.first?.volume
    await model.refresh()
    #expect(first != nil)
    #expect(model.displays.first?.controller === first)
    #expect(model.displays.first?.volume === firstVolume)
  }

  /// The bug: a different panel on a held ID kept the departed panel's
  /// controllers, which persist under its storage key and read its tuning.
  @Test("a different panel on the same ID gets new controllers")
  func swappedPanelGetsNewControllers() async {
    let discovery = ScriptedDiscovery()
    discovery.topology = [(id: 2, key: "panel-A", name: "Panel A")]
    let model = model(discovery)
    await model.refresh()
    let before = model.displays.first?.controller
    let beforeVolume = model.displays.first?.volume

    discovery.topology = [(id: 2, key: "panel-B", name: "Panel B")]
    await model.refresh()

    #expect(model.displays.count == 1)
    #expect(model.displays.first?.display.persistenceKey == "panel-B")
    #expect(model.displays.first?.controller !== before)
    #expect(model.displays.first?.volume !== beforeVolume)
  }

  /// The measured dock-cycle case (MAG 3 to 2, Dell 2 to 3): both panels stay
  /// attached and exchange IDs, so nothing departs and every ID is still held.
  /// Reconciled on the ID alone, BOTH displays would inherit the other's state.
  @Test("two panels exchanging IDs rebuild both, not neither")
  func exchangedIDsRebuildBoth() async {
    let discovery = ScriptedDiscovery()
    discovery.topology = [
      (id: 2, key: "panel-A", name: "Panel A"), (id: 3, key: "panel-B", name: "Panel B"),
    ]
    let model = model(discovery)
    await model.refresh()
    let onTwo = model.displays.first { $0.display.id == 2 }?.controller
    let onThree = model.displays.first { $0.display.id == 3 }?.controller

    discovery.topology = [
      (id: 2, key: "panel-B", name: "Panel B"), (id: 3, key: "panel-A", name: "Panel A"),
    ]
    await model.refresh()

    #expect(model.displays.first { $0.display.id == 2 }?.display.persistenceKey == "panel-B")
    #expect(model.displays.first { $0.display.id == 3 }?.display.persistenceKey == "panel-A")
    #expect(model.displays.first { $0.display.id == 2 }?.controller !== onTwo)
    #expect(model.displays.first { $0.display.id == 3 }?.controller !== onThree)
    // And specifically NOT merely swapped: a controller that moved to the other
    // ID would still be carrying the wrong panel's storage key.
    #expect(model.displays.first { $0.display.id == 2 }?.controller !== onThree)
    #expect(model.displays.first { $0.display.id == 3 }?.controller !== onTwo)
  }

  /// The replacement has to be announced, not silently substituted: the ring is
  /// what records it and the returned IDs are what drop the old panel's HUD.
  /// Its ID is still occupied, so nothing else in the pass can notice.
  @Test("a replaced panel is reported as a departure")
  func replacedPanelIsReportedDeparted() async {
    let discovery = ScriptedDiscovery()
    discovery.topology = [(id: 2, key: "panel-A", name: "Panel A")]
    let model = model(discovery)
    await model.refresh()

    discovery.topology = [(id: 2, key: "panel-B", name: "Panel B")]
    let departed = await model.refresh()

    #expect(departed.contains(2))
    #expect(model.recentDisplayEvents.contains { $0.contains("Panel A departed") })
    #expect(model.recentDisplayEvents.contains { $0.contains("Panel B arrived") })
  }

  @Test("an ordinary unplug still departs")
  func unplugStillDeparts() async {
    let discovery = ScriptedDiscovery()
    discovery.topology = [(id: 2, key: "panel-A", name: "Panel A")]
    let model = model(discovery)
    await model.refresh()

    discovery.topology = []
    let departed = await model.refresh()

    #expect(departed == [2])
    #expect(model.displays.isEmpty)
  }
}
