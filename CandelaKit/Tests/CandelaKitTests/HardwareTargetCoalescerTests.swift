import CoreGraphics
import os
import Testing
@testable import CandelaKit

// MARK: - Fakes

/// Records every target it is asked to apply. Results are scriptable to model
/// hardware failures: scripted results are consumed in order, then every
/// later apply succeeds.
actor RecordingApplier: BrightnessApplying {
  nonisolated let accepts = HardwareTargetKind.ddc

  private(set) var applied: [HardwareTarget] = []
  private var scriptedResults: [Bool]

  init(scriptedResults: [Bool] = []) {
    self.scriptedResults = scriptedResults
  }

  func apply(_ target: HardwareTarget) async -> Bool {
    applied.append(target)
    return scriptedResults.isEmpty ? true : scriptedResults.removeFirst()
  }

  func appliedTargets() async -> [HardwareTarget] { applied }
}

/// Fake epoch checker: a lock-flipped Bool standing in for DisplayManager's
/// "is this reconfiguration epoch still current" answer (Task 4 wires the
/// real one).
final class FakeEpochGate: Sendable {
  private let current = OSAllocatedUnfairLock(initialState: true)

  func setCurrent(_ value: Bool) {
    current.withLock { $0 = value }
  }

  var isCurrent: @Sendable (UInt64) -> Bool {
    let lock = current
    return { _ in lock.withLock { $0 } }
  }
}

// MARK: - Ported M1 coalescer contracts (new applier-carrying payload)

/// Latest-wins: intermediates submitted while an apply is in flight are
/// dropped and the final target always lands.
@Test func coalescerAppliesLatestTargetAndDropsIntermediates() async {
  let applier = RecordingApplier()
  let coalescer = BrightnessWriteCoalescer()
  for step in 1 ... 50 {
    coalescer.submit(
      .init(target: .ddc(raw: UInt16(step)), applier: applier, epoch: 0, generation: UInt64(step))
    )
  }
  await coalescer.waitUntilCompleted(through: 50)
  let applied = await applier.appliedTargets()
  #expect(applied.last == .ddc(raw: 50))
  #expect(applied.count < 50) // latest-wins coalescing must drop intermediates
}

/// Deliberately NOT @MainActor: submission is synchronous and the drain runs
/// on the global executor, so applies must land without this test ever taking
/// a main-actor turn — the property that keeps hardware writes flowing while
/// the main run loop is stuck in event-tracking mode during a slider drag.
@Test func coalescerDrainsWithoutMainActorParticipation() async {
  let applier = RecordingApplier()
  let coalescer = BrightnessWriteCoalescer()
  for step in 1 ... 20 {
    coalescer.submit(
      .init(target: .ddc(raw: UInt16(step)), applier: applier, epoch: 0, generation: UInt64(step))
    )
  }
  await coalescer.waitUntilCompleted(through: 20)
  let applied = await applier.appliedTargets()
  #expect(!applied.isEmpty)
  #expect(applied.last == .ddc(raw: 20)) // latest target always lands last
}

/// A target equal to the one already on the hardware must not reach an
/// applier (duplicate-skip, kept from round 2 — duplicate re-sends saturate
/// the DDC/I2C bus) while still completing its generation. Targets are what
/// hit hardware, so the same target carried by a *different* applier is
/// still a duplicate.
@Test func coalescerSkipsDuplicateTargets() async {
  let applier = RecordingApplier()
  let otherApplier = RecordingApplier()
  let coalescer = BrightnessWriteCoalescer()
  coalescer.submit(.init(target: .ddc(raw: 44), applier: applier, epoch: 0, generation: 1))
  await coalescer.waitUntilCompleted(through: 1)
  // Duplicate target, different applier: still no hardware apply...
  coalescer.submit(.init(target: .ddc(raw: 44), applier: otherApplier, epoch: 0, generation: 2))
  await coalescer.waitUntilCompleted(through: 2) // ...but its generation completes
  coalescer.submit(.init(target: .ddc(raw: 45), applier: applier, epoch: 0, generation: 3))
  await coalescer.waitUntilCompleted(through: 3)
  #expect(await applier.appliedTargets() == [.ddc(raw: 44), .ddc(raw: 45)])
  #expect(await otherApplier.appliedTargets().isEmpty)
}

