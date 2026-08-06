import CoreGraphics
import os
import Testing
@testable import CandelaKit

// Cadence assertions use short intervals and generous bounds: they must
// separate "fast" from "idle" without asserting on exact timer accuracy.

private struct ReadRecord: Sendable {
  let displayID: CGDirectDisplayID
  let at: ContinuousClock.Instant
}

private struct Adoption: Sendable, Equatable {
  let value: Double
  let generation: UInt64
}

/// Stands in for one controller plus the DisplayServices read: records every
/// read (timestamped) and adoption, and lets a test flip the gates mid-run.
private final class Probe: Sendable {
  private struct State {
    var reads: [ReadRecord] = []
    var adoptions: [Adoption] = []
    var expectedValue: Double?
    var generation: UInt64 = 0
    var nativeActive = true
    var converging = false
    var epochCurrent = true
    var hardware: Double? = 0.5
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  let displayID: CGDirectDisplayID = 7

  init(expected: Double?, generation: UInt64 = 0, hardware: Double? = 0.5) {
    state.withLock {
      $0.expectedValue = expected
      $0.generation = generation
      $0.hardware = hardware
    }
  }

  var reads: [ReadRecord] { state.withLock { $0.reads } }
  var adoptions: [Adoption] { state.withLock { $0.adoptions } }

  func setNativeActive(_ value: Bool) { state.withLock { $0.nativeActive = value } }
  func setConverging(_ value: Bool) { state.withLock { $0.converging = value } }
  func setEpochCurrent(_ value: Bool) { state.withLock { $0.epochCurrent = value } }

  func read(_ id: CGDirectDisplayID) -> Double? {
    state.withLock { state in
      state.reads.append(ReadRecord(displayID: id, at: .now))
      return state.hardware
    }
  }

  var isEpochCurrent: @Sendable () -> Bool {
    { [state] in state.withLock { $0.epochCurrent } }
  }

  var target: BrightnessPoller.Target {
    BrightnessPoller.Target(
      displayID: displayID,
      expected: { [state] in state.withLock { ($0.expectedValue, $0.generation) } },
      isNativeActive: { [state] in state.withLock { $0.nativeActive } },
      adopt: { [state] value, generation in
        state.withLock { $0.adoptions.append(Adoption(value: value, generation: generation)) }
      },
      isConverging: { [state] in state.withLock { $0.converging } }
    )
  }
}

private func waitUntil(
  _ timeout: Duration = .seconds(3),
  _ condition: @Sendable () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return condition()
}

private func makePoller(
  _ probe: Probe,
  fast: Duration = .milliseconds(10),
  idle: Duration = .milliseconds(30),
  tolerance: Double = 0.008
) -> BrightnessPoller {
  BrightnessPoller(
    targets: [probe.target],
    read: { probe.read($0) },
    isEpochCurrent: probe.isEpochCurrent,
    fastInterval: fast,
    idleInterval: idle,
    tolerance: tolerance
  )
}

// MARK: - Echo discard

@Test func readMatchingExpectedIsDiscardedAsEcho() async {
  let probe = Probe(expected: 0.5, generation: 3, hardware: 0.5)
  let poller = makePoller(probe)
  let task = Task { await poller.run() }
  _ = await waitUntil { probe.reads.count >= 3 }
  task.cancel()
  #expect(probe.reads.count >= 3)
  #expect(probe.adoptions.isEmpty)
}

@Test func readWithinToleranceIsDiscardedAsEcho() async {
  let probe = Probe(expected: 0.5, generation: 3, hardware: 0.5 + 0.007)
  let poller = makePoller(probe)
  let task = Task { await poller.run() }
  _ = await waitUntil { probe.reads.count >= 3 }
  task.cancel()
  #expect(probe.adoptions.isEmpty)
}

// MARK: - Divergence

@Test func divergenceAdoptsReadValueWithCurrentGeneration() async {
  let probe = Probe(expected: 0.5, generation: 42, hardware: 0.8)
  let poller = makePoller(probe)
  let task = Task { await poller.run() }
  _ = await waitUntil { !probe.adoptions.isEmpty }
  task.cancel()
  #expect(probe.adoptions.first == Adoption(value: 0.8, generation: 42))
}

@Test func noExpectedValueAdopts() async {
  let probe = Probe(expected: nil, generation: 1, hardware: 0.42)
  let poller = makePoller(probe)
  let task = Task { await poller.run() }
  _ = await waitUntil { !probe.adoptions.isEmpty }
  task.cancel()
  #expect(probe.adoptions.first == Adoption(value: 0.42, generation: 1))
}

@Test func failedReadNeverAdopts() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: nil)
  let poller = makePoller(probe)
  let task = Task { await poller.run() }
  _ = await waitUntil { probe.reads.count >= 3 }
  task.cancel()
  #expect(probe.adoptions.isEmpty)
}

