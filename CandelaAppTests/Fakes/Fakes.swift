import AppKit
import CandelaKit
import CoreGraphics
import Foundation

// Shared fakes for the app suite (AT3): tests never construct a hardware
// service. Everything here answers without touching a wire, a panel, or
// CoreAudio. Owned by the scaffold task; sibling test files add their own
// file-local helpers rather than editing this one, so parallel work stays
// on disjoint files.

final class FakeDDCWriter: DDCWriting, @unchecked Sendable {
  // Lock-free single-threaded test use; @unchecked because the test suite
  // confines each instance to one test's structured tasks.
  var capabilities: String?
  var readAnswer: (current: UInt16, max: UInt16)?
  private(set) var writes: [(command: UInt8, value: UInt16)] = []

  init(capabilities: String? = nil) {
    self.capabilities = capabilities
  }

  func write(command: UInt8, value: UInt16) async -> Bool {
    writes.append((command, value))
    return true
  }

  func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
    readAnswer
  }

  func readCapabilityString() async -> String? { capabilities }
}

struct FakeBrightnessApplier: BrightnessApplying {
  let accepts = HardwareTargetKind.native
  func apply(_ target: HardwareTarget) async -> Bool { true }
}

actor FakeHDR: HDRToggling {
  var supports = false
  var enabled = false

  func supportsHDR(displayID: CGDirectDisplayID) async -> Bool { supports }
  func isHDREnabled(displayID: CGDirectDisplayID) async -> Bool { enabled }
  func measuredHDREnabled(displayID: CGDirectDisplayID) async -> Bool { enabled }
  @discardableResult
  func setHDR(displayID: CGDirectDisplayID, enabled: Bool) async -> Bool {
    self.enabled = enabled
    return true
  }
  func displaysReconfigured() async {}
}

@MainActor final class FakeShade: ShadeRendering {
  @discardableResult
  func setShadeAlpha(_ alpha: Double, on displayID: CGDirectDisplayID) -> Bool { true }
  func removeShade(for displayID: CGDirectDisplayID) {}
  func removeAllShades() {}
  func repinFrames() {}
}

@MainActor final class FakeGamma: GammaApplying {
  func applyGammaScale(
    _ scale: Double, on displayID: CGDirectDisplayID,
    enforcerOn drawableDisplayID: CGDirectDisplayID
  ) -> Bool { true }
  func verifyTableIntact(on displayID: CGDirectDisplayID) -> Bool { true }
  func recaptureDefaultTable(on displayID: CGDirectDisplayID) {}
  func resetAllGamma() {}
  func offerShadeFallback(displayName: String, onAccept: @escaping @MainActor () -> Void) {}
}

final class FakeAudio: AudioDeviceProviding, @unchecked Sendable {
  var device: AudioOutputDevice?

  init(device: AudioOutputDevice? = nil) {
    self.device = device
  }

  func defaultOutputDevice() -> AudioOutputDevice? { device }
  func outputDeviceNames() -> [String] { device.map { [$0.name] } ?? [] }
  func setOnDefaultOutputChange(_ handler: (@Sendable () -> Void)?) {}
}

enum TestFixtures {
  /// A prefs domain that cannot collide with the app's or another test's:
  /// unique suite per call, torn down by never being persisted anywhere the
  /// app reads.
  static func prefs(persistenceKey: String, safeMode: Bool = false) -> DisplayPrefs {
    let suite = UserDefaults(suiteName: "app-tests-\(UUID().uuidString)")!
    return DisplayPrefs(defaults: suite, persistenceKey: persistenceKey, safeMode: safeMode)
  }

  /// A real DisplayState over fake hardware: real Kit controllers, fake wire.
  /// `capabilities` feeds the D24 gate; nil means the transaction failed and
  /// unknown resolves to enabled.
  @MainActor static func displayState(
    id: CGDirectDisplayID = 7,
    name: String = "Test Display",
    persistenceKey: String = "test-display",
    capabilities: String? = nil
  ) -> AppModel.DisplayState {
    let writer = FakeDDCWriter(capabilities: capabilities)
    let display = ExternalDisplay(id: id, name: name, persistenceKey: persistenceKey)
    let prefs = prefs(persistenceKey: persistenceKey)
    let backends = BrightnessBackends(
      applierNative: FakeBrightnessApplier(),
      hdr: nil, shade: nil, gamma: nil)
    let controller = BrightnessController(
      writer: writer, backends: backends, prefs: prefs,
      displayID: id, wireSiblings: [])
    return AppModel.DisplayState(
      display: display,
      controller: controller,
      volume: DDCValueController(writer: writer, command: .volume, prefs: prefs),
      contrast: DDCValueController(writer: writer, command: .contrast, prefs: prefs),
      writer: writer)
  }

  /// A hardware-free AppModel (AT3): every injectable seam filled with a
  /// fake, so no MonitorPanelService and no CoreAudioDeviceProvider is ever
  /// constructed. Its display list is empty; derivation tests pass display
  /// state arrays directly instead of seeding the model.
  @MainActor static func appModel(safeMode: Bool = false) -> AppModel {
    AppModel(
      shade: FakeShade(), gamma: FakeGamma(),
      hdrToggling: FakeHDR(), audioDevices: FakeAudio(),
      safeMode: safeMode)
  }
}
