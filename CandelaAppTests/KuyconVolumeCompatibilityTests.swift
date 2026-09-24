import CandelaKit
import Foundation
import Observation
import Testing

@Suite("Kuycon volume compatibility", .timeLimit(.minutes(1))) @MainActor
struct KuyconVolumeCompatibilityTests {
  @Test(arguments: ["Kuycon P27U", "Kuycon P32U"])
  func omittedVolumeStillEnablesControlsAndExplainsWhy(name: String) async throws {
    try await withDisplay(name: name) { model, state, writer, prefs in
      let key = state.display.persistenceKey
      #expect(model.volumeSupport[key] == .supported)
      #expect(model.volumeSliderEnabled(state))
      #expect(model.volumeKeyEnabledStates([state]).count == 1)
      #expect(model.tapConfig.watchedKeys.contains(.volumeUp))
      #expect(prefs.audioSinkOverride == .auto)

      // Only volume is established by the report. An omitted dedicated mute
      // command must still fall back to the volume register.
      prefs.enableMuteUnmute = true
      #expect(model.muteSupport[key] == .unsupported)
      #expect(!model.dedicatedMuteCommandInReach(state))
      #expect(model.muteKeyEnabledStates([state]).count == 1)
      #expect(model.tapConfig.watchedKeys.contains(.mute))
      state.volume.setValue(0.625)
      await state.volume.waitForPendingWrites()
      #expect(writer.writes.contains { $0.command == 0x62 && $0.value > 0 })
      state.volume.toggleMute()
      await state.volume.waitForPendingWrites()
      #expect(writer.writes.last?.command == 0x62)
      #expect(writer.writes.last?.value == 0)
      #expect(!writer.writes.contains { $0.command == 0x8D && $0.value == 1 })
      state.volume.toggleMute()
      await state.volume.waitForPendingWrites()
      #expect(!state.volume.isMuted)
      #expect(writer.writes.contains { $0.command == 0x62 && $0.value > 0 })

      let reason = model.diagnosticsVolumeAvailability(state)
      #expect(reason.hasPrefix("Available:"))
      #expect(reason.contains("compatibility"))
      #expect(!reason.contains("this display lists the volume command"))
      let report = DiagnosticsReport.render(model.diagnosticsSnapshot())
      #expect(report.contains(reason))
      #expect(report.contains("advertised VCP codes: 10 12"))
      #expect(model.capabilityString[key] == "(vcp(10 12))")
    }
  }

  @Test(arguments: [
    ("DELL U2725QE", "DEL"), ("Kuycon P24U", "GKT"),
    ("Kuycon P32U Pro", "GKT"), ("Kuycon P32U", "DEL"),
    ("Kuycon P27U", ""),
  ])
  func otherHardwareKeepsItsCapabilityVerdict(name: String, manufacturer: String) async throws {
    try await withDisplay(name: name, manufacturer: manufacturer) { model, state, _, prefs in
      // A user-assigned name must not create a hardware exception.
      prefs.friendlyName = "Kuycon P32U"
      #expect(!model.volumeSliderEnabled(state))
      #expect(model.volumeKeyEnabledStates([state]).isEmpty)
      #expect(model.muteKeyEnabledStates([state]).isEmpty)
      #expect(!model.diagnosticsVolumeAvailability(state).contains("compatibility"))
    }
  }

  @Test func userAndCommandDisablesStillWin() async throws {
    try await withDisplay(name: "Kuycon P32U") { model, state, _, prefs in
      #expect(model.volumeSliderEnabled(state))
      prefs.audioSinkOverride = .forceNone
      #expect(!model.volumeSliderEnabled(state))
      #expect(model.volumeKeyEnabledStates([state]).isEmpty)
      #expect(model.muteKeyEnabledStates([state]).isEmpty)
      #expect(!model.tapConfig.watchedKeys.contains(.volumeUp))
      #expect(model.diagnosticsVolumeAvailability(state).contains("always off"))
      prefs.audioSinkOverride = .auto
      prefs.forceSoftware = true
      #expect(!state.volume.isAvailable)
      #expect(!model.tapConfig.watchedKeys.contains(.volumeUp))
      #expect(model.diagnosticsVolumeAvailability(state).hasPrefix("Unavailable:"))
      #expect(!model.diagnosticsVolumeAvailability(state).contains("compatibility"))
    }
  }

