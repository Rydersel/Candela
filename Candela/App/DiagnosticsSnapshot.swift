import CandelaKit
import CoreGraphics
import Darwin
import Foundation

struct DiagnosticsAvailability {
  let brightness: String
  let contrast: String
  let mute: String
  let hdr: String
}

extension AppModel {
  typealias ReportField = DiagnosticsReportSnapshot.Field
  typealias ReportSection = DiagnosticsReportSnapshot.Section

  func diagnosticsAvailability(_ state: DisplayState) -> DiagnosticsAvailability {
    let prefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)
    let builtIn = self.builtIn?.id == state.id
    return DiagnosticsAvailability(
      brightness: DiagnosticsCopy.brightnessAvailability(state.controller.brightnessPath),
      contrast: builtIn ? "Not applicable: built-in display" : DiagnosticsCopy.contrastAvailability(
        isAvailable: state.contrast.isAvailable, forceSoftware: prefs.forceSoftware),
      mute: builtIn ? "Not applicable: built-in display" : DiagnosticsCopy.muteAvailability(
        muteEnabled: prefs.enableMuteUnmute, volumeAvailable: state.volume.isAvailable,
        forceSoftware: prefs.forceSoftware, override: prefs.audioSinkOverride,
        muteSupport: muteSupport[state.display.persistenceKey] ?? .unknown),
      hdr: builtIn ? "Managed by macOS" : (!state.controller.hdrCapabilityProbed
        ? "Not checked yet" : DiagnosticsCopy.hdrAvailability(
          displayServicesAvailable: DisplayServices.isAvailable,
          supportsHDR: state.controller.supportsHDR, app: AppInfo.productName))
    )
  }

  var diagnosticsWatchedKeyFamilies: [String] {
    guard let config = lastArmedTapConfig else { return [] }
    return DiagnosticsCopy.watchedKeyFamilies(
      brightness: config.watchedKeys.contains(.brightnessUp) || config.watchedKeys.contains(.brightnessDown),
      volume: config.watchedKeys.contains(.volumeUp) || config.watchedKeys.contains(.volumeDown),
      mute: config.watchedKeys.contains(.mute))
  }

  var diagnosticsWatchedKeys: String {
    DiagnosticsCopy.watchedKeys(families: diagnosticsWatchedKeyFamilies, tapRunning: lastArmedTapConfig != nil)
  }

  /// Only human-readable fields use this list. VCP numbers and dimensions are
  /// measurements, even when their digits happen to equal a short serial.
  var diagnosticsPrivateIdentifiers: [String] {
    let storageKeys = allControlledStates.map(\.display.persistenceKey) + Array(hardwareFacts.keys)
      + Array(capabilityString.keys)
    let configKeys = displayModes.catalogs.values.map { $0.display.identity.key }
      + mirrorTopology.topology().displays.map { $0.identity.key }
    let serials = hardwareFacts.values.flatMap {
      [$0.alphanumericSerialNumber, $0.numericSerialNumber.map(String.init)].compactMap { $0 }
    }
    let capabilityIdentifiers = capabilityString.values.flatMap { DiagnosticsCapabilityText.identifiers(in: $0) }
    return (storageKeys + configKeys + serials + capabilityIdentifiers).filter { !$0.isEmpty && $0 != "builtIn" }
  }

  func diagnosticsSystemSections(audioOutput: AudioOutputDevice?, capturedAt: Date) -> [ReportSection] {
    let topology = mirrorTopology.topology()
    let controlledIDs = Set(allControlledStates.map(\.id))
    let uncontrolled = topology.displays.filter { !controlledIDs.contains($0.id) }
    let identifiers = diagnosticsPrivateIdentifiers
    func scrub(_ value: String) -> String {
      DiagnosticsCapabilityText.redactingIdentifiers(in: value, identifiers: identifiers)
    }
    var sections: [ReportSection] = [
      .init("system", [
        .init("captured at", capturedAt.formatted(.iso8601)),
        .init("Mac model", DiagnosticsSystemInfo.macModel ?? "not reported"),
        .init("screen recording", CGPreflightScreenCaptureAccess() ? "granted" : "not granted"),
        .init("keys being watched", diagnosticsWatchedKeys),
        .init("default sound output", scrub(audioOutput?.name ?? DiagnosticsCopy.noDefaultOutputDevice)),
        .init("output has macOS volume control", audioOutput.map { $0.canSetOwnVolume ? "yes" : "no" }
          ?? "not applicable (no output device)"),
      ]),
      .init("display inventory", [
        .init("controlled displays", String(allControlledStates.count)),
        .init("displays in cached topology", topology.displays.isEmpty ? "no topology sample available" : String(topology.displays.count)),
        .init("scope", "Controlled displays are detailed below. Other displays use the cached topology; it may lag a connection change."),
      ]),
      .init("reading this report", [
        .init("collection", "Uses recorded state. Export does not test commands or change display settings."),
        .init("values", "App values may be requested or stored. Command acceptance does not confirm a physical change."),
        .init("privacy", "Serial fields, known device identifiers and unrecognized capability payloads are redacted. Review custom device names before sharing."),
      ]),
    ]
    if !uncontrolled.isEmpty {
      sections.append(.init("other displays in cached topology", uncontrolled.map { display in
        let reason = virtualDisplays.ownedDisplayIDs.contains(display.id)
          ? "Virtual display created by Candela; no hardware control"
          : "Not in the current control pool; exclusion reason was not recorded"
        return .init(scrub(display.name), reason)
      }))
    }
    return sections
  }

  func diagnosticsDisplaySections(_ state: DisplayState, capabilityRequest: String) -> [ReportSection] {
    let key = state.display.persistenceKey
    let prefs = DisplayPrefs(persistenceKey: key)
    let isBuiltIn = builtIn?.id == state.id
    let availability = diagnosticsAvailability(state)
    let identifiers = diagnosticsPrivateIdentifiers
    func scrub(_ value: String) -> String {
      DiagnosticsCapabilityText.redactingIdentifiers(in: value, identifiers: identifiers)
    }
    var capabilityFields: [ReportField] = [.init("capability request", capabilityRequest)]
    if let raw = capabilityString[key], !isBuiltIn {
      // Derive from the original response, never the export's redacted text.
      let codes = CapabilityString.codes(in: raw)
      let exported = DiagnosticsCapabilityText(raw, identifiers: identifiers)
      capabilityFields += [
        .init("capability parsing", codes == nil ? "could not parse" : "parsed"),
        .init("MCCS version", exported.metadata("mccs_ver")),
        .init("capability model", exported.metadata("model")),
        .init("display type", exported.metadata("type")),
        .init("advertised VCP codes", codes.map { $0.sorted().map { String(format: "%02X", $0) }.joined(separator: " ") }
          ?? "unknown (description did not parse)"),
        .init("commands Candela uses", DiagnosticsCopy.advertisedCommands(codes, app: AppInfo.productName)),
        .init("capability text treatment", exported.wasRedacted ? "redacted; parser results above use the original response" : "unchanged"),
        .init("capability description", exported.text),
      ]
    } else {
      capabilityFields.append(.init("capability description", capabilityRequest))
    }

    let noWire = "Not applicable: built-in display"
    var sections: [ReportSection] = [
      .init("reported capabilities", capabilityFields),
      .init("availability", [
        .init("brightness availability", availability.brightness),
        .init("contrast availability", availability.contrast),
        .init("mute availability", availability.mute),
        .init("HDR availability", availability.hdr),
      ]),
      .init("recorded read evidence", [
        .init("brightness read", isBuiltIn ? noWire : DiagnosticsReadEvidence.describe(state.controller.readEvidence)),
        .init("volume read", isBuiltIn ? noWire : DiagnosticsReadEvidence.describe(state.volume.readEvidence)),
        .init("contrast read", isBuiltIn ? noWire : DiagnosticsReadEvidence.describe(state.contrast.readEvidence)),
        .init("brightness scale", isBuiltIn ? noWire : DiagnosticsCopy.brightnessScale(
          didReadMax: state.controller.didReadMaxDDC, maxValue: state.controller.maxDDCValue,
          evidence: state.controller.readEvidence, app: AppInfo.productName)),
        .init("volume reported maximum", isBuiltIn ? noWire : state.volume.readMax.map(String.init) ?? "not recorded"),
        .init("contrast reported maximum", isBuiltIn ? noWire : state.contrast.readMax.map(String.init) ?? "not recorded"),
      ]),
      .init("current app state", [
        .init("brightness value", SliderSnap.percentText(state.controller.brightness)),
        .init("volume value", isBuiltIn ? noWire : SliderSnap.percentText(state.volume.value)),
        .init("contrast value", isBuiltIn ? noWire : SliderSnap.percentText(state.contrast.value)),
        .init("muted in Candela", isBuiltIn ? noWire : state.volume.isMuted ? "yes" : "no"),
        .init("last brightness command", DiagnosticsCopy.lastWrite(
          target: state.controller.lastAppliedTarget(), failed: state.controller.lastApplyFailed())),
        .init("OLED care enrolled", prefs.oledCareEnrolled ? "yes" : "no"),
        .init("mirroring", DiagnosticsCopy.mirroring(
          isMirrorSlave: mirrorTopology.topology().displays.first { $0.id == state.id }?.isMirrorSlave,
          isSynthesized: synthesis.isEngaged(displayID: state.id))),
        .init("last resolution problem", displayModes.report(for: state.id).map {
          scrub(DiagnosticsCopy.reapplyProblem($0.notice, app: AppInfo.productName))
        } ?? "none recorded"),
      ]),
    ]
    if let facts = hardwareFacts[key] {
      sections.append(.init("display hardware", [
        .init("physical size", facts.physicalWidthCm.flatMap { width in
          facts.physicalHeightCm.map { DiagnosticsCopy.displaySize(widthCm: width, heightCm: $0) }
        } ?? "not reported"),
        .init("hardware match score", String(facts.ioregMatchScore)),
      ]))
    }
    if let catalog = displayModes.catalogs[state.id] {
      sections.append(.init("resolution inventory", [
        .init("resolutions listed by macOS", String(catalog.all.count { $0.provenance == .coreGraphics })),
        .init("additional resolutions found", DiagnosticsCopy.additionalResolutions(
          revealed: catalog.all.count(where: \.isRevealed), revealsHiddenModes: displayModes.revealsHiddenModes)),
        .init("wire timing check", displayModes.guardsWireTiming ? "on" : "off"),
        .init("withheld by wire timing check", String(catalog.withheldForWireTiming)),
      ]))
    } else {
      sections.append(.init("resolution inventory", [.init("status", "not enumerated yet")]))
    }
    return sections
  }
}

private enum DiagnosticsSystemInfo {
  static var macModel: String? {
    var count = 0
    guard sysctlbyname("hw.model", nil, &count, nil, 0) == 0, count > 1, count < 256 else { return nil }
    var bytes = [UInt8](repeating: 0, count: count)
    guard sysctlbyname("hw.model", &bytes, &count, nil, 0) == 0 else { return nil }
    return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
  }
}
