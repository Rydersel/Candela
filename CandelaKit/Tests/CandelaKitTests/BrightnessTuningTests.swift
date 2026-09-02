import Foundation
import Testing
@testable import CandelaKit

@MainActor
private final class TuningHarness {
  let defaults: UserDefaults
  let fake = FakeDDC(readResult: nil)
  let prefs: DisplayPrefs
  let controller: BrightnessController

  init(configure: (DisplayPrefs) -> Void = { _ in }) {
    defaults = InMemoryDefaults()
    // Full-range DDC leg, so raw values are directly legible.
    defaults.set(true, forKey: "disableCombinedBrightness")
    prefs = DisplayPrefs(defaults: defaults, persistenceKey: "bt")
    configure(prefs)
    controller = BrightnessController(
      writer: fake,
      backends: BrightnessBackends(
        applierNative: NativeBrightnessApplier(displayID: 9) { _, _ in false },
        hdr: nil, shade: nil, gamma: nil
      ),
      prefs: prefs,
      displayID: 9,
      wireSiblings: []
    )
  }

  func drainedWrites() async -> [(command: UInt8, value: UInt16)] {
    await controller.waitForPendingWrites()
    return await fake.recordedWrites()
  }
}

@MainActor
@Suite("Brightness DDC tuning (M4)")
struct BrightnessTuningTests {
  @Test func defaultTuningPreservesM3Behavior() async {
    let h = TuningHarness()
    h.controller.setBrightness(0.75)
    let writes = await h.drainedWrites()
    #expect(writes.last?.command == VCP.brightness)
    #expect(writes.last?.value == 75)
  }

  @Test func curveAndOverridesShapeTheBrightnessLeg() async {
    let h = TuningHarness { prefs in
      var tuning = prefs.tuning(for: .brightness)
      tuning.minDDCOverride = 20
      tuning.maxDDCOverride = 80
      tuning.curveIndex = 7 // 1.5
      prefs.setTuning(tuning, for: .brightness)
    }
    h.controller.setBrightness(0.5)
    // pow(0.5, 1.5) ≈ 0.35355 → (80-20)*0.35355+20 ≈ 41.2 → truncates to 41
    #expect(await h.drainedWrites().last?.value == 41)
  }

  @Test func invertFlipsTheBrightnessLeg() async {
    let h = TuningHarness { prefs in
      var tuning = prefs.tuning(for: .brightness)
      tuning.invert = true
      prefs.setTuning(tuning, for: .brightness)
    }
    h.controller.setBrightness(0.75)
    #expect(await h.drainedWrites().last?.value == 25)
  }

  @Test func remapReplacesTheBrightnessCodeAndFansOut() async {
    let h = TuningHarness { prefs in
      var tuning = prefs.tuning(for: .brightness)
      tuning.remapCodes = [0x2F]
      prefs.setTuning(tuning, for: .brightness)
    }
    h.controller.setBrightness(1.0)
    let writes = await h.drainedWrites()
    #expect(writes.last?.command == 0x2F)
    #expect(!writes.contains { $0.command == VCP.brightness })
  }

  @Test func disabledBrightnessCommandSkipsTheDDCLegAndRead() async {
    let h = TuningHarness { prefs in
      var tuning = prefs.tuning(for: .brightness)
      tuning.unavailableDDC = true
      prefs.setTuning(tuning, for: .brightness)
    }
    await h.fake.setReadResult((current: 50, max: 100))
    await h.controller.refreshFromHardware()
    h.controller.setBrightness(0.5)
    #expect(await h.drainedWrites().isEmpty)
    #expect(h.controller.brightness == 0.5) // published state still moves
  }

  @Test func readSideUnappliesTheTuningLikeTheWriteSide() async {
    // The fork reads through `convDDCToValue` with the tuning applied: a linear adoption
    // on an inverted or curved panel would corrupt brightness at every launch.
    let h = TuningHarness { prefs in
      var tuning = prefs.tuning(for: .brightness)
      tuning.invert = true
      prefs.setTuning(tuning, for: .brightness)
    }
    await h.fake.setReadResult((current: 25, max: 100))
    await h.controller.refreshFromHardware()
    #expect(h.controller.brightness == 0.75) // inverted, not the linear 0.25
  }

  @Test func stepFineIsNowFlatPointZeroOne() {
    // The shared 16-chiclet step, with fine a flat ±0.01 rather than a 1/64 snap.
    let h = TuningHarness()
    #expect(h.controller.step(isUp: true, isFine: true) == 1.0) // rail from default 1.0
    h.controller.setBrightness(0.5)
    #expect(abs(h.controller.step(isUp: true, isFine: true) - 0.51) < 1e-9)
  }

  @Test func stepCoarseIsUnchanged() {
    let h = TuningHarness()
    h.controller.setBrightness(0.5)
    #expect(h.controller.step(isUp: true, isFine: false) == 0.5625)
    #expect(h.controller.step(isUp: false, isFine: false) == 0.5)
  }
}
