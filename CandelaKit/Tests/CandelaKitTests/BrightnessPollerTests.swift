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
    var syncEnabled = false
    var surfaceVisible = false
    var onBattery = false
    /// Each counts wakeups, which reads cannot (a tick can skip its read). Two
    /// counters so a sleep sliced to re-check only ONE signal still shows up.
    var syncAsks = 0
    var surfaceAsks = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  let displayID: CGDirectDisplayID
  /// A built-in probe is how a rig with nothing to consume the value is modelled:
  /// it is polled like anything else but casts no vote on the cadence.
  let isExternal: Bool

  init(
    expected: Double?, generation: UInt64 = 0, hardware: Double? = 0.5,
    isExternal: Bool = true, displayID: CGDirectDisplayID = 7
  ) {
    self.isExternal = isExternal
    self.displayID = displayID
    state.withLock {
      $0.expectedValue = expected
      $0.generation = generation
      $0.hardware = hardware
    }
  }

  var reads: [ReadRecord] { state.withLock { $0.reads } }
  var adoptions: [Adoption] { state.withLock { $0.adoptions } }
  var syncAsks: Int { state.withLock { $0.syncAsks } }
  var surfaceAsks: Int { state.withLock { $0.surfaceAsks } }

  func setNativeActive(_ value: Bool) { state.withLock { $0.nativeActive = value } }
  func setConverging(_ value: Bool) { state.withLock { $0.converging = value } }
  func setEpochCurrent(_ value: Bool) { state.withLock { $0.epochCurrent = value } }
  func setSyncEnabled(_ value: Bool) { state.withLock { $0.syncEnabled = value } }
  func setSurfaceVisible(_ value: Bool) { state.withLock { $0.surfaceVisible = value } }
  func setOnBattery(_ value: Bool) { state.withLock { $0.onBattery = value } }

  func read(_ id: CGDirectDisplayID) -> Double? {
    state.withLock { state in
      state.reads.append(ReadRecord(displayID: id, at: .now))
      return state.hardware
    }
  }

  var isEpochCurrent: @Sendable () -> Bool {
    { [state] in state.withLock { $0.epochCurrent } }
  }

  var isSyncEnabled: @Sendable () -> Bool {
    { [state] in state.withLock { $0.syncAsks += 1; return $0.syncEnabled } }
  }

  var isSurfaceVisible: @Sendable () -> Bool {
    { [state] in state.withLock { $0.surfaceAsks += 1; return $0.surfaceVisible } }
  }

  var isOnBattery: @Sendable () -> Bool {
    { [state] in state.withLock { $0.onBattery } }
  }

  var target: BrightnessPoller.Target {
    BrightnessPoller.Target(
      displayID: displayID,
      expected: { [state] in state.withLock { ($0.expectedValue, $0.generation) } },
      isNativeActive: { [state] in state.withLock { $0.nativeActive } },
      adopt: { [state] value, generation in
        state.withLock { $0.adoptions.append(Adoption(value: value, generation: generation)) }
      },
      isConverging: { [state] in state.withLock { $0.converging } },
      isExternal: isExternal
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
  slowIdle: Duration = .milliseconds(60),
  batteryIdle: Duration = .milliseconds(90),
  tolerance: Double = 0.008
) -> BrightnessPoller {
  BrightnessPoller(
    targets: [probe.target],
    read: { probe.read($0) },
    isEpochCurrent: probe.isEpochCurrent,
    isSyncEnabled: probe.isSyncEnabled,
    isSurfaceVisible: probe.isSurfaceVisible,
    isOnBattery: probe.isOnBattery,
    fastInterval: fast,
    idleInterval: idle,
    slowIdleInterval: slowIdle,
    batteryIdleInterval: batteryIdle,
    tolerance: tolerance
  )
}

/// Several targets on one job, so a rig can hold an external AND a built-in. The
/// read routes by display id, which is why a probe can carry its own.
private func makePoller(
  _ probes: [Probe],
  fast: Duration = .milliseconds(10),
  idle: Duration = .milliseconds(30),
  slowIdle: Duration = .milliseconds(60),
  batteryIdle: Duration = .milliseconds(90)
) -> BrightnessPoller {
  BrightnessPoller(
    targets: probes.map(\.target),
    read: { id in probes.first { $0.displayID == id }.flatMap { $0.read(id) } },
    isEpochCurrent: probes[0].isEpochCurrent,
    isSyncEnabled: probes[0].isSyncEnabled,
    isSurfaceVisible: probes[0].isSurfaceVisible,
    isOnBattery: probes[0].isOnBattery,
    fastInterval: fast,
    idleInterval: idle,
    slowIdleInterval: slowIdle,
    batteryIdleInterval: batteryIdle
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

// MARK: - Converging bypass

@Test func convergingAdoptsEvenWithinTolerance() async {
  let probe = Probe(expected: 0.5, generation: 9, hardware: 0.5)
  probe.setConverging(true)
  let poller = makePoller(probe)
  let task = Task { await poller.run() }
  _ = await waitUntil { !probe.adoptions.isEmpty }
  task.cancel()
  #expect(probe.adoptions.first == Adoption(value: 0.5, generation: 9))
}

// MARK: - Epoch gate

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
  // The idle interval dwarfs waitUntil's window on purpose: `run()` ticks before it
  // sleeps, so a fast poller produces five reads in ~40 ms while an idle one cannot
  // produce read two inside 3 s. The gate below is the cadence assertion; an elapsed-time
  // bound crossed 1.198 s under runner starvation while still on the fast cadence.
  let poller = makePoller(probe, fast: .milliseconds(10), idle: .seconds(30))
  let task = Task { await poller.run() }
  let got = await waitUntil { probe.reads.count >= 5 }
  task.cancel()
  #expect(got)
}

@Test func echoStaysOnIdleCadence() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.5)
  let poller = makePoller(probe, fast: .milliseconds(5), idle: .milliseconds(200))
  let task = Task { await poller.run() }
  // Await the first read rather than betting 250 ms produces one: a starved scheduler
  // can delay the poller's first timeslice, and "it ran at all" is not the claim.
  let started = await waitUntil { !probe.reads.isEmpty }
  try? await Task.sleep(for: .milliseconds(250))
  task.cancel()
  #expect(started)
  // Idle cadence over this window is 2 reads and fast would be ~50, so only the upper
  // bound can show the wrong cadence, and starvation moves the count the safe way.
  #expect(probe.reads.count <= 4)
}

