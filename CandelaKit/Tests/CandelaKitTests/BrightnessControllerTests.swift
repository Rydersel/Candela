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

/// Blocks each write until the test releases it, so the test can submit new
/// targets at deterministic points mid-ramp. The drain performs at most one
/// write at a time, so a single pending-continuation slot suffices.
actor GatedDDC: DDCWriting {
  private(set) var writes: [UInt16] = []
  private var open = false
  private var blockedWrite: CheckedContinuation<Void, Never>?
  private var arrivalWaiter: CheckedContinuation<UInt16, Never>?
  private var unobservedArrival: UInt16?

  func write(command: UInt8, value: UInt16) async -> Bool {
    if !open {
      if let waiter = arrivalWaiter {
        arrivalWaiter = nil
        waiter.resume(returning: value)
      } else {
        unobservedArrival = value
      }
      await withCheckedContinuation { blockedWrite = $0 }
    }
    writes.append(value)
    return true
  }

  func read(command _: UInt8) async -> (current: UInt16, max: UInt16)? { nil }

  /// Suspends until the drain enters a write (which stays blocked), returning
  /// the value it is trying to send.
  func awaitWriteArrival() async -> UInt16 {
    if let value = unobservedArrival {
      unobservedArrival = nil
      return value
    }
    return await withCheckedContinuation { arrivalWaiter = $0 }
  }

  func releaseOne() {
    blockedWrite?.resume()
    blockedWrite = nil
  }

  func openGate() {
    open = true
    blockedWrite?.resume()
    blockedWrite = nil
  }

  func recordedValues() async -> [UInt16] { writes }
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
  let controller = BrightnessController(writer: fake, minimumWriteInterval: .zero)
  controller.setBrightness(1.7)
  #expect(controller.brightness == 1.0)
  controller.setBrightness(-0.3)
  #expect(controller.brightness == 0.0)
  await controller.waitForPendingWrites()
  let writes = await fake.recordedWrites()
  #expect(writes.last?.value == 0) // the final target always lands exactly
}

/// Rapid sets must neither queue stale ramps (latest-wins redirect) nor jump:
/// the writes form a monotonic eased path that ends exactly at the newest
/// target.
@MainActor
@Test func rapidSetsPlayEasedPathToLatestValue() async {
  let fake = FakeDDC()
  let controller = BrightnessController(writer: fake, minimumWriteInterval: .zero)
  await controller.refreshFromHardware()
  for step in 1 ... 50 {
    controller.setBrightness(Double(step) / 50)
  }
  await controller.waitForPendingWrites()
  let values = await fake.recordedWrites().map(\.value)
  #expect(values.last == 100)
  // Targets only ever increased, so the eased path must be strictly
  // increasing after the initial jump — no repeats, no backtracking.
  #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
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
  let coalescer = BrightnessWriteCoalescer(writer: fake, minimumWriteInterval: .zero)
  for step in 1 ... 20 {
    coalescer.submit(.init(value: UInt16(step), generation: UInt64(step)))
  }
  await coalescer.waitUntilCompleted(through: 20)
  let writes = await fake.recordedWrites()
  #expect(!writes.isEmpty)
  #expect(writes.last?.value == 20) // the latest target is always reached last
  #expect(writes.allSatisfy { $0.command == VCP.brightness })
}

/// The first write jumps straight to its target: the ramp origin is unknown
/// on a write-only panel (DDC reads return zeros), so there is nothing
/// truthful to ease from. Easing applies from the second target on.
@Test func firstWriteJumpsDirectlyToTarget() async {
  let fake = FakeDDC()
  let coalescer = BrightnessWriteCoalescer(writer: fake, minimumWriteInterval: .zero)
  coalescer.submit(.init(value: 70, generation: 1))
  await coalescer.waitUntilCompleted(through: 1)
  let writes = await fake.recordedWrites()
  #expect(writes.map(\.value) == [70]) // one write, no synthetic ramp
}

