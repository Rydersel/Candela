import Foundation
import Testing
@testable import CandelaKit

/// Construction helper for the suites that predate Task 6 path selection:
/// combined dimming disabled and no HDR/software backends, so brightness maps
/// onto the full DDC range — the M1/M2 shape these tests were written against.
/// (The combined/native/software paths get their own coverage in
/// PathSelectionTests.swift.)
@MainActor
func makeLegacyPathController(
  writer: any DDCWriting,
  store: (any BrightnessStoring)? = nil,
  storageKey: String? = nil
) -> BrightnessController {
  // One shared suite: the only key ever written is the app-level
  // combined-disable flag, always with the same value, so cross-test reuse
  // (and parallel test execution) is safe.
  let defaults = UserDefaults(suiteName: "com.rydersel.Candela.tests.legacy-path")!
  defaults.set(true, forKey: "disableCombinedBrightness")
  return BrightnessController(
    writer: writer,
    backends: BrightnessBackends(
      applierNative: NativeBrightnessApplier(displayID: 1) { _, _ in false },
      hdr: nil,
      shade: nil,
      gamma: nil
    ),
    prefs: DisplayPrefs(defaults: defaults, persistenceKey: "legacy"),
    displayID: 1,
    store: store,
    storageKey: storageKey
  )
}

/// Records writes; serves a canned read.
actor FakeDDC: DDCWriting {
  private(set) var writes: [(command: UInt8, value: UInt16)] = []
  var readResult: (current: UInt16, max: UInt16)?

  init(readResult: (current: UInt16, max: UInt16)? = (current: 50, max: 100)) {
    self.readResult = readResult
  }

  func write(command: UInt8, value: UInt16) async -> Bool {
    writes.append((command, value))
    return true
  }

  func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
    readResult
  }

  func recordedWrites() async -> [(command: UInt8, value: UInt16)] { writes }
}

@MainActor
@Test func setBrightnessWritesScaledDDCValue() async {
  let fake = FakeDDC()
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware() // learns max = 100
  controller.setBrightness(0.75)
  await controller.waitForPendingWrites()
  let writes = await fake.recordedWrites()
  #expect(writes.last?.command == VCP.brightness)
  #expect(writes.last?.value == 75)
  #expect(controller.brightness == 0.75)
}

@MainActor
@Test func setBrightnessClampsToUnitRange() async {
  let fake = FakeDDC()
  let controller = makeLegacyPathController(writer: fake)
  controller.setBrightness(1.7)
  #expect(controller.brightness == 1.0)
  controller.setBrightness(-0.3)
  #expect(controller.brightness == 0.0)
  await controller.waitForPendingWrites()
  let writes = await fake.recordedWrites()
  #expect(writes.last?.value == 0) // the final target always lands
}

@MainActor
@Test func rapidSetsCoalesceToLatestValue() async {
  let fake = FakeDDC()
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  for step in 1 ... 50 {
    controller.setBrightness(Double(step) / 50)
  }
  await controller.waitForPendingWrites()
  let writes = await fake.recordedWrites()
  #expect(writes.last?.value == 100)
  #expect(writes.count < 50) // latest-wins coalescing must drop intermediates
}

@MainActor
@Test func refreshFromHardwareAdoptsCurrentAndMax() async {
  let fake = FakeDDC(readResult: (current: 30, max: 120))
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.maxDDCValue == 120)
  #expect(abs(controller.brightness - 0.25) < 0.001)
}

@MainActor
@Test func refreshFailureKeepsDefaults() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.maxDDCValue == 100)
  // First-run rule (Task 6, review I13): with no saved value the controller
  // starts at full brightness, and a failed read leaves that untouched.
  #expect(controller.brightness == 1.0)
}

// Coalescer-level contract tests (latest-wins, no-main-actor drain,
// duplicate-skip, retry-after-failed-apply, superseded-generation waits,
// epoch gate) live in HardwareTargetCoalescerTests.swift — the coalescer's
// payload is now an applier-carrying HardwareTarget.
