import CandelaKit
import CoreGraphics
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

  @Test func reportIncludesTheCapabilityInputAndParsedCommandsForEveryDisplay() async throws {
    let raw = "(prot(monitor)type(lcd)model(P32U)cmds(01 03 F3)vcp(10 12 60(0F 11))mccs_ver(2.2))"
    let model = await model(audio: FakeAudio(), capabilities: raw)
    for _ in 0..<200 where model.volumeSupport.count < 2 { await Task.yield() }
    #expect(model.volumeSupport.count == 2)
    let report = DiagnosticsReport.render(model.diagnosticsSnapshot())
    let sections = report.components(separatedBy: "\ndisplay: ")
    for name in ["Left Monitor", "Right Monitor"] {
      let section = try #require(sections.first { $0.hasPrefix(name + "\n") })
      #expect(section.contains(raw))
      #expect(section.contains("MCCS version: 2.2"))
      #expect(section.contains("advertised VCP codes: 10 12 60"))
      #expect(section.contains("capability parsing: parsed"))
    }
    Attachment.record(report, named: "Diagnostics sample with simulated displays.txt")
  }

  @Test func reportDistinguishesMalformedCapabilitiesFromAnUnansweredRequest() async throws {
    let malformed = await model(audio: FakeAudio(), capabilities: "(vcp(10 ZZ))")
    let unanswered = await model(audio: FakeAudio())
    for _ in 0..<200 where malformed.volumeSupport.count < 2 || unanswered.volumeSupport.count < 2 {
      await Task.yield()
    }
    #expect(malformed.volumeSupport.count == 2)
    #expect(unanswered.volumeSupport.count == 2)
    let badReport = DiagnosticsReport.render(malformed.diagnosticsSnapshot())
    let noReport = DiagnosticsReport.render(unanswered.diagnosticsSnapshot())
    #expect(badReport.contains("capability parsing: could not parse"))
    #expect(badReport.contains("(vcp(10 ZZ))"))
    #expect(noReport.contains("capability description: no readable reply"))
    #expect(!noReport.contains("advertised VCP codes: none"))
  }

  @Test func reportDoesNotPublishIdentifierOrVendorPayloadsFromCapabilities() async throws {
    let raw = "(prot(monitor)model(P32U PRIVATE-SERIAL-123)serial(PRIVATE-SERIAL-123)vendor_data(PRIVATE-VENDOR-456)vcp(10 12))"
    let model = await model(audio: FakeAudio(), capabilities: raw)
    for _ in 0..<200 where model.volumeSupport.count < 2 { await Task.yield() }
    #expect(model.volumeSupport.count == 2)
    let report = DiagnosticsReport.render(model.diagnosticsSnapshot())
    #expect(report.contains("vcp(10 12)"))
    #expect(report.contains("serial([redacted])"))
    #expect(report.contains("vendor_data([redacted])"))
    #expect(!report.contains("PRIVATE-SERIAL-123"))
    #expect(!report.contains("PRIVATE-VENDOR-456"))
    #expect(report.contains("capability model: P32U [redacted]"))
  }

  @Test func departedDisplaysCannotRestoreIdentifiersInRecentEvents() async throws {
    let key = "report-departed-\(UUID().uuidString)"
    let discovery = ScriptedDiscovery([(id: 70004, key: key, name: "Monitor PRIVATE123 \(key)")])
    let model = AppModel(
      shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(), audioDevices: FakeAudio(),
      safeMode: true, discoverDisplays: {
        let entries = discovery.discover($0)
        for entry in entries {
          (entry.writer as? FakeDDCWriter)?.capabilities = "(serial(PRIVATE123)vcp(10))"
        }
        return entries
      })
    _ = await model.refresh()
    for _ in 0..<200 where model.volumeSupport[key] == nil { await Task.yield() }
    _ = try #require(model.volumeSupport[key])
    let before = DiagnosticsReport.render(model.diagnosticsSnapshot())
    #expect(!before.contains("PRIVATE123"))
    #expect(!before.contains(key))
    discovery.topology = []
    _ = await model.refresh()
    #expect(model.capabilityString[key] == nil)
    #expect(model.hardwareFacts[key] == nil)
    let after = DiagnosticsReport.render(model.diagnosticsSnapshot())
    #expect(after.contains("arrived"))
    #expect(after.contains("departed"))
    #expect(!after.contains("PRIVATE123"))
    #expect(!after.contains(key))
  }

  @Test func uncontrolledTopologyNamesAreScrubbedWithTheirOwnIdentity() {
    let model = AppModel(shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(),
                         audioDevices: FakeAudio(), safeMode: true, discoverDisplays: { _ in [] })
    let identity = DisplayConfigIdentity(vendor: 100, model: 200, serial: 7391955, isBuiltIn: false)
    model.mirrorTopology.update(MirrorTopology([
      ConfiguredDisplay(id: 70005, identity: identity, name: "Other \(identity.key)", isBuiltIn: false),
    ]))
    let report = DiagnosticsReport.render(model.diagnosticsSnapshot())
    #expect(report.contains("other displays in cached topology:"))
    #expect(report.contains("Other [redacted]"))
    #expect(!report.contains(identity.key))
  }

  @Test func reportIncludesPerControlEvidenceAndCurrentAudioVolumeOwnership() async {
    let audio = FakeAudio(device: .init(id: 1, name: "Left Monitor", canSetOwnVolume: false))
    let model = await model(audio: audio)
    let before = DiagnosticsReport.render(model.diagnosticsSnapshot())
    for label in ["brightness availability:", "contrast availability:", "mute availability:",
                  "HDR availability:", "brightness read:", "volume read:", "contrast read:",
                  "keys being watched:", "screen recording:", "Mac model:", "captured at:"] {
      #expect(before.contains(label), "Missing \(label)")
    }
    #expect(before.contains("output has macOS volume control: no"))
    audio.device = .init(id: 2, name: "Headphones", canSetOwnVolume: true)
    let after = DiagnosticsReport.render(model.diagnosticsSnapshot())
    #expect(after.contains("output has macOS volume control: yes"))
    audio.device = nil
    #expect(DiagnosticsReport.render(model.diagnosticsSnapshot()).contains(
      "output has macOS volume control: not applicable (no output device)"))
  }

  @Test func reportDistinguishesPendingCapabilitiesAndUnprobedHDR() async throws {
    let writer = ReportPendingWriter()
    let key = "report-pending-\(UUID().uuidString)"
    let discovery = ScriptedDiscovery([(id: 70006, key: key, name: "Pending monitor")])
    let model = AppModel(shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(),
      audioDevices: FakeAudio(), safeMode: true, discoverDisplays: {
        discovery.discover($0).map { (display: $0.display, writer: writer, facts: $0.facts) }
      })
    _ = await model.refresh()
    let pending = DiagnosticsReport.render(model.diagnosticsSnapshot())
    await writer.resolve()
    #expect(pending.contains("capability request: in progress"))
    #expect(pending.contains("HDR availability: Not checked yet"))
    for _ in 0..<200 where model.volumeSupport[key] == nil { await Task.yield() }
    _ = try #require(model.volumeSupport[key])
    #expect(DiagnosticsReport.render(model.diagnosticsSnapshot()).contains("capability request: no readable reply"))
  }

  @Test func reportDistinguishesAnUnavailableTapFromIntentionallyWatchingNoKeys() {
    let model = AppModel(shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(),
                         audioDevices: FakeAudio(), safeMode: true, discoverDisplays: { _ in [] })
    #expect(DiagnosticsReport.render(model.diagnosticsSnapshot()).contains("None: the media-key tap is not running"))
    model.noteTapArmed(.init(watchedKeys: [], interceptAlternateBrightnessKeys: false))
    #expect(DiagnosticsReport.render(model.diagnosticsSnapshot()).contains("None: every media key is going straight to macOS"))
    model.noteTapArmed(.init(watchedKeys: [.volumeUp, .volumeDown], interceptAlternateBrightnessKeys: false))
    #expect(DiagnosticsReport.render(model.diagnosticsSnapshot()).contains("keys being watched: volume"))
    model.noteTapDisarmed()
    #expect(DiagnosticsReport.render(model.diagnosticsSnapshot()).contains("None: the media-key tap is not running"))
  }

  @Test func snapshotDoesNotIssueHardwareRequestsOrChangeStoredValues() async throws {
    let key = "report-read-only-\(UUID().uuidString)"
    let writer = ReportCountingWriter()
    let model = AppModel(
      shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(), audioDevices: FakeAudio(),
      safeMode: true, discoverDisplays: { _ in
        [(display: ExternalDisplay(id: 70003, name: "Read-only fixture", persistenceKey: key),
          writer: writer,
          facts: DisplayHardwareFacts(transportUpstream: "DP", transportDownstream: nil,
            manufacturerID: "TEST", alphanumericSerialNumber: "PRIVATE-SERIAL-987", numericSerialNumber: nil,
            physicalWidthCm: 60, physicalHeightCm: 34, ioDisplayLocation: "PRIVATE-IOREG", ioregMatchScore: 20))]
      })
    _ = await model.refresh()
    for _ in 0..<200 where model.volumeSupport[key] == nil { await Task.yield() }
    _ = try #require(model.volumeSupport[key])
    let state = try #require(model.displays.first)
    let beforeCalls = await writer.calls
    let beforeValues = [state.controller.brightness, state.volume.value, state.contrast.value]
    let snapshot = model.diagnosticsSnapshot()
    let report = DiagnosticsReport.render(snapshot)
    #expect(DiagnosticsReport.render(snapshot) == report)
    #expect(await writer.calls == beforeCalls)
    #expect([state.controller.brightness, state.volume.value, state.contrast.value] == beforeValues)
    #expect(!report.contains(key))
    #expect(!report.contains("PRIVATE-SERIAL-987"))
    #expect(!report.contains("PRIVATE-IOREG"))
    #expect(report.contains("capability model: Test [redacted]"))
    #expect(report.contains("advertised VCP codes: 10 12"))
  }

  @Test func reportKeepsParserFailureWhenRawPayloadsAreRedacted() async {
    let model = await model(audio: FakeAudio(), capabilities: "(vcp(10 PRIVATE-SERIAL))")
    for _ in 0..<200 where model.volumeSupport.count < 2 { await Task.yield() }
    #expect(model.volumeSupport.count == 2)
    let report = DiagnosticsReport.render(model.diagnosticsSnapshot())
    #expect(report.contains("capability parsing: could not parse"))
    #expect(report.contains("advertised VCP codes: unknown"))
    #expect(report.contains("vcp(10 [redacted])"))
    #expect(!report.contains("PRIVATE-SERIAL"))
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

private actor ReportCountingWriter: DDCWriting {
  private(set) var calls = 0
  func write(command: UInt8, value: UInt16) async -> Bool {
    calls += 1
    return true
  }
  func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
    calls += 1
    return nil
  }
  func readCapabilityString() async -> String? {
    calls += 1
    return "(model(Test PRIVATE-SERIAL-987)vcp(10 12))"
  }
}

private actor ReportPendingWriter: DDCWriting {
  private var released = false
  private var continuation: CheckedContinuation<String?, Never>?
  func write(command: UInt8, value: UInt16) async -> Bool { true }
  func read(command: UInt8) async -> (current: UInt16, max: UInt16)? { nil }
  func readCapabilityString() async -> String? {
    if released { return nil }
    return await withCheckedContinuation { continuation = $0 }
  }
  func resolve() {
    released = true
    continuation?.resume(returning: nil)
    continuation = nil
  }
}
