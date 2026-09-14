import CandelaKit
import CoreGraphics
import Foundation
import Testing

private actor LegacyUpdatePanel: DDCWriting {
  var raw: UInt16 = 81
  var writes: [UInt16] = []
  var succeeds = true
  func read(command: UInt8) -> (current: UInt16, max: UInt16)? {
    command == 0x10 ? (raw, 100) : nil
  }
  func write(command: UInt8, value: UInt16) -> Bool {
    guard command == 0x10 else { return false }
    writes.append(value)
    guard succeeds else { return false }
    raw = value
    return true
  }
  func setRaw(_ value: UInt16) { raw = value }
  func setSuccess(_ value: Bool) { succeeds = value }
}

@Suite("Legacy update brightness handback") @MainActor
struct LegacyUpdateBrightnessTests {
  @Test(arguments: [1, 2])
  func firstDiscoveryPreservesEveryAttachedPanel(count: Int) async throws {
    let rig = Rig(count: count)
    defer { rig.clear() }
    let model = rig.model(recover: true)
    await model.refresh()
    for state in model.displays {
      #expect(abs(state.controller.brightness - 0.81) < 0.000_001)
    }
    for panel in rig.panels { #expect(await panel.raw == 62) }
    #expect(rig.saved == 0.81)
    // An OSD change after migration remains an external adjustment.
    for panel in rig.panels { await panel.setRaw(40) }
    await model.refresh()
    #expect(rig.saved == 0.7)
  }

  @Test func aFailedTwinCanRecoverOnTheNextLaunch() async {
    let rig = Rig(count: 2)
    defer { rig.clear() }
    await rig.panels[1].setSuccess(false)
    let first = rig.model(recover: true)
    await first.refresh()
    #expect(rig.saved == 0.81)
    #expect(await rig.panels[0].raw == 62)
    #expect(await rig.panels[1].raw == 81)
    await rig.panels[1].setSuccess(true)
    let next = rig.model(recover: false)
    await next.refresh()
    #expect(rig.saved == 0.81)
    for panel in rig.panels { #expect(await panel.raw == 62) }
  }

  @Test func aDifferentMonitorValueIsAdopted() async {
    let rig = Rig()
    defer { rig.clear() }
    await rig.panels[0].setRaw(40)
    await rig.model(recover: true).refresh()
    #expect(rig.saved == 0.7)
    #expect(await rig.panels[0].writes.isEmpty)
  }

  @Test func safeModeDefersTheHintWithoutWriting() async {
    let rig = Rig()
    defer { rig.clear() }
    let safeModel = rig.model(recover: true, safeMode: true)
    await safeModel.refresh()
    #expect(rig.saved == 0.81)
    #expect(await rig.panels[0].writes.isEmpty)
    // The global update UI mark has been consumed before the next launch.
    let normalModel = rig.model(recover: false)
    await normalModel.refresh()
    #expect(rig.saved == 0.81)
    #expect(await rig.panels[0].raw == 62)
  }

  @Test(arguments: [false, true])
  func laterArrivalsNeverReceiveTheInitialHint(emptyFirstPass: Bool) async {
    let rig = Rig()
    defer { rig.clear() }
    if emptyFirstPass { rig.attached = false }
    let model = rig.model(recover: true)
    await model.refresh()
    rig.attached = false
    await model.refresh()
    rig.attached = true
    UserDefaults.standard.set(0.81, forKey: rig.storageKey)
    await rig.panels[0].setRaw(81)
    await model.refresh()
    #expect(rig.saved == 0.905)
  }

  @MainActor private final class Rig {
    let key = "app-tests-legacy-update-\(UUID().uuidString)"
    let panels: [LegacyUpdatePanel]
    var attached = true
    var storageKey: String { "combinedBrightness.\(key)" }
    var saved: Double { UserDefaults.standard.double(forKey: storageKey) }
    init(count: Int = 1) {
      panels = (0..<count).map { _ in LegacyUpdatePanel() }
      UserDefaults.standard.set(0.81, forKey: storageKey)
    }
    func model(recover: Bool, safeMode: Bool = false) -> AppModel {
      AppModel(
        shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(), audioDevices: FakeAudio(),
        safeMode: safeMode, recoverLegacyUpdateHandbacks: recover,
        discoverDisplays: { [self] _ in
          let entries: AppModel.DiscoveredDisplays = attached ? panels.enumerated().map { index, panel in
            (display: ExternalDisplay(id: CGDirectDisplayID(901 + index), name: "Panel", persistenceKey: key),
             writer: panel,
             facts: DisplayHardwareFacts(
               transportUpstream: nil, transportDownstream: nil, manufacturerID: nil,
               alphanumericSerialNumber: nil, numericSerialNumber: nil,
               physicalWidthCm: nil, physicalHeightCm: nil, ioDisplayLocation: nil,
               ioregMatchScore: 0))
          } : []
          return .init(controlled: entries, report: .notEnumerated)
        })
    }
    func clear() {
      for name in UserDefaults.standard.dictionaryRepresentation().keys where name.hasSuffix(".\(key)") {
        UserDefaults.standard.removeObject(forKey: name)
      }
    }
  }
}