/// A target equal to the value already on the wire must produce no hardware
/// write (duplicate-skip, kept from round 2 — duplicate re-sends saturate the
/// DDC/I2C bus) while still completing its generation.
@Test func coalescerSkipsDuplicateValues() async {
  let fake = FakeDDC()
  let coalescer = BrightnessWriteCoalescer(writer: fake, minimumWriteInterval: .zero)
  coalescer.submit(.init(value: 44, generation: 1))
  await coalescer.waitUntilCompleted(through: 1)
  coalescer.submit(.init(value: 44, generation: 2)) // duplicate: no new write
  await coalescer.waitUntilCompleted(through: 2) // but its generation completes
  coalescer.submit(.init(value: 45, generation: 3))
  await coalescer.waitUntilCompleted(through: 3)
  let writes = await fake.recordedWrites()
  #expect(writes.map(\.value) == [44, 45])
}

/// Eased stepping plays through intermediate values: from a settled origin,
/// a far target is approached with adaptive steps — an eighth of the
/// remaining distance, floored at 1, capped to land exactly — forming a
/// strictly monotonic path that ends at the target. Deterministic: the second
/// target is submitted only after the first has fully landed, and cadence is
/// zero, so no wall-clock timing is involved.
@Test func easedRampPlaysMonotonicAdaptivePathToTarget() async {
  let fake = FakeDDC()
  let coalescer = BrightnessWriteCoalescer(writer: fake, minimumWriteInterval: .zero)
  coalescer.submit(.init(value: 20, generation: 1)) // first write: direct jump
  await coalescer.waitUntilCompleted(through: 1)
  coalescer.submit(.init(value: 100, generation: 2)) // ramp 20 -> 100
  await coalescer.waitUntilCompleted(through: 2)
  let values = await fake.recordedWrites().map(\.value)
  #expect(values.first == 20)
  #expect(values.last == 100)
  #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
  for (previous, next) in zip(values, values.dropFirst()) {
    let remaining = 100 - Int(previous)
    let expectedStep = min(max(1, remaining / 8), remaining)
    #expect(Int(next) - Int(previous) == expectedStep)
  }
}

/// A submission arriving mid-ramp redirects the ramp: the drain re-reads the
/// newest target before every step instead of finishing the stale ramp first.
/// The gated writer makes the interleaving deterministic — the redirect is
/// submitted while a known step value sits blocked "on the wire".
@Test func midRampSubmissionRedirectsTheRamp() async {
  let gate = GatedDDC()
  let coalescer = BrightnessWriteCoalescer(writer: gate, minimumWriteInterval: .zero)
  coalescer.submit(.init(value: 40, generation: 1)) // first write: jump to 40
  #expect(await gate.awaitWriteArrival() == 40)
  await gate.releaseOne()
  coalescer.submit(.init(value: 80, generation: 2)) // ramp 40 -> 80 begins
  // First eased step: max(1, (80-40)/8) = 5 -> 45, now blocked on the wire.
  #expect(await gate.awaitWriteArrival() == 45)
  coalescer.submit(.init(value: 50, generation: 3)) // redirect while 45 is in flight
  await gate.openGate()
  await coalescer.waitUntilCompleted(through: 3)
  // Generation 2's target (80) is never reached: superseded by generation 3.
  await coalescer.waitUntilCompleted(through: 2) // must not hang
  let values = await gate.recordedValues()
  #expect(values == [40, 45, 46, 47, 48, 49, 50]) // redirected, lands exactly on 50
}

/// A wait issued for a generation whose target gets superseded must resolve
/// when the ramp reaches the newer target — never resolve early against an
/// idle-looking coalescer, and never hang because its own target was dropped.
@Test func coalescerWaitCoversSupersededGenerations() async {
  let fake = FakeDDC()
  let coalescer = BrightnessWriteCoalescer(writer: fake, minimumWriteInterval: .zero)
  coalescer.submit(.init(value: 10, generation: 1))
  coalescer.submit(.init(value: 90, generation: 2)) // may displace generation 1 in the slot
  await coalescer.waitUntilCompleted(through: 1) // satisfied even if 1 was dropped
  await coalescer.waitUntilCompleted(through: 2)
  let writes = await fake.recordedWrites()
  #expect(writes.last?.value == 90)
}