// MARK: - Idle cadence

@Test func nothingConsumingTheValueLengthensTheInterval() async {
  // Built-in only, echoing: nothing is moving, no surface is up, sync is off and
  // no EXTERNAL is native, which is the whole of the slow condition.
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.5, isExternal: false)
  let poller = makePoller(probe, fast: .milliseconds(5), idle: .milliseconds(5), slowIdle: .milliseconds(200))
  let task = Task { await poller.run() }
  let started = await waitUntil { !probe.reads.isEmpty }
  try? await Task.sleep(for: .milliseconds(250))
  task.cancel()
  #expect(started)
  // The idle interval here is the FAST one, so a poller that ignored the slow
  // cadence would be at ~50 reads. The control below proves this window can carry
  // them.
  #expect(probe.reads.count <= 4)
}

@Test func aSurfaceAppearingShortensTheNextIntervalWithNoRestart() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.5, isExternal: false)
  let poller = makePoller(probe, fast: .milliseconds(5), idle: .milliseconds(5), slowIdle: .milliseconds(200))
  let task = Task { await poller.run() }
  _ = await waitUntil { !probe.reads.isEmpty }
  // Flipped mid-run, on the SAME poll job: the cadence is re-read every tick, so
  // nothing restarts it.
  probe.setSurfaceVisible(true)
  let sped = await waitUntil { probe.reads.count >= 20 }
  task.cancel()
  #expect(sped)
}

@Test func syncOnKeepsTheShortIntervalWithNoExternalNative() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.5, isExternal: false)
  probe.setSyncEnabled(true)
  let poller = makePoller(probe, fast: .milliseconds(5), idle: .milliseconds(5), slowIdle: .seconds(30))
  let task = Task { await poller.run() }
  let sped = await waitUntil { probe.reads.count >= 20 }
  task.cancel()
  #expect(sped)
}

@Test func batteryLengthensTheSlowIntervalFurther() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.5, isExternal: false)
  probe.setOnBattery(true)
  let poller = makePoller(
    probe, fast: .milliseconds(5), idle: .milliseconds(5),
    slowIdle: .milliseconds(20), batteryIdle: .milliseconds(400))
  let task = Task { await poller.run() }
  let started = await waitUntil { !probe.reads.isEmpty }
  try? await Task.sleep(for: .milliseconds(300))
  task.cancel()
  #expect(started)
  // On mains this window is ~15 reads.
  #expect(probe.reads.count <= 2)
}

