import CandelaKit
import Foundation
import Testing

@Suite("Diagnostics audio snapshot")
@MainActor
struct DiagnosticsSnapshotTests {
  private func model(audio: FakeAudio, capabilities: String? = nil) async -> AppModel {
    let discovery = ScriptedDiscovery([
      (id: 70001, key: "report-left-\(UUID().uuidString)", name: "Left Monitor"),
      (id: 70002, key: "report-right-\(UUID().uuidString)", name: "Right Monitor"),
    ])
    let model = AppModel(
      shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(),
      audioDevices: audio, discoverDisplays: {
        let entries = discovery.discover($0)
        for entry in entries { (entry.writer as? FakeDDCWriter)?.capabilities = capabilities }
        return entries
      })
    _ = await model.refresh()
    return model
  }

  @Test func reportIncludesVolumeReasonWithoutTreatingAnUnansweredDisplayAsUnsupported() async {
    let model = await model(audio: FakeAudio())
    let report = DiagnosticsReport.render(model.diagnosticsSnapshot())
    #expect(report.contains("  volume: Available: Candela"))
    #expect(report.contains("so the control stays on"))
    #expect(!report.contains("volume: Unavailable"))
  }

  @Test func reportAssociatesTheAudioMatchWithTheCorrectDisplay() async {
    let audio = FakeAudio(device: .init(id: 1, name: "Right Monitor", canSetOwnVolume: false))
    let model = await model(audio: audio)
    let report = DiagnosticsReport.render(model.diagnosticsSnapshot())
    let sections = report.components(separatedBy: "\ndisplay: ")
    let left = sections.first { $0.hasPrefix("Left Monitor\n") }
    let right = sections.first { $0.hasPrefix("Right Monitor\n") }
    #expect(left?.contains("  sound output: Right Monitor: not matched to this display") == true)
    #expect(right?.contains("  sound output: Right Monitor: matched to this display") == true)
  }

  @Test func nextReportReflectsAChangedOrRemovedOutputWithoutOpeningDiagnostics() async {
    let audio = FakeAudio(device: .init(id: 1, name: "Left Monitor", canSetOwnVolume: false))
    let model = await model(audio: audio)
    let before = model.diagnosticsSnapshot()
    audio.device = .init(id: 2, name: "Headphones", canSetOwnVolume: true)
    let after = model.diagnosticsSnapshot()
    audio.device = nil
    let removed = model.diagnosticsSnapshot()
    #expect(DiagnosticsReport.render(before).contains("sound output: Left Monitor: matched"))
    #expect(DiagnosticsReport.render(after).contains("sound output: Headphones: not matched"))
    #expect(!DiagnosticsReport.render(after).contains("sound output: Left Monitor"))
    #expect(DiagnosticsReport.render(removed).contains(
      "sound output: macOS reports no default output device"))
  }

  @Test(arguments: [
    ("(vcp(10 12 62))", "Available: this display lists the volume command"),
    ("(vcp(10 12))", "Unavailable: this display's description parsed cleanly and does not list the volume command"),
    ("(broken)", "Available: Candela could not read a command list out of this display's description, so the control stays on"),
  ])
  func reportPreservesTheCapabilityVerdict(capabilities: String, reason: String) async throws {
    let model = await model(audio: FakeAudio(), capabilities: capabilities)
    let display = try #require(model.displays.first)
    let key = display.display.persistenceKey
    for _ in 0..<200 where model.volumeSupport[key] == nil { await Task.yield() }
    _ = try #require(model.volumeSupport[key])
    let report = DiagnosticsReport.render(model.diagnosticsSnapshot())
    #expect(report.contains("  volume: \(reason)\n"))
  }

  @Test func reportUsesTheDisplaysVolumeAndAudioNameOverrides() async throws {
    let audio = FakeAudio(device: .init(id: 1, name: "Desk Speakers", canSetOwnVolume: false))
    let model = await model(audio: audio)
    let display = try #require(model.displays.first)
    let key = display.display.persistenceKey
    let prefs = DisplayPrefs(persistenceKey: key)
    defer {
      UserDefaults.standard.removeObject(forKey: "audioDeviceNameOverride.\(key)")
      UserDefaults.standard.removeObject(forKey: "audioSinkOverride.\(key)")
    }
    prefs.audioDeviceNameOverride = "Desk Speakers"
    prefs.audioSinkOverride = .forceNone
    let report = DiagnosticsReport.render(model.diagnosticsSnapshot())
    #expect(report.contains("volume: Unavailable: you set this display's volume slider to always off"))
    #expect(report.contains("sound output: Desk Speakers: matched to this display"))
    prefs.audioSinkOverride = .forcePresent
    #expect(DiagnosticsReport.render(model.diagnosticsSnapshot()).contains(
      "volume: Available: you set this display's volume slider to always on"))
  }
}
