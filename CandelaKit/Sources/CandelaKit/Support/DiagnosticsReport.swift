/// Everything the diagnostics report says, gathered by the app before rendering.
///
/// `recentEvents` arrive pre-formatted so the renderer stays pure: one snapshot
/// always renders to the same bytes, which is what makes two pasted reports diffable.
public struct DiagnosticsReportSnapshot: Sendable {
  public struct DisplayEntry: Sendable {
    public let name: String
    public let hardwareName: String
    public let connection: String?
    public let manufacturer: String?
    /// Presence only. The serial is PII and never reaches the report, which gets
    /// pasted into public issues; presence is all twin-display diagnosis needs.
    public let hasSerial: Bool
    public let currentMode: String?
    public let controlMethod: String
    public let readbackVerdict: String
    public let hdrEngaged: Bool
    /// Rendered verbatim; the caller scrubs these, not the renderer. Bare pref
    /// name and value only (`forceSw = true`), never a full storage key: a
    /// persistence key carries the display's serial.
    public let nonDefaultPrefs: [String]

    public init(name: String, hardwareName: String, connection: String?,
                manufacturer: String?, hasSerial: Bool, currentMode: String?,
                controlMethod: String, readbackVerdict: String, hdrEngaged: Bool,
                nonDefaultPrefs: [String]) {
      self.name = name
      self.hardwareName = hardwareName
      self.connection = connection
      self.manufacturer = manufacturer
      self.hasSerial = hasSerial
      self.currentMode = currentMode
      self.controlMethod = controlMethod
      self.readbackVerdict = readbackVerdict
      self.hdrEngaged = hdrEngaged
      self.nonDefaultPrefs = nonDefaultPrefs
    }
  }

  public let appVersion: String
  public let osVersion: String
  public let safeMode: Bool
  public let accessibilityGranted: Bool
  public let launchAtLogin: String
  public let displays: [DisplayEntry]
  /// Newest first, each already carrying its own short timestamp.
  public let recentEvents: [String]

  public init(appVersion: String, osVersion: String, safeMode: Bool,
              accessibilityGranted: Bool, launchAtLogin: String,
              displays: [DisplayEntry], recentEvents: [String]) {
    self.appVersion = appVersion
    self.osVersion = osVersion
    self.safeMode = safeMode
    self.accessibilityGranted = accessibilityGranted
    self.launchAtLogin = launchAtLogin
    self.displays = displays
    self.recentEvents = recentEvents
  }
}

public enum DiagnosticsReport {
  public static func render(_ s: DiagnosticsReportSnapshot) -> String {
    var lines = ["Candela diagnostics report", ""]

    lines += [
      "app: \(s.appVersion)",
      "os: \(s.osVersion)",
      "safe mode: \(s.safeMode ? "on" : "off")",
      "accessibility: \(s.accessibilityGranted ? "granted" : "not granted")",
      "launch at login: \(s.launchAtLogin)",
      "",
    ]

    if s.displays.isEmpty {
      lines += ["displays: none", ""]
    } else {
      lines.append("displays: \(s.displays.count)")
      for display in s.displays {
        lines += ["", "display: \(display.name)"]
        lines += [
          "  hardware name: \(display.hardwareName)",
          "  connection: \(reported(display.connection))",
          "  manufacturer: \(reported(display.manufacturer))",
          "  serial: \(display.hasSerial ? "present" : "none")",
          "  current mode: \(reported(display.currentMode))",
          "  control method: \(display.controlMethod)",
          "  readback: \(display.readbackVerdict)",
          "  hdr: \(display.hdrEngaged ? "engaged" : "off")",
        ]
        if display.nonDefaultPrefs.isEmpty {
          lines.append("  non-default settings: none")
        } else {
          lines.append("  non-default settings:")
          lines += display.nonDefaultPrefs.map { "    \($0)" }
        }
      }
      lines.append("")
    }

    if s.recentEvents.isEmpty {
      lines.append("recent events: none")
    } else {
      lines.append("recent events:")
      lines += s.recentEvents.map { "  \($0)" }
    }

    return lines.joined(separator: "\n") + "\n"
  }

  /// A missing field says so rather than vanishing: an absent line reads as an
  /// absent capability to whoever triages the paste.
  private static func reported(_ value: String?) -> String {
    value ?? "not reported"
  }
}
