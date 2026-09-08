import CoreGraphics
import os
import Testing
@testable import CandelaKit

/// `syncFromNativeBeforeStep`: the read a brightness key takes before it steps, so
/// a value moved in Control Center while the poller was on its long interval does
/// not jump back on the first press.
@MainActor
@Suite("Media-key freshness")
struct MediaKeyFreshnessTests {
  /// A panel whose brightness something else can move between calls.
  private func makePanel(at value: Float) -> (Harness, OSAllocatedUnfairLock<Float>) {
    let hardware = OSAllocatedUnfairLock(initialState: value)
    let harness = Harness(role: .builtIn, readNative: { _ in hardware.withLock { $0 } })
    return (harness, hardware)
  }

  private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-6 }

  @Test func theStepStartsFromTheLiveRead() {
    let (h, hardware) = makePanel(at: 0.5)
    #expect(near(h.controller.brightness, 0.5))
    hardware.withLock { $0 = 0.75 } // moved in Control Center, unobserved
    h.controller.syncFromNativeBeforeStep()
    #expect(near(h.controller.brightness, 0.75))
    // One chiclet up from where the panel actually is.
    #expect(h.controller.step(isUp: true, isFine: false) == 0.8125)
  }

  /// The positive control: without the read, the same press is the jump.
  @Test func withoutTheReadTheFirstPressJumpsBack() {
    let (h, hardware) = makePanel(at: 0.5)
    hardware.withLock { $0 = 0.75 }
    #expect(h.controller.step(isUp: true, isFine: false) == 0.5625)
  }

  @Test func aQueuedAdoptionIsRetired() {
    let (h, hardware) = makePanel(at: 0.5)
    let queued = h.controller.expectedNative().generation
    hardware.withLock { $0 = 0.75 }
    h.controller.syncFromNativeBeforeStep()
    // An adoption the poller queued before the read describes an older look at the
    // same panel, so it must not land on top of the fresh one.
    #expect(h.controller.adoptExternal(0.4, generation: queued) == 0)
    #expect(near(h.controller.brightness, 0.75))
  }

  @Test func quantizationNoiseIsNotAMove() {
    let (h, hardware) = makePanel(at: 0.5)
    hardware.withLock { $0 = 0.505 }
    h.controller.syncFromNativeBeforeStep()
    #expect(near(h.controller.brightness, 0.5))
  }

  /// Off the native path the register is DDC's, and this read must never go
  /// looking for it.
  @Test func nothingIsReadOffTheNativePath() async {
    let h = Harness(hdrEnabled: false, readNative: { _ in 0.9 })
    await h.prime()
    h.controller.setBrightness(0.5)
    h.controller.syncFromNativeBeforeStep()
    #expect(near(h.controller.brightness, 0.5))
  }

  /// A read under a lock dim reads OUR write, not the user's value, and folding it
  /// in would corrupt what the restore returns to.
  @Test func nothingIsReadUnderATemporaryDim() {
    let (h, hardware) = makePanel(at: 0.5)
    h.controller.beginTemporaryDim(factor: 0.3)
    hardware.withLock { $0 = 0.15 }
    h.controller.syncFromNativeBeforeStep()
    #expect(near(h.controller.brightness, 0.5))
  }
}