/// A failed apply must NOT advance the duplicate-skip watermark: resubmitting
/// the same target has to reach the hardware again, or a single transient
/// failure leaves brightness stuck until the user picks a different value.
@Test func coalescerRetriesSameTargetAfterFailedApply() async {
  let applier = RecordingApplier(scriptedResults: [false]) // first apply fails
  let coalescer = BrightnessWriteCoalescer()
  coalescer.submit(.init(target: .ddc(raw: 42), applier: applier, epoch: 0, generation: 1))
  await coalescer.waitUntilCompleted(through: 1)
  coalescer.submit(.init(target: .ddc(raw: 42), applier: applier, epoch: 0, generation: 2))
  await coalescer.waitUntilCompleted(through: 2)
  // Attempted twice, not duplicate-skipped — and the retry landed.
  #expect(await applier.appliedTargets() == [.ddc(raw: 42), .ddc(raw: 42)])
}

/// A wait issued for a generation whose target gets superseded must resolve
/// when the newer target lands — never resolve early against an idle-looking
/// coalescer, and never hang because its own target was dropped from the
/// newest-wins slot.
@Test func coalescerWaitCoversSupersededGenerations() async {
  let applier = RecordingApplier()
  let coalescer = BrightnessWriteCoalescer()
  coalescer.submit(.init(target: .ddc(raw: 10), applier: applier, epoch: 0, generation: 1))
  coalescer.submit(.init(target: .ddc(raw: 90), applier: applier, epoch: 0, generation: 2)) // may displace generation 1 in the slot
  await coalescer.waitUntilCompleted(through: 1) // satisfied even if 1 was dropped
  await coalescer.waitUntilCompleted(through: 2)
  #expect(await applier.appliedTargets().last == .ddc(raw: 90))
}

// MARK: - Epoch gate

/// A stale-epoch target is skipped without touching the applier, but its
/// generation still completes (the M1 deadlock rule: every dequeued target
/// completes, so no waiter is ever left suspended).
@Test func staleEpochTargetSkipsApplierButCompletesGeneration() async {
  let applier = RecordingApplier()
  let gate = FakeEpochGate()
  gate.setCurrent(false)
  let coalescer = BrightnessWriteCoalescer(isEpochCurrent: gate.isCurrent)
  coalescer.submit(.init(target: .ddc(raw: 33), applier: applier, epoch: 1, generation: 1))
  await coalescer.waitUntilCompleted(through: 1) // must return, not hang
  #expect(await applier.appliedTargets().isEmpty)
}

/// An epoch-skip must not advance the duplicate memo: the skipped target
/// never hit hardware, so the next same-value current-epoch write IS applied.
@Test func epochSkipDoesNotAdvanceDuplicateState() async {
  let applier = RecordingApplier()
  let gate = FakeEpochGate()
  let coalescer = BrightnessWriteCoalescer(isEpochCurrent: gate.isCurrent)
  gate.setCurrent(false)
  coalescer.submit(.init(target: .ddc(raw: 60), applier: applier, epoch: 1, generation: 1))
  await coalescer.waitUntilCompleted(through: 1)
  gate.setCurrent(true)
  coalescer.submit(.init(target: .ddc(raw: 60), applier: applier, epoch: 2, generation: 2))
  await coalescer.waitUntilCompleted(through: 2)
  #expect(await applier.appliedTargets() == [.ddc(raw: 60)]) // applied once — by generation 2
}

/// The gate closure is settable post-init (the epoch pair is wired after
/// controller construction): a gate installed via `setEpochGate` governs
/// subsequent drains.
@Test func epochGateIsSettablePostInit() async {
  let applier = RecordingApplier()
  let gate = FakeEpochGate()
  gate.setCurrent(false)
  let coalescer = BrightnessWriteCoalescer() // default gate accepts everything
  coalescer.setEpochGate(gate.isCurrent)
  coalescer.submit(.init(target: .ddc(raw: 12), applier: applier, epoch: 1, generation: 1))
  await coalescer.waitUntilCompleted(through: 1)
  #expect(await applier.appliedTargets().isEmpty) // installed gate rejected it
}

// MARK: - Mixed hardware targets

