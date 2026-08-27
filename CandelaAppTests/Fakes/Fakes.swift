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
  /// A panel that stops accepting commands mid-session. The write is still
  /// RECORDED when it fails: the transaction was attempted, which is the whole
  /// distinction the wire's health counts.
  var writesSucceed = true
  private(set) var writes: [(command: UInt8, value: UInt16)] = []

  init(capabilities: String? = nil) {
    self.capabilities = capabilities
  }

  func write(command: UInt8, value: UInt16) async -> Bool {
    writes.append((command, value))
    return writesSucceed
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

/// Holds no baselines, so SS15's `assumingLinearBaseline` leg deliberately
/// takes the protocol's forwarding default: there is nothing here for it to do
/// differently. A fake that DID hold baselines would have to implement it, and
/// nothing would say so at compile time.
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

/// A discovery seam whose answer a test sets between passes: the only route to
/// a populated `AppModel` display list, and the only way to script a topology
/// change that no cable arrangement can produce (a same-port panel swap always
/// splits into a departure pass and an arrival pass on real hardware).
@MainActor
final class ScriptedDiscovery {
  var topology: [(id: CGDirectDisplayID, key: String, name: String)] = []
  /// One writer per persistence key, kept so a rebuild is not mistaken for a
  /// rebind: a fresh writer every pass would make every controller look new.
  private var writers: [String: FakeDDCWriter] = [:]

  init(_ topology: [(id: CGDirectDisplayID, key: String, name: String)] = []) {
    self.topology = topology
  }

  func discover(_: Set<CGDirectDisplayID>) -> AppModel.DiscoveredDisplays {
    topology.map { entry in
      let writer = writers[entry.key] ?? {
        let fresh = FakeDDCWriter()
        writers[entry.key] = fresh
        return fresh
      }()
      return (
        display: ExternalDisplay(id: entry.id, name: entry.name, persistenceKey: entry.key),
        writer: writer,
        // Nothing that drives this seam reads the facts; reconciliation decides
        // on the persistence key alone.
        facts: DisplayHardwareFacts(
          transportUpstream: nil, transportDownstream: nil, manufacturerID: nil,
          alphanumericSerialNumber: nil, numericSerialNumber: nil,
          physicalWidthCm: nil, physicalHeightCm: nil, ioDisplayLocation: nil,
          ioregMatchScore: 0)
      )
    }
  }
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
  /// constructed. Its display list is empty until something refreshes it; the
  /// `discovery` overload below is what fills one.
  @MainActor static func appModel(safeMode: Bool = false) -> AppModel {
    AppModel(
      shade: FakeShade(), gamma: FakeGamma(),
      hdrToggling: FakeHDR(), audioDevices: FakeAudio(),
      safeMode: safeMode)
  }

  /// The same hardware-free model with its discovery scripted, so a caller can
  /// `await model.refresh()` into a known external topology.
  ///
  /// The BUILT-IN slot is not scripted and cannot be: `refreshBuiltIn` reads
  /// `BuiltInDisplayDiscovery` directly, so whether `model.builtIn` is filled
  /// depends on the machine running the suite. Nothing built on this may assert
  /// on the built-in's presence, which is also why it is worth asserting that
  /// the built-in never reaches `displays`.
  @MainActor static func appModel(
    discovery: ScriptedDiscovery, safeMode: Bool = false
  ) -> AppModel {
    AppModel(
      shade: FakeShade(), gamma: FakeGamma(),
      hdrToggling: FakeHDR(), audioDevices: FakeAudio(),
      safeMode: safeMode,
      discoverDisplays: { discovery.discover($0) })
  }
}

/// SplitMix64, as in the engine suite. Seeded so a planted control's position
/// is reproducible and a failure can be re-run.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