// MARK: - Converging bypass (review M33)

@Test func convergingAdoptsEvenWithinTolerance() async {
  let probe = Probe(expected: 0.5, generation: 9, hardware: 0.5)
  probe.setConverging(true)
  let poller = makePoller(probe)
  let task = Task { await poller.run() }
  _ = await waitUntil { !probe.adoptions.isEmpty }
  task.cancel()
  #expect(probe.adoptions.first == Adoption(value: 0.5, generation: 9))
}

// MARK: - Epoch gate (review I15)

@Test func staleEpochSkipsTheTickEntirely() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.9)
  probe.setEpochCurrent(false)
  let poller = makePoller(probe)
  let task = Task { await poller.run() }
  try? await Task.sleep(for: .milliseconds(150))
  #expect(probe.reads.isEmpty)
  #expect(probe.adoptions.isEmpty)
  // The loop must still be alive: reads resume once the epoch is current.
  probe.setEpochCurrent(true)
  let resumed = await waitUntil { !probe.reads.isEmpty }
  task.cancel()
  #expect(resumed)
}

// MARK: - Native-active gate

@Test func inactiveTargetIsNeverRead() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.9)
  probe.setNativeActive(false)
  let poller = makePoller(probe)
  let task = Task { await poller.run() }
  try? await Task.sleep(for: .milliseconds(150))
  #expect(probe.reads.isEmpty)
  probe.setNativeActive(true)
  let resumed = await waitUntil { !probe.reads.isEmpty }
  task.cancel()
  #expect(resumed)
}

// MARK: - Cadence

@Test func divergenceSwitchesToFastCadence() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.9)
  let poller = makePoller(probe, fast: .milliseconds(10), idle: .milliseconds(500))
  let task = Task { await poller.run() }
  let got = await waitUntil { probe.reads.count >= 5 }
  task.cancel()
  #expect(got)
  let reads = probe.reads
  guard reads.count >= 5 else { return }
  // Four idle intervals would be 2 s; four fast ones ~40 ms.
  #expect(reads[4].at - reads[0].at < .milliseconds(300))
}

@Test func echoStaysOnIdleCadence() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.5)
  let poller = makePoller(probe, fast: .milliseconds(5), idle: .milliseconds(200))
  let task = Task { await poller.run() }
  try? await Task.sleep(for: .milliseconds(250))
  task.cancel()
  let count = probe.reads.count
  // Idle cadence over 250 ms: 2 reads. Fast cadence would be ~50.
  #expect(count >= 1)
  #expect(count <= 4)
}

// MARK: - Lifecycle

@Test func cancellationEndsRun() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.5)
  let poller = makePoller(probe, fast: .milliseconds(10), idle: .seconds(5))
  let finished = OSAllocatedUnfairLock(initialState: false)
  let task = Task {
    await poller.run()
    finished.withLock { $0 = true }
  }
  _ = await waitUntil { !probe.reads.isEmpty }
  task.cancel()
  let ended = await waitUntil { finished.withLock { $0 } }
  #expect(ended)
}
