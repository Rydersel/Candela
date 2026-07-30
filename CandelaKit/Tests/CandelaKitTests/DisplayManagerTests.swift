import CoreGraphics
import os
import Testing
@testable import CandelaKit

// Test debounce: 50 ms quiet window (the brief's suggested short window);
// assertions that require the window to have elapsed wait 5× that.
private let testDebounce: Duration = .milliseconds(50)
private let settle: Duration = .milliseconds(250)

/// Background consumer counting topology elements, so tests can assert
/// "exactly one" / "none" without racing an iterator against a timeout.
private final class TopologyCounter: Sendable {
  private let count = OSAllocatedUnfairLock(initialState: 0)
  private let consumer: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)

  init(_ manager: DisplayManager) {
    let count = count
    let task = Task.detached { [stream = manager.topologyChanges] in
      for await _ in stream {
        count.withLock { $0 += 1 }
      }
    }
    consumer.withLock { $0 = task }
  }

  var elements: Int { count.withLock { $0 } }

  func cancel() {
    consumer.withLock { $0 }?.cancel()
  }
}

// MARK: - Epoch basics

@Test func epochStartsAtZeroAndIsCurrent() {
  let manager = DisplayManager(debounce: testDebounce)
  #expect(manager.currentEpoch() == 0)
  #expect(manager.isEpochCurrent(0))
}

/// `isEpochCurrent` / `currentEpoch` are synchronous — this test function is
/// deliberately not async: the calls must compile and answer without await
/// (the property that lets the coalescer drain consult the gate with no
/// actor hop).
@Test func epochChecksAreCallableWithoutAwait() {
  let manager = DisplayManager(debounce: testDebounce)
  let epoch: UInt64 = manager.currentEpoch()
  _ = manager.isEpochCurrent(epoch)
}

// MARK: - Reconfigure burst intake

/// N rapid simulated events bump the epoch N times IMMEDIATELY (review I6:
/// the bump happens inside the callback, not after the debounce), suspend
/// writes for the whole burst, then — after one quiet window — produce
/// exactly ONE topology element and clear the suspension.
@Test func burstBumpsImmediatelySuspendsAndDebouncesToOneElement() async {
  let manager = DisplayManager(debounce: testDebounce)
  let counter = TopologyCounter(manager)
  defer { counter.cancel() }

  for _ in 1 ... 5 {
    manager._simulateReconfigureEvent()
  }
  // Synchronous region — no awaits since the events fired.
  #expect(manager.currentEpoch() == 5) // N events, N immediate bumps
  #expect(manager.isEpochCurrent(5) == false) // suspended during the burst
  #expect(manager.isEpochCurrent(manager.currentEpoch()) == false)

  try? await Task.sleep(for: settle)
  #expect(counter.elements == 1) // the burst debounced to ONE downstream signal
  #expect(manager.currentEpoch() == 5)
  #expect(manager.isEpochCurrent(5)) // suspension cleared at quiet
}

/// A write-epoch captured before a burst stays non-current after the burst
/// settles: bumps are monotonic, stale epochs never become current again.
@Test func epochCapturedBeforeBurstStaysNonCurrentAfterIt() async {
  let manager = DisplayManager(debounce: testDebounce)
  let counter = TopologyCounter(manager)
  defer { counter.cancel() }

  let captured = manager.currentEpoch()
  #expect(manager.isEpochCurrent(captured))
  for _ in 1 ... 3 {
    manager._simulateReconfigureEvent()
  }
  try? await Task.sleep(for: settle)
  #expect(manager.isEpochCurrent(captured) == false) // stale forever
  #expect(manager.isEpochCurrent(manager.currentEpoch())) // but the live epoch is current
}

// MARK: - Sleep / wake

