import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Software dimming reports failure instead of faking success (DT17)")
@MainActor
struct SoftwareDimmingReportingTests {
  private static let slaveID: CGDirectDisplayID = 3
  private static let masterID: CGDirectDisplayID = 2

  /// The slave `3` mirrors the master `2`, so anything needing a screen
  /// resolves to `2` and anything needing the panel keeps `3`.
  private func mirroredStore() -> MirrorTopologyStore {
    MirrorTopologyStore(MirrorTopology([
      MirrorFixtures.display(Self.masterID, inSet: true),
      MirrorFixtures.display(Self.slaveID, mirrors: Self.masterID),
    ]))
  }

  private func controller(
    shade: RecordingShade, gamma: RecordingGamma, store: MirrorTopologyStore,
    configure: (DisplayPrefs) -> Void
  ) -> BrightnessController {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "mirror")
    configure(prefs)
    return BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: nil, shade: shade, gamma: gamma
      ),
      prefs: prefs,
      displayID: Self.slaveID,
      mirrorTopology: store
    )
  }

  /// The gamma WRITE keeps the panel's own ID — gamma is per-display and the
  /// slave's panel is what we want dimmed — while the activity enforcer goes to
  /// the display that actually has a compositor.
  @Test func theGammaWriteStaysOnThePanelWhileTheEnforcerMovesToTheMaster() {
    let shade = RecordingShade()
    let gamma = RecordingGamma()
    let controller = controller(shade: shade, gamma: gamma, store: mirroredStore()) { prefs in
      prefs.forceSoftware = true
      prefs.avoidGamma = false
    }
    controller.setBrightness(0.4)
    #expect(gamma.calls.last?.write == Self.slaveID)
    #expect(gamma.calls.last?.enforcer == Self.masterID)
  }

  /// The shade for a mirror set belongs on the master: it is the master's
  /// framebuffer every panel in the set is showing, and a shade keyed to a
  /// display with no desktop is a window nothing ever dims.
  @Test func theShadeIsAppliedToTheDisplayThatOwnsThePixels() {
    let shade = RecordingShade()
    let gamma = RecordingGamma()
    let controller = controller(shade: shade, gamma: gamma, store: mirroredStore()) { prefs in
      prefs.forceSoftware = true
      prefs.avoidGamma = true
    }
    controller.setBrightness(0.4)
    #expect(shade.alphaCalls.last?.id == Self.masterID)
  }

  /// THE DEFECT. A software write that did not land must not be memoised as
  /// applied: today `lastAppliedSw` is set before the backend is even asked, so
  /// the identical value is deduped away forever and the display never dims
  /// again — while the engine reports a brightness it never achieved.
  @Test func aFailedShadeWriteIsRetriedRatherThanMemoisedAsApplied() {
    let shade = RecordingShade()
    let gamma = RecordingGamma()
    shade.succeeds = false
    let controller = controller(shade: shade, gamma: gamma, store: mirroredStore()) { prefs in
      prefs.forceSoftware = true
      prefs.avoidGamma = true
    }
    controller.setBrightness(0.4)
    controller.setBrightness(0.4)
    #expect(shade.alphaCalls.count == 2)

    // And once it starts working, the dedupe comes back: the retry is because
    // the write FAILED, not because dedupe was abandoned.
    shade.succeeds = true
    controller.setBrightness(0.4)
    controller.setBrightness(0.4)
    #expect(shade.alphaCalls.count == 3)
  }

  @Test func aFailedGammaWriteIsRetriedRatherThanMemoisedAsApplied() {
    let shade = RecordingShade()
    let gamma = RecordingGamma()
    gamma.succeeds = false
    let controller = controller(shade: shade, gamma: gamma, store: mirroredStore()) { prefs in
      prefs.forceSoftware = true
      prefs.avoidGamma = false
    }
    controller.setBrightness(0.4)
    controller.setBrightness(0.4)
    #expect(gamma.calls.count == 2)
  }

  /// An engine nobody wired a topology into behaves exactly as it does today:
  /// the identity function, not a crash and not a guess.
  @Test func anUnwiredEngineResolvesEveryDisplayToItself() {
    let shade = RecordingShade()
    let gamma = RecordingGamma()
    let controller = controller(shade: shade, gamma: gamma, store: MirrorTopologyStore()) { prefs in
      prefs.forceSoftware = true
      prefs.avoidGamma = true
    }
    controller.setBrightness(0.4)
    #expect(shade.alphaCalls.last?.id == Self.slaveID)
  }
}
