import Testing
@testable import CandelaKit

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
  let controller = BrightnessController(writer: fake)
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
  let controller = BrightnessController(writer: fake)
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
  let controller = BrightnessController(writer: fake)
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
  let controller = BrightnessController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.maxDDCValue == 120)
  #expect(abs(controller.brightness - 0.25) < 0.001)
}

@MainActor
@Test func refreshFailureKeepsDefaults() async {
  let fake = FakeDDC(readResult: nil)
  let controller = BrightnessController(writer: fake)
  await controller.refreshFromHardware()
  #expect(controller.maxDDCValue == 100)
  #expect(controller.brightness == 0.5)
}

/// Deliberately NOT @MainActor: submission is synchronous and the drain runs
/// on the global executor, so writes must land without this test ever taking
/// a main-actor turn — the property that keeps DDC writes flowing while the
/// main run loop is stuck in event-tracking mode during a slider drag.
@Test func coalescerDrainsWithoutMainActorParticipation() async {
  let fake = FakeDDC()
  let coalescer = BrightnessWriteCoalescer(writer: fake)
  for step in 1 ... 20 {
    coalescer.submit(.init(value: UInt16(step), generation: UInt64(step)))
  }
  await coalescer.waitUntilCompleted(through: 20)
  let writes = await fake.recordedWrites()
  #expect(!writes.isEmpty)
  #expect(writes.last?.value == 20) // latest value always lands last
  #expect(writes.allSatisfy { $0.command == VCP.brightness })
}

/// A target equal to the value already on the wire must produce no hardware
/// write (duplicate-skip, kept from round 2 — duplicate re-sends saturate the
/// DDC/I2C bus) while still completing its generation.
@Test func coalescerSkipsDuplicateValues() async {
  let fake = FakeDDC()
  let coalescer = BrightnessWriteCoalescer(writer: fake)
  coalescer.submit(.init(value: 44, generation: 1))
  await coalescer.waitUntilCompleted(through: 1)
  coalescer.submit(.init(value: 44, generation: 2)) // duplicate: no new write
  await coalescer.waitUntilCompleted(through: 2) // but its generation completes
  coalescer.submit(.init(value: 45, generation: 3))
  await coalescer.waitUntilCompleted(through: 3)
  let writes = await fake.recordedWrites()
  #expect(writes.map(\.value) == [44, 45])
}

/// Fails the first `write` and succeeds on every one after, recording the
/// outcome of each attempt.
actor FlakyDDC: DDCWriting {
  private(set) var attempts: [(value: UInt16, succeeded: Bool)] = []

  func write(command _: UInt8, value: UInt16) async -> Bool {
    let succeeded = !attempts.isEmpty
    attempts.append((value, succeeded))
    return succeeded
  }

  func read(command _: UInt8) async -> (current: UInt16, max: UInt16)? { nil }

  func recordedAttempts() async -> [(value: UInt16, succeeded: Bool)] { attempts }
}

/// A failed write must NOT advance the duplicate-skip watermark: resubmitting
/// the same value has to reach the hardware again, or a single transient DDC
/// failure leaves brightness stuck until the user picks a different value.
@Test func coalescerRetriesSameValueAfterFailedWrite() async {
  let fake = FlakyDDC()
  let coalescer = BrightnessWriteCoalescer(writer: fake)
  coalescer.submit(.init(value: 42, generation: 1)) // write fails
  await coalescer.waitUntilCompleted(through: 1)
  coalescer.submit(.init(value: 42, generation: 2)) // same value: must retry
  await coalescer.waitUntilCompleted(through: 2)
  let attempts = await fake.recordedAttempts()
  #expect(attempts.map(\.value) == [42, 42]) // attempted twice, not duplicate-skipped
  #expect(attempts.map(\.succeeded) == [false, true]) // and the retry landed
}

/// A wait issued for a generation whose target gets superseded must resolve
/// when the newer target lands — never resolve early against an idle-looking
/// coalescer, and never hang because its own target was dropped from the
/// newest-wins slot.
@Test func coalescerWaitCoversSupersededGenerations() async {
  let fake = FakeDDC()
  let coalescer = BrightnessWriteCoalescer(writer: fake)
  coalescer.submit(.init(value: 10, generation: 1))
  coalescer.submit(.init(value: 90, generation: 2)) // may displace generation 1 in the slot
  await coalescer.waitUntilCompleted(through: 1) // satisfied even if 1 was dropped
  await coalescer.waitUntilCompleted(through: 2)
  let writes = await fake.recordedWrites()
  #expect(writes.last?.value == 90)
}