/// `noteSleep` bumps and suspends synchronously and emits NO topology
/// element — sleep is a write gate, not a topology change; the refresh
/// belongs to the post-wake quiet window.
@Test func noteSleepSuspendsAndBumpsSynchronouslyWithoutElement() async {
  let manager = DisplayManager(debounce: testDebounce)
  let counter = TopologyCounter(manager)
  defer { counter.cancel() }

  manager.noteSleep()
  #expect(manager.currentEpoch() == 1) // synchronous bump
  #expect(manager.isEpochCurrent(1) == false) // suspended

  try? await Task.sleep(for: settle)
  #expect(counter.elements == 0) // no element, even after the debounce window
  #expect(manager.isEpochCurrent(1) == false) // still suspended: only a wake clears it
}

/// `noteWake` routes through the debounced path: the suspension holds through
/// the quiet window (the fork's 3 s "sober" analog), then clears with one
/// epoch bump and one topology element.
@Test func noteWakeClearsSuspensionOnlyAfterDebounceAndYieldsOneElement() async {
  let manager = DisplayManager(debounce: testDebounce)
  let counter = TopologyCounter(manager)
  defer { counter.cancel() }

  manager.noteSleep()
  manager.noteWake()
  // Immediately after wake: still suspended, no bump yet.
  #expect(manager.currentEpoch() == 1)
  #expect(manager.isEpochCurrent(manager.currentEpoch()) == false)
  #expect(counter.elements == 0)

  try? await Task.sleep(for: settle)
  #expect(counter.elements == 1) // one element once sober
  #expect(manager.currentEpoch() == 2) // wake fire bumps: pre-sleep epochs stay stale
  #expect(manager.isEpochCurrent(2)) // suspension cleared
  #expect(manager.isEpochCurrent(1) == false)
}

// MARK: - Coalescer integration (review C3d)

/// DDC writer whose writes park until released, pinning the coalescer drain
/// mid-apply so the test controls exactly when the next target is dequeued.
private actor GatedDDC: DDCWriting {
  private(set) var writes: [(command: UInt8, value: UInt16)] = []
  private var gateOpen = false
  private var parked: CheckedContinuation<Void, Never>?

  func write(command: UInt8, value: UInt16) async -> Bool {
    writes.append((command, value))
    if !gateOpen {
      await withCheckedContinuation { parked = $0 }
    }
    return true
  }

  func read(command _: UInt8) async -> (current: UInt16, max: UInt16)? { nil }

  func open() {
    gateOpen = true
    parked?.resume()
    parked = nil
  }

  func recordedWrites() -> [(command: UInt8, value: UInt16)] { writes }
}

/// A `BrightnessController` wired to a REAL DisplayManager epoch pair: a
/// write submitted before `noteSleep()` lands is never applied to hardware
/// once the sleep suspension is up, and `waitForPendingWrites` still returns
/// (the M1 deadlock rule: skipped targets complete their generation).
///
/// Determinism: a first write parks the drain inside the gated writer, so the
/// test write is provably still in the newest-wins slot when `noteSleep()`
/// lands; only then is the drain released to dequeue it.
@MainActor
@Test func writeSubmittedBeforeSleepNeverLandsButWaitReturns() async {
  let writer = GatedDDC()
  let manager = DisplayManager(debounce: testDebounce)
  let controller = makeLegacyPathController(writer: writer)
  controller.setEpochProvider({ manager.currentEpoch() }, isCurrent: { manager.isEpochCurrent($0) })

  controller.setBrightness(0.3) // raw 30 — parks the drain inside the writer
  var attempts = 0
  while await writer.recordedWrites().isEmpty, attempts < 400 {
    try? await Task.sleep(for: .milliseconds(5))
    attempts += 1
  }
  #expect(await writer.recordedWrites().count == 1)

  controller.setBrightness(0.6) // raw 60 — sits in the slot behind the parked drain
  manager.noteSleep() // lands BEFORE the drain can apply it
  await writer.open() // release the drain: it now dequeues the stale write

  await controller.waitForPendingWrites() // must return, not hang
  let landed = await writer.recordedWrites()
  #expect(landed.map(\.value) == [30]) // the post-sleep-stale write never hit hardware
}