/// One coalescer serves both hardware paths: each target is applied by the
/// applier it carries.
@Test func mixedTargetsFlowThroughTheirCarriedAppliers() async {
  let ddcApplier = RecordingApplier()
  let nativeApplier = RecordingApplier()
  let coalescer = BrightnessWriteCoalescer()
  coalescer.submit(.init(target: .ddc(raw: 30), applier: ddcApplier, epoch: 0, generation: 1))
  await coalescer.waitUntilCompleted(through: 1) // keep it out of the newest-wins slot
  coalescer.submit(.init(target: .native(0.5), applier: nativeApplier, epoch: 0, generation: 2))
  await coalescer.waitUntilCompleted(through: 2)
  #expect(await ddcApplier.appliedTargets() == [.ddc(raw: 30)])
  #expect(await nativeApplier.appliedTargets() == [.native(0.5)])
}

// MARK: - resetDuplicateState

/// A replugged monitor or an HDR exit returns hardware to a state we didn't
/// write; after `resetDuplicateState()` the next write to the previously
/// applied value must reach hardware again instead of being skipped forever.
@Test func resetDuplicateStateAllowsReapplyOfSameTarget() async {
  let applier = RecordingApplier()
  let coalescer = BrightnessWriteCoalescer()
  coalescer.submit(.init(target: .ddc(raw: 70), applier: applier, epoch: 0, generation: 1))
  await coalescer.waitUntilCompleted(through: 1)
  coalescer.resetDuplicateState()
  coalescer.submit(.init(target: .ddc(raw: 70), applier: applier, epoch: 0, generation: 2))
  await coalescer.waitUntilCompleted(through: 2)
  #expect(await applier.appliedTargets() == [.ddc(raw: 70), .ddc(raw: 70)])
}

/// Applier whose applies block until released, for racing `resetDuplicateState`
/// against an apply that is already in flight.
actor GatedApplier: BrightnessApplying {
  nonisolated let accepts = HardwareTargetKind.ddc

  private(set) var applied: [HardwareTarget] = []
  private var permits = 0
  private var gateWaiters: [CheckedContinuation<Void, Never>] = []
  private var startedCount = 0
  private var startObservers: [CheckedContinuation<Void, Never>] = []

  /// Suspends until at least `count` applies have entered `apply`.
  func waitUntilApplyStarted(count: Int) async {
    while startedCount < count {
      await withCheckedContinuation { startObservers.append($0) }
    }
  }

  /// Grants one permit; an in-flight (or future) apply consumes it to finish.
  func release() {
    permits += 1
    if !gateWaiters.isEmpty {
      permits -= 1
      gateWaiters.removeFirst().resume()
    }
  }

  func apply(_ target: HardwareTarget) async -> Bool {
    applied.append(target)
    startedCount += 1
    for observer in startObservers {
      observer.resume()
    }
    startObservers.removeAll()
    if permits > 0 {
      permits -= 1
    } else {
      await withCheckedContinuation { gateWaiters.append($0) }
    }
    return true
  }

  func appliedTargets() async -> [HardwareTarget] { applied }
}

/// A reset that lands while an apply is in flight must not be lost: if the
/// apply then succeeds, it must NOT resurrect `lastApplied` — the reset was
/// issued because that hardware state is no longer trustworthy (rebind: the
/// in-flight value landed on the OLD panel). The next same-target write must
/// reach hardware again, not be duplicate-skipped (review I1).
@Test func resetDuplicateStateDuringInFlightApplyIsNotLost() async {
  let applier = GatedApplier()
  let coalescer = BrightnessWriteCoalescer()
  coalescer.submit(.init(target: .ddc(raw: 70), applier: applier, epoch: 0, generation: 1))
  await applier.waitUntilApplyStarted(count: 1) // apply is now in flight, blocked
  coalescer.resetDuplicateState() // mid-apply: must win over the apply's success
  await applier.release() // let the in-flight apply finish (returns true)
  await coalescer.waitUntilCompleted(through: 1)
  await applier.release() // pre-grant a permit so the re-apply completes
  coalescer.submit(.init(target: .ddc(raw: 70), applier: applier, epoch: 0, generation: 2))
  await coalescer.waitUntilCompleted(through: 2)
  #expect(await applier.appliedTargets() == [.ddc(raw: 70), .ddc(raw: 70)])
}

// MARK: - Concrete appliers

