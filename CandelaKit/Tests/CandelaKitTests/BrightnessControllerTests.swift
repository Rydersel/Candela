import Foundation
import os
import Testing
@testable import CandelaKit

/// Combined dimming disabled and no HDR or software backends, so brightness maps onto
/// the full DDC range. The combined, native and software paths are covered elsewhere.
@MainActor
func makeLegacyPathController(
  writer: any DDCWriting,
  store: (any BrightnessStoring)? = nil,
  storageKey: String? = nil,
  panelIdentity: String? = nil
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
    storageKey: storageKey,
    panelIdentity: panelIdentity,
    wireSiblings: []
  )
}

/// Records writes; serves a canned read.
actor FakeDDC: DDCWriting {
  private(set) var writes: [(command: UInt8, value: UInt16)] = []
  var readResult: (current: UInt16, max: UInt16)?
  /// Defaults to every write succeeding; flip it to model a panel that stops accepting
  /// commands mid-session. A failed write is still recorded, because the transaction was
  /// attempted, and that distinction is the point of the flag.
  var writesSucceed = true
  /// Codes whose writes fail while everything else succeeds. A per-command failure is a
  /// different fact from `writesSucceed = false`: it pins that a remap fan-out neither
  /// short-circuits past a failing code nor swallows the failure.
  var failingCommands: Set<UInt8> = []

  init(
    readResult: (current: UInt16, max: UInt16)? = (current: 50, max: 100),
    failingCommands: Set<UInt8> = []
  ) {
    self.readResult = readResult
    self.failingCommands = failingCommands
  }

  func write(command: UInt8, value: UInt16) async -> Bool {
    writes.append((command, value))
    landed.withLock { $0 += 1 }
    return writesSucceed && !failingCommands.contains(command)
  }

  /// Nonisolated mirror of `writes.count`. The ordering claim is sampled at the instant
  /// the software leg goes out, and that instant is a synchronous main-actor hook
  /// (`preGammaApplyHook`) which cannot await an actor.
  private nonisolated let landed = OSAllocatedUnfairLock(initialState: 0)

  nonisolated func landedWriteCount() -> Int { landed.withLock { $0 } }

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
  // No strict `count < 50` bound: when the drain keeps pace with the submit loop nothing
  // coalesces and 50 writes is legitimate, so the old bound asserted a scheduling race and
  // flaked. Drop behaviour is pinned deterministically by the gated coalescer tests.
  #expect(writes.count <= 50)
}

@MainActor
@Test func refreshFromHardwareAdoptsCurrentAndMax() async {
  let fake = FakeDDC(readResult: (current: 30, max: 120))
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.maxDDCValue == 120)
  // The read mirrors the write through the tuning's effective max, which clamps a read
  // max above 100, so 30 maps over [0, 100] rather than [0, 120].
  #expect(abs(controller.brightness - 0.3) < 0.001)
}

@MainActor
@Test func refreshFailureKeepsDefaults() async {
  let fake = FakeDDC(readResult: nil)
  let controller = makeLegacyPathController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.maxDDCValue == 100)
  // First-run rule: with no saved value the controller starts at full brightness, and
  // a failed read leaves that untouched.
  #expect(controller.brightness == 1.0)
}

// Coalescer-level contract tests (latest-wins, drain, duplicate-skip, retry, epoch
// gate) live in `HardwareTargetCoalescerTests`.

// MARK: - DisplayServices availability

/// The shim degrades silently by design: a missing framework or symbol logs once at
/// resolve time and every call after returns nil or false. This runs on a real macOS
/// host, so the assertion is not a tautology: it fails the day a release renames or
/// drops `DisplayServicesSetBrightness`, which is when the native path stops working.
@Test func displayServicesReportsItsOwnAvailability() {
  #expect(DisplayServices.isAvailable)
}

/// The read half of the degradation contract on a display ID that is never real: nil,
/// not a crash and not a plausible zero. Nothing is written; one-writer discipline.
@Test func displayServicesReadOfANullDisplayIsNil() {
  #expect(DisplayServices.getBrightness(for: 0) == nil)
}
