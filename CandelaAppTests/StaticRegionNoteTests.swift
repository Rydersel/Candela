import CandelaKit
import Testing

@Suite("Static-region dimming note") @MainActor
struct StaticRegionNoteTests {
  private static func note(
    on: Bool = true, telemetry: Bool = true, windowObservation: Bool = true,
    granted: Bool = true, heldAwake: Bool = false, safeMode: Bool = false
  ) -> OledCareDisplayPage.DetectionNote? {
    OledCareDisplayPage.detectionNote(
      detectionDimming: on, telemetry: telemetry, windowObservation: windowObservation,
      screenRecordingGranted: granted, assertionHeld: heldAwake, safeMode: safeMode)
  }

  private static func gap(_ note: OledCareDisplayPage.DetectionNote?) -> OledCareDisplayPage.MeasurementGap? {
    if case let .measurementOff(gap) = note { return gap }
    return nil
  }

  @Test func withBothMeasurementsOnThereIsNoNote() {
    #expect(Self.note() == nil)
  }

  @Test func aSwitchThatIsOffNeverShowsANote() {
    #expect(Self.note(on: false, telemetry: false, windowObservation: false) == nil)
    #expect(Self.note(on: false, telemetry: false) == nil)
    #expect(Self.note(on: false, windowObservation: false) == nil)
    #expect(Self.note(on: false, heldAwake: true) == nil)
    #expect(Self.note(on: false, granted: false) == nil)
    #expect(Self.note(on: false, safeMode: true) == nil)
  }

  @Test func bothOffNamesBothAndTurnsBothOn() throws {
    let gap = try #require(Self.gap(Self.note(telemetry: false, windowObservation: false)))
    #expect(gap.turnsOnTelemetry)
    #expect(gap.turnsOnWindowObservation)
    #expect(gap.prefNames == [.oledTelemetry, .oledWindowObservation])
    #expect(gap.message.contains("measuring brightness"))
    #expect(gap.message.contains("noting which apps"))
    #expect(gap.buttonTitle == "Turn Both On")
  }

  @Test func onlyMeasurementOffNamesMeasurementAlone() throws {
    let gap = try #require(Self.gap(Self.note(telemetry: false)))
    #expect(gap.turnsOnTelemetry)
    #expect(!gap.turnsOnWindowObservation)
    #expect(gap.prefNames == [.oledTelemetry])
    #expect(gap.message.contains("measuring brightness"))
    #expect(!gap.message.contains("noting which apps"))
  }

  @Test func onlyWindowObservationOffNamesItAlone() throws {
    let gap = try #require(Self.gap(Self.note(windowObservation: false)))
    #expect(!gap.turnsOnTelemetry)
    #expect(gap.turnsOnWindowObservation)
    #expect(gap.prefNames == [.oledWindowObservation])
    #expect(gap.message.contains("noting which apps"))
    #expect(!gap.message.contains("measuring brightness"))
  }

  @Test func thePermissionSentenceAppearsOnlyWhenTheButtonCanAsk() throws {
    let asks = try #require(Self.gap(Self.note(telemetry: false, granted: false)))
    #expect(asks.message.contains("Screen Recording"))

    let bothAsk = try #require(Self.gap(Self.note(telemetry: false, windowObservation: false, granted: false)))
    #expect(bothAsk.message.hasSuffix(
      "Measuring brightness needs Screen Recording, so System Settings opens to help you grant it. Nothing is recorded or stored as an image, and nothing leaves this Mac."))

    let alreadyGranted = try #require(Self.gap(Self.note(telemetry: false, granted: true)))
    #expect(!alreadyGranted.message.contains("Screen Recording"))

    // Window observation needs no permission.
    let noPermission = try #require(Self.gap(Self.note(windowObservation: false, granted: false)))
    #expect(!noPermission.message.contains("Screen Recording"))
  }

  /// Ending the assertion would not start dimming while a measurement is off.
  @Test func aMissingMeasurementOutranksTheHeldAwakeNote() {
    #expect(Self.gap(Self.note(telemetry: false, heldAwake: true)) != nil)
    #expect(Self.note(heldAwake: true) == .heldAwake)
  }

  /// The sampler is preflight-only, so without the grant nothing is ever dimmed.
  /// A dialog dismissed after the button click lands here.
  @Test func bothOnWithoutTheGrantSaysNothingIsDimmed() {
    #expect(Self.note(granted: false) == .screenRecordingMissing)
    #expect(OledCareDisplayPage.screenRecordingMissingText.contains(
      PermissionPane.screenRecording.settingsPath(macOSMajor: PermissionPane.currentMacOSMajor)))
    #expect(OledCareDisplayPage.screenRecordingMissingText.contains("no static regions are dimmed"))
  }

  /// Granting would not end the silence while a setting is still off, and
  /// ending the assertion would not end it without the grant.
  @Test func theGrantNoteSitsBetweenAMissingSettingAndTheHeldAwakeNote() {
    #expect(Self.gap(Self.note(windowObservation: false, granted: false)) != nil)
    #expect(Self.note(granted: false, heldAwake: true) == .screenRecordingMissing)
  }

  /// The care loop never runs in Safe Mode, so no other reason applies.
  @Test func safeModeOutranksEveryOtherNote() {
    #expect(Self.note(safeMode: true) == .safeMode)
    #expect(Self.note(telemetry: false, windowObservation: false, granted: false, safeMode: true) == .safeMode)
    #expect(Self.note(granted: false, heldAwake: true, safeMode: true) == .safeMode)
    #expect(OledCareDisplayPage.safeModeNoteText.hasPrefix("Safe Mode is on for this session"))
  }

  /// Voice Control activates a button by what it shows, so the spoken label
  /// has to start with the visible title.
  @Test func everyButtonLabelStartsWithItsVisibleTitle() throws {
    for (telemetry, windowObservation) in [(false, false), (false, true), (true, false)] {
      let gap = try #require(Self.gap(Self.note(telemetry: telemetry, windowObservation: windowObservation)))
      #expect(gap.accessibilityLabel.lowercased().hasPrefix(gap.buttonTitle.lowercased()))
    }
  }

  @Test func noCopyCarriesAnEmDash() throws {
    let cases: [(Bool, Bool, Bool)] = [
      (false, false, false), (false, true, false), (true, false, false), (false, false, true),
    ]
    for (telemetry, windowObservation, granted) in cases {
      let gap = try #require(Self.gap(Self.note(
        telemetry: telemetry, windowObservation: windowObservation, granted: granted)))
      for text in [gap.message, gap.buttonTitle, gap.accessibilityLabel] {
        #expect(!text.contains("\u{2014}"))
      }
    }
    #expect(!OledCareDisplayPage.safeModeNoteText.contains("\u{2014}"))
    #expect(!OledCareDisplayPage.screenRecordingMissingText.contains("\u{2014}"))
  }
}
