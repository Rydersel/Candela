import CandelaKit

/// Permission instructions shared by the surfaces that can start measurement.
enum ScreenRecordingCopy {
  enum Context: CaseIterable {
    case measurement, stalled, healthWithHistory, healthWithoutHistory, staticRegions, setup
  }

  static func message(
    _ context: Context, macOSMajor: Int = PermissionPane.currentMacOSMajor
  ) -> String {
    let path = PermissionPane.screenRecording.settingsPath(macOSMajor: macOSMajor)
    switch context {
    case .measurement:
      return "macOS has not granted Screen Recording, so no readings are being taken. Grant it in \(path)."
    case .stalled:
      return "No reading in over 10 minutes while measurement is on. If this persists, macOS may have dropped the Screen Recording grant after an update to the app; check \(path)."
    case .healthWithHistory:
      return "Measuring is switched on for this display, but macOS has not granted \(AppInfo.productName) Screen Recording, so no new readings are being taken. What is shown below was recorded while the permission was in place. Grant it again in \(path)."
    case .healthWithoutHistory:
      return "Measuring is switched on for this display, but macOS has not granted \(AppInfo.productName) Screen Recording, so no readings are being taken. Grant it in \(path)."
    case .staticRegions:
      return "macOS has not granted Screen Recording, so no static regions are dimmed. Grant it in \(path)."
    case .setup:
      return "Waiting for permission. Drag \(AppInfo.productName) into the list in \(path). Health figures stay estimates until then."
    }
  }
}
