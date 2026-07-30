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

/// Consecutive submissions carrying the same raw value must produce a single
/// hardware write (the value is already on the wire) while still completing
/// their generations. Duplicate re-sends saturate the DDC/I2C bus during a
/// drag and the monitor defers applying brightness until the bus quiets —
/// the round-2 hardware defect.
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

/// During the post-write quiet gap, values arriving in the interim coalesce in
/// the stream buffer; only the newest is sent once the gap elapses. Uses a
/// deliberately huge injected gap so the assertion is about ordering, not
/// wall-clock timing: after generation 1 completes the drain is inside its
/// gap, and the two subsequent submits are back-to-back synchronous yields
/// (no suspension point between them), so 20 is superseded before the drain
/// can possibly dequeue it.
@Test func coalescerQuietGapSkipsIntermediateValues() async {
  let fake = FakeDDC()
  let coalescer = BrightnessWriteCoalescer(writer: fake, minimumQuietGap: .milliseconds(500))
  coalescer.submit(.init(value: 10, generation: 1))
  await coalescer.waitUntilCompleted(through: 1) // write done; drain now sleeping the gap
  coalescer.submit(.init(value: 20, generation: 2))
  coalescer.submit(.init(value: 30, generation: 3)) // displaces 20 in the buffer
  await coalescer.waitUntilCompleted(through: 3)
  let writes = await fake.recordedWrites()
  #expect(writes.map(\.value) == [10, 30]) // 20 never hit the bus
}

/// A wait issued before its write has drained must suspend until that write
/// (or a newer one superseding it) lands — never resolve early against an
/// idle-looking coalescer.
@Test func coalescerWaitCoversSupersededGenerations() async {
  let fake = FakeDDC()
  let coalescer = BrightnessWriteCoalescer(writer: fake)
  coalescer.submit(.init(value: 10, generation: 1))
  coalescer.submit(.init(value: 90, generation: 2)) // may displace generation 1 in the buffer
  await coalescer.waitUntilCompleted(through: 1) // satisfied even if 1 was dropped
  await coalescer.waitUntilCompleted(through: 2)
  let writes = await fake.recordedWrites()
  #expect(writes.last?.value == 90)
}
