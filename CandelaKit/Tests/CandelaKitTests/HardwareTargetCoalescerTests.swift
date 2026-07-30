import CoreGraphics
import os
import Testing
@testable import CandelaKit

// MARK: - Fakes

/// Records every target it is asked to apply. Results are scriptable to model
/// hardware failures: scripted results are consumed in order, then every
/// later apply succeeds.
actor RecordingApplier: BrightnessApplying {
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

// MARK: - Concrete appliers

/// DDCBrightnessApplier maps `.ddc` onto the writer's brightness VCP write
/// and rejects `.native` targets (wiring bug) without touching the writer.
@Test func ddcApplierWritesBrightnessAndRejectsNativeTargets() async {
  let fake = FakeDDC()
  let applier = DDCBrightnessApplier(writer: fake)
  #expect(await applier.apply(.ddc(raw: 55)) == true)
  #expect(await applier.apply(.native(0.5)) == false)
  let writes = await fake.recordedWrites()
  #expect(writes.count == 1)
  #expect(writes.first?.command == VCP.brightness)
  #expect(writes.first?.value == 55)
}

/// NativeBrightnessApplier invokes the injected closure with its display ID
/// and rejects `.ddc` targets (wiring bug) without invoking the closure.
@Test func nativeApplierInvokesClosureAndRejectsDDCTargets() async {
  let calls = OSAllocatedUnfairLock<[(Float, CGDirectDisplayID)]>(initialState: [])
  let applier = NativeBrightnessApplier(displayID: 7) { value, displayID in
    calls.withLock { $0.append((value, displayID)) }
    return true
  }
  #expect(await applier.apply(.native(0.25)) == true)
  #expect(await applier.apply(.ddc(raw: 25)) == false)
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
  let controller = BrightnessController(writer: fake)
  let gate = FakeEpochGate()
  controller.setEpochProvider({ 1 }, isCurrent: gate.isCurrent)
  gate.setCurrent(false)
  controller.setBrightness(0.3)
  await controller.waitForPendingWrites() // must return, not hang
  #expect(await fake.recordedWrites().isEmpty)
}

/// `rebind(writer:)` swaps the writer for subsequent writes (the applier is
/// built per submit) and resets the duplicate memo, so re-asserting the same
/// value after a replug reaches the new hardware.
@MainActor
@Test func rebindSwapsWriterAndResetsDuplicateState() async {
  let first = FakeDDC()
  let second = FakeDDC()
  let controller = BrightnessController(writer: first)
  controller.setBrightness(0.4)
  await controller.waitForPendingWrites()
  #expect(await first.recordedWrites().map(\.value) == [40])

  controller.rebind(writer: second)
  controller.setBrightness(0.4) // same target: only valid because rebind reset the memo
  await controller.waitForPendingWrites()
  #expect(await first.recordedWrites().map(\.value) == [40]) // old writer untouched
  #expect(await second.recordedWrites().map(\.value) == [40]) // re-applied to the new writer
}
