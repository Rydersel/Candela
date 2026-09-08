import CoreGraphics
import os
import Testing
@testable import CandelaKit

/// `adoptNativeForSurface`: the read a surface takes as it opens. Unlike the key
/// route it has no `step()` behind it to write the value down, so it publishes,
/// persists and hands back a delta for the sync fan-out.
@MainActor
@Suite("Surface brightness read")
struct SurfaceBrightnessReadTests {
  /// An external on the native path (HDR live), with a panel something else can
  /// move between calls and a store seeded with the value published at launch.
  private func nativeExternal(
    at value: Float
  ) async -> (Harness, OSAllocatedUnfairLock<Float>) {
    let hardware = OSAllocatedUnfairLock(initialState: value)
    let h = Harness(
      hdrEnabled: true,
      settle: .milliseconds(5),
      seed: [Harness.storageKey: 1.0],
      readNative: { _ in hardware.withLock { $0 } }
    )
    await h.prime()
    await h.controller.setHDRMode(.alwaysOn)
    // The entry assert submits; drained here so the in-flight gate is not what the
    // assertions below are measuring.
    await h.controller.waitForPendingWrites()
    return (h, hardware)
  }

  private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-6 }

  @Test func aSurfaceReadPersistsWhatItPublishes() async {
    let (h, hardware) = await nativeExternal(at: 1.0)
    #expect(h.store.values[Harness.storageKey] == 1.0)
    hardware.withLock { $0 = 0.75 } // moved in Control Center, unobserved

    let delta = h.controller.adoptNativeForSurface()

    #expect(near(h.controller.brightness, 0.75))
    #expect(near(delta, -0.25))
    // The defect this pins: the bare snap published 0.75 and left 1.0 in the store,
    // which is what the next launch restore would have written to the glass.
    #expect(near(h.store.values[Harness.storageKey] ?? -1, 0.75))
  }

  @Test func aSurfaceReadDuringConvergenceIsANoOp() async {
    let (h, hardware) = await nativeExternal(at: 1.0)
    let generation = h.controller.expectedNative().generation
    h.controller.adoptExternal(0.6, generation: generation)
    #expect(h.controller.isConvergingFromExternal())
    let published = h.controller.brightness
    let stored = h.store.values[Harness.storageKey]
    hardware.withLock { $0 = 0.6 }

    #expect(h.controller.adoptNativeForSurface() == 0)

    // The poller owns this move and lands it within a few ticks, fanning each eased
    // step out as it goes; ending it here would leave the other displays short.
    #expect(h.controller.brightness == published)
    #expect(h.store.values[Harness.storageKey] == stored)
    #expect(h.controller.isConvergingFromExternal())
  }

  @Test func nothingIsReadWhileTheEpochIsClosed() async {
    let (h, hardware) = await nativeExternal(at: 1.0)
    h.controller.setEpochProvider({ 1 }, isCurrent: { _ in false })
    hardware.withLock { $0 = 0.75 }

    #expect(h.controller.adoptNativeForSurface() == 0)
    #expect(near(h.controller.brightness, 1.0))

    // The positive control: the same read with the epoch open takes the value, so
    // the assertion above is about the gate and not about a read that never works.
    h.controller.setEpochProvider({ 1 }, isCurrent: { _ in true })
    #expect(h.controller.adoptNativeForSurface() != 0)
    #expect(near(h.controller.brightness, 0.75))
  }
}

/// A native applier that holds every write until released, so a test can keep the
/// coalescer's queue in flight without racing its drain.
private actor GatedNativeApplier: BrightnessApplying {
  nonisolated let accepts = HardwareTargetKind.native
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false

  func apply(_: HardwareTarget) async -> Bool {
    if !released {
      await withCheckedContinuation { waiters.append($0) }
    }
    return true
  }

  func release() {
    released = true
    for waiter in waiters { waiter.resume() }
    waiters.removeAll()
  }
}

/// The freshness read's in-flight gate, on the panel that has key repeat and no DDC
/// wire. Its own suite because the applier has to be gated at construction.
@MainActor
@Suite("Freshness read against a queued write")
struct FreshnessReadInFlightTests {
  @Test func nothingIsReadWhileOurOwnWriteIsStillQueued() async {
    let hardware = OSAllocatedUnfairLock<Float>(initialState: 0.75)
    let applier = GatedNativeApplier()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: applier, hdr: nil, shade: nil, gamma: nil,
        readNative: { _ in hardware.withLock { $0 } }
      ),
      prefs: DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "t"),
      displayID: 7,
      role: .builtIn,
      wireSiblings: []
    )
    #expect(controller.brightness == 0.75)

    controller.setBrightness(0.5)
    // The panel has not moved yet: the write is parked in the applier. A key repeat
    // reading here would snap published state back to 0.75 and re-step from it.
    controller.syncFromNativeBeforeStep()
    #expect(controller.brightness == 0.5)

    // The positive control: once the queue is empty the same read is taken.
    await applier.release()
    await controller.waitForPendingWrites()
    controller.syncFromNativeBeforeStep()
    #expect(controller.brightness == 0.75)
  }
}