/// The brightness leg's applier (an unremapped `DDCCommandApplier`) maps `.ddc`
/// onto ONE brightness VCP write and rejects `.native` targets (wiring bug)
/// without touching the writer.
@Test func ddcApplierWritesBrightnessAndRejectsNativeTargets() async {
  let fake = FakeDDC()
  let recorder = MismatchRecorder()
  let applier = DDCCommandApplier(writer: fake, command: VCP.brightness, onMismatch: recorder.report)
  #expect(applier.accepts == .ddc)
  #expect(await applier.apply(.ddc(raw: 55)) == true)
  #expect(await applier.apply(.native(0.5)) == false)
  #expect(recorder.recorded().count == 1)
  let writes = await fake.recordedWrites()
  #expect(writes.count == 1)
  #expect(writes.first?.command == VCP.brightness)
  #expect(writes.first?.value == 55)
}

/// NativeBrightnessApplier invokes the injected closure with its display ID
/// and rejects `.ddc` targets (wiring bug) without invoking the closure.
@Test func nativeApplierInvokesClosureAndRejectsDDCTargets() async {
  let calls = OSAllocatedUnfairLock<[(Float, CGDirectDisplayID)]>(initialState: [])
  let recorder = MismatchRecorder()
  let applier = NativeBrightnessApplier(
    displayID: 7,
    apply: { value, displayID in
      calls.withLock { $0.append((value, displayID)) }
      return true
    },
    onMismatch: recorder.report
  )
  #expect(applier.accepts == .native)
  #expect(await applier.apply(.native(0.25)) == true)
  #expect(await applier.apply(.ddc(raw: 25)) == false)
  #expect(recorder.recorded().count == 1)
  let recorded = calls.withLock { $0 }
  #expect(recorded.count == 1)
  #expect(recorded.first?.0 == 0.25)
  #expect(recorded.first?.1 == 7)
}

// MARK: - Controller plumbing (epoch provider + rebind)

/// The controller stamps the provider's epoch on each submit and hands the
/// checker to the coalescer: under a stale epoch the writer is never touched,
/// but `waitForPendingWrites` still returns.
@MainActor
@Test func controllerStaleEpochWriteSkipsHardwareButWaitReturns() async {
  let fake = FakeDDC()
  let controller = makeLegacyPathController(writer: fake)
  let gate = FakeEpochGate()
  controller.setEpochProvider({ 1 }, isCurrent: gate.isCurrent)
  gate.setCurrent(false)
  controller.setBrightness(0.3)
  await controller.waitForPendingWrites() // must return, not hang
  #expect(await fake.recordedWrites().isEmpty)
}

/// `rebind(writer:panelIdentity:)` swaps the writer for subsequent writes (the
/// applier is built per submit) and resets the duplicate memo, so re-asserting
/// the same value after a replug reaches the new hardware.
///
/// The identity is UNCHANGED here (nil on both sides), deliberately: the memo
/// reset is not conditional on the panel, and this pins that. The memo is a
/// claim that a value is already in the register, reached through a service we
/// no longer hold — which is true of every rebind, panel swap or not.
@MainActor
@Test func rebindSwapsWriterAndResetsDuplicateState() async {
  let first = FakeDDC()
  let second = FakeDDC()
  let controller = makeLegacyPathController(writer: first)
  controller.setBrightness(0.4)
  await controller.waitForPendingWrites()
  #expect(await first.recordedWrites().map(\.value) == [40])

  controller.rebind(writer: second, panelIdentity: nil)
  controller.setBrightness(0.4) // same target: only valid because rebind reset the memo
  await controller.waitForPendingWrites()
  #expect(await first.recordedWrites().map(\.value) == [40]) // old writer untouched
  #expect(await second.recordedWrites().map(\.value) == [40]) // re-applied to the new writer
}

// MARK: - Last write outcome (B4)

/// The `Bool` that `DDCCommandApplier` hands back used to advance the
/// duplicate memo and then evaporate: nothing anywhere retained "the last
/// write to this display failed", so the diagnostics section could not tell a
/// display that is accepting commands from one that has been refusing every
/// one of them since the cable was plugged in. These pin the two facts the
/// coalescer now keeps — and, just as importantly, the cases where it must
/// keep NEITHER.
@Suite("Last DDC write outcome (B4)")
struct LastAppliedTargetTests {
  /// A fresh controller has written nothing, and "nothing written" must not
  /// read as "the last write failed" — the row would then accuse a display
  /// that has never been asked for anything.
  @Test func aControllerThatHasWrittenNothingReportsNoTargetAndNoFailure() async {
    let coalescer = BrightnessWriteCoalescer()
    #expect(coalescer.lastAppliedTarget() == nil)
    #expect(coalescer.lastApplyFailed() == false)
    coalescer.finishSubmissions()
  }

