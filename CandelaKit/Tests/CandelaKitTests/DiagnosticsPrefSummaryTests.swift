import Foundation
import Testing
@testable import CandelaKit

@Suite("Diagnostics non-default pref summary")
struct DiagnosticsPrefSummaryTests {
  /// The shape `DisplayDiscovery.persistenceKey(from:)` falls back to when a
  /// display reports no EDID UUID: `name-manufacturer-serial`. The serial is
  /// spelled out as its own constant so the scrub test can look for it
  /// independently of the whole key.
  private static let serial = "CN0ABCD1234567"
  private static let persistenceKey = "DELL U2725QE-DEL-\(serial)"

  private func prefs() -> DisplayPrefs {
    DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: Self.persistenceKey)
  }

  private func summary(_ prefs: DisplayPrefs, remembersMode: Bool = false) -> [String] {
    DiagnosticsPrefSummary.nonDefaultPrefs(prefs, remembersMode: remembersMode)
  }

  @Test func anUntouchedDisplayReportsNothing() {
    #expect(summary(prefs()).isEmpty)
  }

  @Test func namesEachSettingByItsBarePrefName() {
    let prefs = prefs()
    prefs.friendlyName = "Left"
    prefs.forceSoftware = true
    prefs.combinedSwitchingPoint = 3
    prefs.audioSinkOverride = .forceNone
    prefs.pollingCount = 4

    let lines = summary(prefs, remembersMode: true)
    #expect(lines.contains("friendlyName = Left"))
    #expect(lines.contains("forceSw = true"))
    #expect(lines.contains("combinedSwitchingPoint = 3"))
    #expect(lines.contains("audioSinkOverride = forceNone"))
    #expect(lines.contains("pollingCount = 4"))
    // `rememberDisplayMode` lives in `ModePersistence`, not in `DisplayPrefs`,
    // so it can only arrive from the caller. Pinned so a refactor that drops
    // the parameter is a failing test rather than a silently shorter report.
    #expect(lines.contains("rememberDisplayMode = true"))
  }

  /// THE PII CONTRACT. `DisplayPrefs` stores under `"<name>.<persistenceKey>"`
  /// and a persistence key is an EDID UUID or `name-manufacturer-serial`, so a
  /// summary that named its settings by their real storage keys would put the
  /// display's serial into every report — straight past the `hasSerial` flag
  /// that exists to keep it out of public issues.
  ///
  /// Asserted over EVERY emitted line rather than over a known set, so a new
  /// setting added to the summary is covered the day it is added.
  @Test func noEmittedLineCarriesAComposedStorageKey() {
    let prefs = prefs()
    prefs.friendlyName = "Left"
    prefs.hideDisplay = true
    prefs.isDisabled = true
    prefs.hideVolumeSlider = true
    prefs.hideOsd = true
    prefs.forceSoftware = true
    prefs.avoidGamma = true
    prefs.combinedSwitchingPoint = 3
    prefs.enableMuteUnmute = true
    prefs.audioSinkOverride = .forcePresent
    prefs.audioDeviceNameOverride = "Dell Speakers"
    prefs.pollingMode = .heavy
    prefs.pollingCount = 4
    for command in DDCCommand.allCases {
      prefs.setTuning(
        CommandTuning(
          unavailableDDC: true, minDDCOverride: 10, maxDDCOverride: 90,
          curveIndex: 7, invert: true, remapCodes: [0x1A]
        ),
        for: command
      )
    }

    let lines = summary(prefs, remembersMode: true)
    #expect(!lines.isEmpty, "a fixture that produced nothing could not fail this test")
    for line in lines {
      #expect(!line.contains(Self.persistenceKey), "leaked the persistence key: \(line)")
      #expect(!line.contains(Self.serial), "leaked the serial number: \(line)")
      // The composed key's shape, independent of this fixture's key: every
      // stored key ends `.<persistenceKey>`, and no bare name may.
      #expect(!line.contains(".DELL"), "leaked a composed storage key: \(line)")
    }
  }

  /// The command is SCOPE, not identity — three commands share one pref name,
  /// and dropping the middle component would print three different settings as
  /// one. It is also the one part of a storage key that is safe to keep: it is
  /// a fixed vocabulary, not display-derived.
  @Test func perCommandTuningNamesItsCommandAndNotItsDisplay() {
    let prefs = prefs()
    var tuning = CommandTuning.unset
    tuning.unavailableDDC = true
    prefs.setTuning(tuning, for: .volume)

    let lines = summary(prefs)
    #expect(lines == ["unavailableDDC.volume = true"])
  }

  /// `DimmingMath.curveMultiplier` treats 0 (unset) and 5 alike, so neither is
  /// a departure from the default. Reporting 5 as an override would send every
  /// reader of the report hunting a response curve nobody set.
  @Test func aLinearCurveIsNotAnOverrideAtEitherSpelling() {
    for index in [0, 5] {
      let prefs = prefs()
      var tuning = CommandTuning.unset
      tuning.curveIndex = index
      prefs.setTuning(tuning, for: .brightness)
      #expect(summary(prefs).isEmpty, "curveIndex \(index) reported as an override")
    }
  }

  /// Same rule the panel title uses (`DisplayCardPolicy.normalizedFriendlyName`):
  /// a field the user cleared to spaces is unset, and reporting `friendlyName =
  /// "   "` would describe a rename that is not in effect.
  @Test func aWhitespaceOnlyNameIsNotAReportedSetting() {
    let prefs = prefs()
    prefs.friendlyName = "   "
    #expect(summary(prefs).isEmpty)
  }

  @Test func remapCodesRenderAsHexRatherThanDecimal() {
    let prefs = prefs()
    var tuning = CommandTuning.unset
    tuning.remapCodes = [0x1A, 0x0B]
    prefs.setTuning(tuning, for: .contrast)
    #expect(summary(prefs) == ["remapDDC.contrast = 1a, 0b"])
  }
}
