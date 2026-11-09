import CandelaKit
import Testing

@Suite("Screen Recording permission instructions")
struct ScreenRecordingCopyTests {
  @Test(arguments: [14, 15, 26, 27, 28])
  func everyInstructionNamesTheRightSettingsPane(macOSMajor: Int) {
    let path = PermissionPane.screenRecording.settingsPath(macOSMajor: macOSMajor)
    for context in ScreenRecordingCopy.Context.allCases {
      let message = ScreenRecordingCopy.message(context, macOSMajor: macOSMajor)
      #expect(message.contains(path))
      #expect(!message.contains("\u{2014}"))
    }
  }

  @Test func preservedHistoryIsDistinguishedFromNoReadings() {
    #expect(ScreenRecordingCopy.message(.healthWithHistory).contains("recorded while the permission was in place"))
    #expect(!ScreenRecordingCopy.message(.healthWithoutHistory).contains("recorded while the permission was in place"))
    #expect(ScreenRecordingCopy.message(.staticRegions).contains("no static regions are dimmed"))
  }
}