  @Test func aSuccessfulApplyIsRetainedAsTheLastTarget() async {
    let applier = RecordingApplier()
    let coalescer = BrightnessWriteCoalescer()
    coalescer.submit(.init(target: .ddc(raw: 42), applier: applier, epoch: 0, generation: 1))
    await coalescer.waitUntilCompleted(through: 1)
    #expect(coalescer.lastAppliedTarget() == .ddc(raw: 42))
    #expect(coalescer.lastApplyFailed() == false)
    coalescer.finishSubmissions()
  }

  /// A failed apply must NOT advance `lastApplied` — that is the shipped
  /// duplicate-skip rule (a failure that advanced the memo would make the
  /// retry of the same value look like a duplicate and strand the panel at
  /// the old level) — and must still be reportable.
  @Test func aFailedApplyIsRememberedAndDoesNotBecomeTheLastTarget() async {
    let applier = RecordingApplier(scriptedResults: [false])
    let coalescer = BrightnessWriteCoalescer()
    coalescer.submit(.init(target: .ddc(raw: 7), applier: applier, epoch: 0, generation: 1))
    await coalescer.waitUntilCompleted(through: 1)
    #expect(coalescer.lastApplyFailed() == true)
    #expect(coalescer.lastAppliedTarget() == nil)
    coalescer.finishSubmissions()
  }

  /// The failure flag tracks the LATEST attempt, not the worst one: a display
  /// that failed once and has worked ever since is working, and a row that
  /// latched the old failure would send someone hunting a cable that is fine.
  @Test func aLaterSuccessClearsAnEarlierFailure() async {
    let applier = RecordingApplier(scriptedResults: [false])
    let coalescer = BrightnessWriteCoalescer()
    coalescer.submit(.init(target: .ddc(raw: 7), applier: applier, epoch: 0, generation: 1))
    await coalescer.waitUntilCompleted(through: 1)
    coalescer.submit(.init(target: .ddc(raw: 8), applier: applier, epoch: 0, generation: 2))
    await coalescer.waitUntilCompleted(through: 2)
    #expect(coalescer.lastApplyFailed() == false)
    #expect(coalescer.lastAppliedTarget() == .ddc(raw: 8))
    coalescer.finishSubmissions()
  }

  /// A reset means the hardware is in a state we did not write — a replug or
  /// an HDR exit. Carrying the old failure across it would report a fault
  /// against a wire that no longer exists.
  @Test func aDuplicateResetClearsTheFailureAlongWithTheTarget() async {
    let applier = RecordingApplier(scriptedResults: [false])
    let coalescer = BrightnessWriteCoalescer()
    coalescer.submit(.init(target: .ddc(raw: 7), applier: applier, epoch: 0, generation: 1))
    await coalescer.waitUntilCompleted(through: 1)
    coalescer.resetDuplicateState()
    #expect(coalescer.lastApplyFailed() == false)
    #expect(coalescer.lastAppliedTarget() == nil)
    coalescer.finishSubmissions()
  }

  /// Review I1 applied to the failure flag as well as to the target: a reset
  /// that lands while an apply is in flight must win over that apply's
  /// OUTCOME, whichever way the outcome went. The failing write went to the
  /// old panel; recording it after the rebind would make the new one look
  /// broken before it had been asked for anything.
  @Test func aResetDuringAnInFlightFailingApplyStillClearsTheFailure() async {
    let applier = GatedFailingApplier()
    let coalescer = BrightnessWriteCoalescer()
    coalescer.submit(.init(target: .ddc(raw: 7), applier: applier, epoch: 0, generation: 1))
    await applier.waitUntilApplyStarted()
    coalescer.resetDuplicateState() // mid-apply: must win over the apply's failure
    await applier.release()
    await coalescer.waitUntilCompleted(through: 1)
    #expect(coalescer.lastApplyFailed() == false)
    #expect(coalescer.lastAppliedTarget() == nil)
    coalescer.finishSubmissions()
  }
}

