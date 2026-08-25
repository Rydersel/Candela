import CandelaKit
import Testing

/// The pure half of the live environment builder: virtual displays out (CK26),
/// the only-display flag, and the panel class each source resolves to. The live
/// half reads the app's own objects and is covered by the hardware pass.
@Suite("Checkup live environment")
struct CheckupLiveEnvironmentTests {
  @Test func entriesExcludeVirtualDisplaysAndMarkTheOnlyDisplay() {
    let entries = CheckupLiveEnvironment.entries(from: [
      .init(id: 1, identityKey: "a", name: "Built-in", isBuiltIn: true, isVirtual: false, capabilities: nil, hasDDCService: false, pixelWidth: 3024, pixelHeight: 1964),
      .init(id: 2, identityKey: "v", name: "Virtual", isBuiltIn: false, isVirtual: true, capabilities: nil, hasDDCService: false, pixelWidth: 1920, pixelHeight: 1080),
    ])
    #expect(entries.map(\.id) == [1])
    #expect(entries[0].isOnlyDisplay)
    #expect(entries[0].panelClass == .noDDC)
  }

  @Test func twoRealDisplaysAreNeitherTheOnlyOne() {
    let entries = CheckupLiveEnvironment.entries(from: [
      .init(id: 1, identityKey: "a", name: "Built-in", isBuiltIn: true, isVirtual: false, capabilities: nil, hasDDCService: false, pixelWidth: 1, pixelHeight: 1),
      .init(id: 2, identityKey: "d", name: "DELL", isBuiltIn: false, isVirtual: false, capabilities: "(vcp(10 12))", hasDDCService: true, pixelWidth: 1, pixelHeight: 1),
    ])
    #expect(entries.allSatisfy { !$0.isOnlyDisplay })
    #expect(entries[1].panelClass == .readsDDC)
  }
}
