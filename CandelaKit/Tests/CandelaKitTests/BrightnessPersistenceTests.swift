import Foundation
import Testing
@testable import CandelaKit

@MainActor
@Suite("Brightness persistence")
struct BrightnessPersistenceTests {
  /// In-memory store; UserDefaults-backed store gets its own test below.
  final class MemoryStore: BrightnessStoring, @unchecked Sendable {
    // Confinement: tests touch it only from one actor at a time.
    var values: [String: Double] = [:]
    func savedBrightness(for key: String) -> Double? { values[key] }
    func saveBrightness(_ value: Double, for key: String) { values[key] = value }
  }

  @Test func restoresSavedValueAtInit() {
    let store = MemoryStore()
    store.values["brightness.test-display"] = 0.8125
    let c = makeLegacyPathController(writer: FakeDDC(), store: store, storageKey: "brightness.test-display")
    #expect(c.brightness == 0.8125)
  }

  @Test func defaultsToFullWithoutSavedValue() {
    // Task 6 first-run rule (review I13): post-M3, 0.5 means "hardware
    // minimum" on the combined scale, so a fresh display starts at 1.0.
    let c = makeLegacyPathController(writer: FakeDDC(), store: MemoryStore(), storageKey: "brightness.x")
    #expect(c.brightness == 1.0)
  }

  @Test func savesOnSetBrightness() {
    let store = MemoryStore()
    let c = makeLegacyPathController(writer: FakeDDC(), store: store, storageKey: "brightness.x")
    c.setBrightness(0.25)
    #expect(store.values["brightness.x"] == 0.25)
  }

  @Test func savesOnStep() {
    let store = MemoryStore()
    let c = makeLegacyPathController(writer: FakeDDC(), store: store, storageKey: "brightness.x")
    c.setBrightness(0.5)
    c.step(isUp: true, isFine: false)
    #expect(store.values["brightness.x"] == 0.5625)
  }

  @Test func userDefaultsStoreRoundTrips() {
    let defaults = InMemoryDefaults()
    let store = UserDefaultsBrightnessStore(defaults: defaults)
    #expect(store.savedBrightness(for: "brightness.k") == nil)
    store.saveBrightness(0.4375, for: "brightness.k")
    #expect(store.savedBrightness(for: "brightness.k") == 0.4375)
  }

  @Test func persistenceKeyPrefersEDIDUUID() {
    var service = Arm64DDC.IOregService()
    service.edidUUID = "AAAA-BBBB"
    service.productName = "MAG 341C"
    #expect(DisplayDiscovery.persistenceKey(from: service) == "AAAA-BBBB")
  }

  @Test func persistenceKeyFallsBackToIdentityTriple() {
    var service = Arm64DDC.IOregService()
    service.productName = "MAG 341C"
    service.manufacturerID = "MSI"
    service.serialNumber = 1_392_915_824
    #expect(DisplayDiscovery.persistenceKey(from: service) == "MAG341C-MSI-1392915824")
  }
}
