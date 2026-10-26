import AppKit
import CandelaKit
import Testing

@Suite("Hardware report handoff")
@MainActor
struct HardwareReportHandoffTests {
  private func snapshot() -> DiagnosticsReportSnapshot {
    DiagnosticsReportSnapshot(
      appVersion: "1.0.5", osVersion: "27.0.1", safeMode: false,
      accessibilityGranted: true, launchAtLogin: "on",
      displays: [
        .init(
          name: "Private OLED", hardwareName: "MAG 341C OLED", connection: "USB-C",
          manufacturer: "MSI", hasSerial: true, currentMode: "3440 x 1440",
          controlMethod: "DDC", readbackVerdict: "answers", hdrEngaged: false,
          nonDefaultPrefs: [], volumeAvailability: "available", soundOutput: "none")
      ],
      recentEvents: [])
  }

  @Test func copiesTheReportBeforeOpeningTheHardwareForm() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    var openedURL: URL?

    let outcome = HardwareReportHandoff.prepare(
      snapshot: snapshot(), pasteboard: pasteboard,
      openURL: { url in
        #expect(pasteboard.string(forType: .string)?.contains("display: Private OLED") == true)
        openedURL = url
        return true
      })

    #expect(outcome == .opened)
    #expect(openedURL?.absoluteString ==
      "https://github.com/Rydersel/Candela/issues/new?template=hardware_report.yml")
    #expect(openedURL?.absoluteString.contains("Private OLED") == false)
    #expect(pasteboard.string(forType: .string)?.contains("serial: present") == true)
  }

  @Test func failedBrowserOpenLeavesTheReportOnTheClipboard() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    let outcome = HardwareReportHandoff.prepare(
      snapshot: snapshot(), pasteboard: pasteboard, openURL: { _ in false })

    #expect(outcome == .browserFailed)
    #expect(pasteboard.string(forType: .string)?.contains("display: Private OLED") == true)
  }
}