/// `GatedApplier`'s sibling for the failure race: same block-until-released
/// shape, but every apply reports failure. Separate rather than a flag on
/// `GatedApplier` so the existing I1 test's expectations stay untouched.
actor GatedFailingApplier: BrightnessApplying {
  nonisolated let accepts = HardwareTargetKind.ddc

  private var started = false
  private var startObservers: [CheckedContinuation<Void, Never>] = []
  private var permits = 0
  private var gateWaiters: [CheckedContinuation<Void, Never>] = []

  func waitUntilApplyStarted() async {
    while !started {
      await withCheckedContinuation { startObservers.append($0) }
    }
  }

  func release() {
    permits += 1
    if !gateWaiters.isEmpty {
      permits -= 1
      gateWaiters.removeFirst().resume()
    }
  }

  func apply(_: HardwareTarget) async -> Bool {
    started = true
    for observer in startObservers {
      observer.resume()
    }
    startObservers.removeAll()
    if permits > 0 {
      permits -= 1
    } else {
      await withCheckedContinuation { gateWaiters.append($0) }
    }
    return false
  }
}

/// The controller's B4 accessors are pass-throughs over the coalescer's
/// existing lock (the `_duplicateResetCount()` precedent), so what they need
/// pinning for is the WIRING: that they read the coalescer this controller
/// actually writes through, and that a real DDC failure — not a synthetic
/// applier — shows up in them.
@MainActor
@Test func controllerReportsTheLastWriteOutcomeItActuallyPerformed() async {
  let fake = FakeDDC()
  let controller = makeLegacyPathController(writer: fake)
  #expect(controller.lastAppliedTarget() == nil)
  #expect(controller.lastApplyFailed() == false)

  controller.setBrightness(0.4)
  await controller.waitForPendingWrites()
  #expect(controller.lastAppliedTarget() == .ddc(raw: 40))
  #expect(controller.lastApplyFailed() == false)

  await fake.setWritesSucceed(false)
  controller.setBrightness(0.6)
  await controller.waitForPendingWrites()
  #expect(controller.lastApplyFailed() == true)
  #expect(controller.lastAppliedTarget() == .ddc(raw: 40)) // the failed write never landed
}

// MARK: - Settling a set of queues

/// A queue whose contents are visible: `pending` is what would still be owed to
/// the panel if the settle loop stopped now.
@MainActor
final class CountingQueue: PendingWireDraining {
  private(set) var mark: UInt64 = 0
  private(set) var pending = 0

  func enqueue() {
    mark += 1
    pending += 1
  }

  func submissionMark() -> UInt64 { mark }

  func drainPendingWrites() async -> Bool {
    pending = 0
    return true
  }
}

/// Stands in for anything that writes on its own timer (the poller's fan-out, a
/// dimming ramp): while IT is being drained, it puts work on a queue that was
/// drained earlier in the same pass.
@MainActor
final class RefillingQueue: PendingWireDraining {
  private let victim: CountingQueue
  private var refillsLeft: Int

  init(victim: CountingQueue, refills: Int) {
    self.victim = victim
    self.refillsLeft = refills
  }

  func submissionMark() -> UInt64 { 0 }

  func drainPendingWrites() async -> Bool {
    if refillsLeft > 0 {
      refillsLeft -= 1
      victim.enqueue()
    }
    return true
  }
}

/// Draining a list one at a time proves only that the LAST one is empty. This
/// is the window: work lands on an already-drained queue while a later one is
/// still being waited on, and a caller that took the first pass as proof would
/// then make the wire unusable over a write nobody can see fail.
@MainActor
@Test func settlingReDrainsAQueueRefilledDuringTheSamePass() async {
  let queue = CountingQueue()
  let refiller = RefillingQueue(victim: queue, refills: 1)
  queue.enqueue()

  let settled = await WireQuiescence.settle([queue, refiller], betweenRounds: .zero)

  #expect(settled)
  #expect(queue.pending == 0, "the refill was drained too, not left behind the report")
}

/// And it gives up rather than claiming a quiet wire: something submitting on
/// every pass never settles, and saying so is what makes the caller stand down.
@MainActor
@Test func settlingReportsFailureWhenTheQueueIsNeverQuiet() async {
  let queue = CountingQueue()
  let refiller = RefillingQueue(victim: queue, refills: .max)

  let settled = await WireQuiescence.settle(
    [queue, refiller], rounds: 3, betweenRounds: .zero
  )

  #expect(!settled)
}
