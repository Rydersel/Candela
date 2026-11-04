import Foundation
import Testing
@testable import CandelaKit

@Suite("Permission pane")
struct PermissionPaneTests {
  @Test func accessibilityNameBy27() {
    #expect(PermissionPane.accessibility.paneName(macOSMajor: 14) == "Accessibility")
    #expect(PermissionPane.accessibility.paneName(macOSMajor: 26) == "Accessibility")
    #expect(PermissionPane.accessibility.paneName(macOSMajor: 27) == "Device Control and Data Access")
  }

  @Test func screenRecordingNameBy27() {
    #expect(PermissionPane.screenRecording.paneName(macOSMajor: 26) == "Screen Recording")
    #expect(PermissionPane.screenRecording.paneName(macOSMajor: 27) == "Screen & System Audio Recording")
  }

  @Test func pathJoinsPrivacyAndSecurity() {
    #expect(PermissionPane.screenRecording.settingsPath(macOSMajor: 27)
      == "System Settings > Privacy & Security > Screen & System Audio Recording")
    #expect(PermissionPane.accessibility.settingsPath(macOSMajor: 26)
      == "System Settings > Privacy & Security > Accessibility")
  }

  @Test func deepLinksAreThePrivacyAnchors() {
    #expect(PermissionPane.accessibility.deepLink.absoluteString.hasSuffix("Privacy_Accessibility"))
    #expect(PermissionPane.screenRecording.deepLink.absoluteString.hasSuffix("Privacy_ScreenCapture"))
  }

  @Test func currentMajorIsPlausible() {
    #expect(PermissionPane.currentMacOSMajor >= 14)
  }
}