  @Test(arguments: ["(vcp(10 12 62))", "(vcp(10 ZZ))", ""])
  func anExceptionIsNotClaimedWithoutAnOmission(capabilities: String) async throws {
    try await withDisplay(name: "Kuycon P32U", capabilities: capabilities) { model, state, _, _ in
      #expect(model.volumeSliderEnabled(state))
      #expect(!model.diagnosticsVolumeAvailability(state).contains("compatibility"))
    }
  }

  @Test func refreshedManufacturerReassessesTheCachedDescription() async throws {
    var manufacturer: String?
    try await withDisplay(name: "Kuycon P32U", discoveryManufacturer: { manufacturer }) { model, state, _, _ in
      var rearms = 0
      model.onVolumeKeyRoutingChanged = { rearms += 1 }
      #expect(!model.volumeSliderEnabled(state))
      manufacturer = "GKT"
      _ = await model.refresh()
      #expect(model.volumeSliderEnabled(state))
      #expect(model.tapConfig.watchedKeys.contains(.volumeUp))
      #expect(model.diagnosticsVolumeAvailability(state).contains("compatibility"))
      #expect(rearms == 1)

      manufacturer = "DEL"
      _ = await model.refresh()
      #expect(!model.volumeSliderEnabled(state))
      #expect(!model.tapConfig.watchedKeys.contains(.volumeUp))
      #expect(model.diagnosticsVolumeAvailability(state).hasPrefix("Unavailable:"))
      #expect(rearms == 2)
      #expect(model.capabilityString[state.display.persistenceKey] == "(vcp(10 12))")
    }
  }

  private func withDisplay(
    name: String, manufacturer: String = "GKT", capabilities: String = "(vcp(10 12))",
    discoveryManufacturer: (() -> String?)? = nil,
    body: (AppModel, AppModel.DisplayState, FakeDDCWriter, DisplayPrefs) async throws -> Void
  ) async throws {
    let key = "kuycon-tests-\(UUID().uuidString)"
    defer {
      for entry in UserDefaults.standard.dictionaryRepresentation().keys where entry.hasSuffix(key) {
        UserDefaults.standard.removeObject(forKey: entry)
      }
    }
    let writer = FakeDDCWriter(capabilities: capabilities.isEmpty ? nil : capabilities)
    let model = AppModel(
      shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(),
      audioDevices: FakeAudio(device: .init(id: 1, name: name, canSetOwnVolume: false)),
      discoverDisplays: { _ in
        let facts = DisplayHardwareFacts(
          transportUpstream: "DP", transportDownstream: nil,
          manufacturerID: discoveryManufacturer.map { $0() } ?? manufacturer,
          alphanumericSerialNumber: nil, numericSerialNumber: nil, physicalWidthCm: nil,
          physicalHeightCm: nil, ioDisplayLocation: nil, ioregMatchScore: 10)
        return DisplayDiscoverySurvey(controlled: [(
          display: ExternalDisplay(id: 70003, name: name, persistenceKey: key),
          writer: writer, facts: facts)], report: .notEnumerated)
      })
    _ = await model.refresh()
    let (changes, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    var iterator = changes.makeAsyncIterator()
    while model.volumeSupport[key] == nil {
      withObservationTracking { _ = model.volumeSupport } onChange: { continuation.yield(()) }
      guard await iterator.next() != nil else { return }
    }
    try await body(model, #require(model.displays.first), writer, DisplayPrefs(persistenceKey: key))
  }
}