/// The whole saving, stated as wakeups rather than reads: a tick can skip its read
/// (a non-native target), so only the per-loop cadence read counts the timer.
@Test func aSlowIntervalWakesOncePerIntervalNotOncePerSecond() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.5, isExternal: false)
  let poller = makePoller(
    probe, fast: .milliseconds(5), idle: .milliseconds(20), slowIdle: .milliseconds(300))
  let task = Task { await poller.run() }
  let started = await waitUntil { probe.syncAsks >= 1 }
  try? await Task.sleep(for: .milliseconds(250))
  task.cancel()
  #expect(started)
  // A sleep sliced at the idle interval would show about 12 in whichever signal it
  // re-checked, so both are asserted.
  #expect(probe.syncAsks <= 2)
  #expect(probe.surfaceAsks <= 2)
}

/// The app's route back from a long interval is rebuilding the job, which buys
/// nothing unless a fresh run reads BEFORE it sleeps.
@Test func aFreshJobReadsBeforeItSleeps() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.5, isExternal: false)
  let first = makePoller(
    probe, fast: .milliseconds(5), idle: .milliseconds(50), slowIdle: .seconds(30))
  let firstTask = Task { await first.run() }
  _ = await waitUntil { !probe.reads.isEmpty }
  firstTask.cancel() // asleep for 30 s, exactly the state a surface can open into
  // Awaited, not merely cancelled: a read the old job had already begun would
  // otherwise land after the count below and pass for the new job's first read.
  await firstTask.value
  let before = probe.reads.count
  probe.setSurfaceVisible(true)
  let replacement = makePoller(
    probe, fast: .milliseconds(5), idle: .milliseconds(50), slowIdle: .seconds(30))
  let start = ContinuousClock.now
  let secondTask = Task { await replacement.run() }
  let read = await waitUntil(.seconds(5)) { probe.reads.count > before }
  let elapsed = ContinuousClock.now - start
  secondTask.cancel()
  #expect(read)
  // Milliseconds expected; the bound survives a loaded machine and stays an order
  // of magnitude under the 30 s a job that slept first would wait.
  #expect(elapsed < .seconds(2))
}

/// A display on the DDC path is not a consumer of the poll: it is never read, so
/// it must not hold the short interval either.
@Test func aNonNativeExternalDoesNotHoldTheShortInterval() async {
  let external = Probe(expected: 0.5, generation: 1, hardware: 0.5, displayID: 8)
  external.setNativeActive(false)
  let builtIn = Probe(expected: 0.5, generation: 1, hardware: 0.5, isExternal: false, displayID: 9)
  let poller = makePoller(
    [builtIn, external], fast: .milliseconds(5), idle: .milliseconds(5),
    slowIdle: .milliseconds(200))
  let task = Task { await poller.run() }
  let started = await waitUntil { !builtIn.reads.isEmpty }
  try? await Task.sleep(for: .milliseconds(250))
  task.cancel()
  #expect(started)
  #expect(external.reads.isEmpty)
  #expect(builtIn.reads.count <= 4)
}

/// The control for the test above: the same rig with the external ON the native
/// path must hold the short interval, or the one above passes for the wrong reason.
@Test func aNativeExternalDoesHoldTheShortInterval() async {
  let external = Probe(expected: 0.5, generation: 1, hardware: 0.5, displayID: 8)
  let builtIn = Probe(expected: 0.5, generation: 1, hardware: 0.5, isExternal: false, displayID: 9)
  let poller = makePoller(
    [builtIn, external], fast: .milliseconds(5), idle: .milliseconds(5),
    slowIdle: .seconds(30))
  let task = Task { await poller.run() }
  let sped = await waitUntil { builtIn.reads.count >= 20 }
  task.cancel()
  #expect(sped)
}

/// The poll job must survive every idle state: an external entering HDR reaches
/// the native path through no call of ours, and the running poller is what
/// notices.
@Test func theSlowCadenceStillNoticesADisplayTurningNative() async {
  let probe = Probe(expected: 0.5, generation: 1, hardware: 0.9)
  probe.setNativeActive(false)
  let poller = makePoller(probe, fast: .milliseconds(5), idle: .milliseconds(5), slowIdle: .milliseconds(50))
  let task = Task { await poller.run() }
  try? await Task.sleep(for: .milliseconds(120))
  #expect(probe.reads.isEmpty)
  probe.setNativeActive(true)
  let adopted = await waitUntil { !probe.adoptions.isEmpty }
  task.cancel()
  #expect(adopted)
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
