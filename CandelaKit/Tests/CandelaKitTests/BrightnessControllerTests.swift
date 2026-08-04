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
  // Per-call in-memory store: the only key ever written is the app-level
  // combined-disable flag, and no two callers share state.
  let defaults = InMemoryDefaults()
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
  /// Defaults to the historical "every write succeeds"; flip it to model a
  /// panel that stops accepting commands mid-session (the B4 accessors have
  /// nothing to report otherwise). The write is still RECORDED when it fails —
  /// the transaction was attempted, which is exactly the distinction the
  /// failure flag exists to preserve.
  var writesSucceed = true

  init(readResult: (current: UInt16, max: UInt16)? = (current: 50, max: 100)) {
    self.readResult = readResult
  }

  func write(command: UInt8, value: UInt16) async -> Bool {
    writes.append((command, value))
    return writesSucceed
  }

  func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
    readResult
  }

  func recordedWrites() async -> [(command: UInt8, value: UInt16)] { writes }

  func setReadResult(_ result: (current: UInt16, max: UInt16)?) { readResult = result }

  func setWritesSucceed(_ value: Bool) { writesSucceed = value }
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
  // No strict `count < 50` bound: when the drain keeps pace with the submit
  // loop nothing coalesces and 50 writes is legitimate — the old bound
  // asserted a scheduling race (flaked ~2/14 runs, T12 report). Latest-wins
  // correctness is the ordered final value, pinned above; the drop behavior
  // is pinned deterministically by the gated coalescer tests.
  #expect(writes.count <= 50)
}

@MainActor
@Test func refreshFromHardwareAdoptsCurrentAndMax() async {
  let fake = FakeDDC(readResult: (current: 30, max: 120))
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.maxDDCValue == 120)
  // M4: the read mirrors the write through the tuning's effective max, which
  // clamps a read max above 100 to the fork's DDC_MAX_DETECT_LIMIT — so 30
  // maps over [0, 100], not [0, 120] (old pre-tuning expectation: 0.25).
  #expect(abs(controller.brightness - 0.3) < 0.001)
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

// MARK: - DisplayServices availability (B6)

/// The shim degrades silently by design: a missing framework or symbol logs
/// once at resolve time and every call thereafter returns nil/false forever.
/// Correct, and invisible — "native brightness cannot work on this machine at
/// all" was a fact the process learned on first use and could not state.
///
/// This is a real macOS host, so the framework is in the dyld shared cache and
/// the symbol resolves. The assertion is not a tautology: it fails the day a
/// macOS release renames or drops `DisplayServicesSetBrightness`, which is
/// exactly when the native path silently stops working and someone needs the
/// pane to say why.
@Test func displayServicesReportsItsOwnAvailability() {
  #expect(DisplayServices.isAvailable)
}

/// The read half of the degradation contract, on a display ID that is never a
/// real display: nil, not a crash and not a plausible-looking zero. Nothing is
/// written — the private setter is left alone, one-writer discipline.
@Test func displayServicesReadOfANullDisplayIsNil() {
  #expect(DisplayServices.getBrightness(for: 0) == nil)
}
