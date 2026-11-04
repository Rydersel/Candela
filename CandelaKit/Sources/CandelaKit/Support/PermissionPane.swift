import Foundation

public enum PermissionPane: Sendable, CaseIterable {
  case accessibility
  case screenRecording

  public var deepLink: URL {
    switch self {
    case .accessibility:
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    case .screenRecording:
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    }
  }

  /// The rename was measured on 27.2 only; treating 27.0 and 27.1 as renamed is an assumption.
  public func paneName(macOSMajor: Int) -> String {
    let renamed = macOSMajor >= 27
    switch self {
    case .accessibility:
      return renamed ? "Device Control and Data Access" : "Accessibility"
    case .screenRecording:
      return renamed ? "Screen & System Audio Recording" : "Screen Recording"
    }
  }

  public func settingsPath(macOSMajor: Int) -> String {
    "System Settings > Privacy & Security > " + paneName(macOSMajor: macOSMajor)
  }

  public static var currentMacOSMajor: Int {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion
  }
}
