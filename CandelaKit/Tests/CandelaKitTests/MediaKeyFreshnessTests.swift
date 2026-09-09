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
  @Test(arguments: [false, true])
  func consecutiveKeysReachTheDisplayAfterAnExternalMove(isUp: Bool) async {
    let panel = NativeFreshnessPanel(at: 0.75)
    panel.controller.setBrightness(0.5)
    await panel.controller.waitForPendingWrites()
    #expect(panel.hardware.withLock { $0.value } == 0.5)
    panel.hardware.withLock { $0.value = isUp ? 0.46 : 0.54 }

    let expected: [Float] = isUp ? [0.5, 0.5625, 0.625] : [0.5, 0.4375, 0.375]
    for value in expected {
      panel.controller.syncFromNativeBeforeStep()
      #expect(panel.controller.step(isUp: isUp, isFine: false) == Double(value))
      await panel.controller.waitForPendingWrites()
      #expect(panel.hardware.withLock { $0.value } == value)
    }
  }

  @Test(arguments: [Float(0.5), Float(0.505)])
  func unchangedReadsDoNotCauseRedundantWrites(read: Float) async {
    let panel = NativeFreshnessPanel(at: 0.75)
    panel.controller.setBrightness(0.5)
    await panel.controller.waitForPendingWrites()
    panel.hardware.withLock { $0.value = read }

    panel.controller.syncFromNativeBeforeStep()
    panel.controller.setBrightness(0.5)
    await panel.controller.waitForPendingWrites()

    #expect(panel.hardware.withLock { $0.writes } == [0.5])
  }

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

/// Keeps the real controller, applier and coalescer; only the display I/O is replaced.
@MainActor
struct NativeFreshnessPanel {
  let controller: BrightnessController
  let hardware: OSAllocatedUnfairLock<(value: Float, writes: [Float])>

  init(at value: Float) {
    let hardware = OSAllocatedUnfairLock(initialState: (value: value, writes: [Float]()))
    self.hardware = hardware
    controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: NativeBrightnessApplier(displayID: 7, apply: { value, _ in
          hardware.withLock {
            $0.value = value
            $0.writes.append(value)
          }
          return true
        }),
        hdr: nil, shade: nil, gamma: nil,
        readNative: { _ in hardware.withLock { $0.value } }
      ),
      prefs: DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "native-freshness"),
      displayID: 7,
      role: .builtIn,
      wireSiblings: []
    )
  }
}
