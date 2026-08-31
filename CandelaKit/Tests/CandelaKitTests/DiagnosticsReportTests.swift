import Testing
@testable import CandelaKit

@Suite("Diagnostics report rendering")
struct DiagnosticsReportTests {
  private func entry(nonDefaultPrefs: [String] = ["friendlyName = Left"]) -> DiagnosticsReportSnapshot.DisplayEntry {
    .init(name: "Left", hardwareName: "DELL U2725QE", connection: "DisplayPort",
          manufacturer: "Dell", hasSerial: true,
          currentMode: "1296 × 2304 at 120 Hz", controlMethod: "Hardware (DDC)",
          readbackVerdict: "answers reads", hdrEngaged: false,
          nonDefaultPrefs: nonDefaultPrefs)
  }

  private func snapshot() -> DiagnosticsReportSnapshot {
    .init(appVersion: "0.9.1 (214)", osVersion: "macOS 26.0 (25A100)",
          safeMode: false, accessibilityGranted: true, launchAtLogin: "enabled",
          displays: [entry()],
          recentEvents: ["12:01 DELL U2725QE arrived"])
  }

  @Test func coversEveryDisplayAndTheAppEnvelope() {
    let text = DiagnosticsReport.render(snapshot())
    for needle in ["0.9.1 (214)", "macOS 26.0", "DELL U2725QE", "Hardware (DDC)",
                   "answers reads", "friendlyName = Left", "DELL U2725QE arrived"] {
      #expect(text.contains(needle), "missing \(needle)")
    }
  }

  @Test func neverContainsASerialValueOnlyPresence() {
    let text = DiagnosticsReport.render(snapshot())
    #expect(text.contains("serial: present"))
  }

  @Test func nonDefaultSectionSaysNoneWhenEmpty() {
    let s = DiagnosticsReportSnapshot(
      appVersion: "0.9.1 (214)", osVersion: "macOS 26.0 (25A100)",
      safeMode: false, accessibilityGranted: true, launchAtLogin: "enabled",
      displays: [entry(nonDefaultPrefs: [])],
      recentEvents: [])
    #expect(DiagnosticsReport.render(s).contains("non-default settings: none"))
  }

  @Test func serialAbsenceIsStatedRatherThanOmitted() {
    // The twin-display diagnosis turns on whether a serial exists at all, so
    // "none" has to be a line, not a missing one.
    let e = DiagnosticsReportSnapshot.DisplayEntry(
      name: "Left", hardwareName: "DELL U2725QE", connection: nil,
      manufacturer: nil, hasSerial: false, currentMode: nil,
      controlMethod: "Software (gamma)", readbackVerdict: "never asked",
      hdrEngaged: true, nonDefaultPrefs: [])
    let s = DiagnosticsReportSnapshot(
      appVersion: "1", osVersion: "2", safeMode: true, accessibilityGranted: false,
      launchAtLogin: "disabled", displays: [e], recentEvents: [])
    let text = DiagnosticsReport.render(s)
    #expect(text.contains("serial: none"))
    #expect(!text.contains("serial: present"))
  }

  @Test func rendersTheSameTextEveryTime() {
    // Pins that render carries nothing between calls, no accumulating buffer. It
    // does not prove purity: a minute-granularity timestamp would survive this.
    // Purity is structural instead, since the file imports nothing that reaches Date.
    let s = snapshot()
    #expect(DiagnosticsReport.render(s) == DiagnosticsReport.render(s))
  }

  @Test func namesTheRecentEventsSectionEvenWithNoEvents() {
    let s = DiagnosticsReportSnapshot(
      appVersion: "1", osVersion: "2", safeMode: false, accessibilityGranted: true,
      launchAtLogin: "enabled", displays: [], recentEvents: [])
    let text = DiagnosticsReport.render(s)
    #expect(text.contains("recent events: none"))
    #expect(text.contains("displays: none"))
  }

  @Test func keepsEveryDisplayWhenSeveralAreAttached() {
    let s = DiagnosticsReportSnapshot(
      appVersion: "1", osVersion: "2", safeMode: false, accessibilityGranted: true,
      launchAtLogin: "enabled",
      displays: [entry(), DiagnosticsReportSnapshot.DisplayEntry(
        name: "Right", hardwareName: "MSI MAG 341C", connection: "HDMI",
        manufacturer: "MSI", hasSerial: false, currentMode: "3440 × 1440 at 175 Hz",
        controlMethod: "Hardware (DDC)", readbackVerdict: "write-only",
        hdrEngaged: false, nonDefaultPrefs: ["forceSw = true", "minDDCOverride.brightness = 12"])],
      recentEvents: ["12:01 MSI MAG 341C arrived", "12:00 DELL U2725QE departed"])
    let text = DiagnosticsReport.render(s)
    for needle in ["Left", "Right", "MSI MAG 341C", "write-only",
                   "forceSw = true", "minDDCOverride.brightness = 12",
                   "MSI MAG 341C arrived", "DELL U2725QE departed"] {
      #expect(text.contains(needle), "missing \(needle)")
    }
  }

  @Test func statesSafeModeAndAccessibilityInBothDirections() {
    let on = DiagnosticsReport.render(snapshot())
    #expect(on.contains("safe mode: off"))
    #expect(on.contains("accessibility: granted"))
    let s = DiagnosticsReportSnapshot(
      appVersion: "1", osVersion: "2", safeMode: true, accessibilityGranted: false,
      launchAtLogin: "disabled", displays: [], recentEvents: [])
    let off = DiagnosticsReport.render(s)
    #expect(off.contains("safe mode: on"))
    #expect(off.contains("accessibility: not granted"))
  }

  @Test func reportsHDRAndUnknownFieldsPerDisplay() {
    let e = DiagnosticsReportSnapshot.DisplayEntry(
      name: "Left", hardwareName: "DELL U2725QE", connection: nil,
      manufacturer: nil, hasSerial: true, currentMode: nil,
      controlMethod: "Software (gamma)", readbackVerdict: "never asked",
      hdrEngaged: true, nonDefaultPrefs: [])
    let s = DiagnosticsReportSnapshot(
      appVersion: "1", osVersion: "2", safeMode: false, accessibilityGranted: true,
      launchAtLogin: "enabled", displays: [e], recentEvents: [])
    let text = DiagnosticsReport.render(s)
    #expect(text.contains("hdr: engaged"))
    #expect(text.contains("connection: not reported"))
    #expect(text.contains("manufacturer: not reported"))
    #expect(text.contains("current mode: not reported"))
  }
}
