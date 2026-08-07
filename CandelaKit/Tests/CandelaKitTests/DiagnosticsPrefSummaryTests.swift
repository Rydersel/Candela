import Foundation
import Testing
@testable import CandelaKit

/// One persistence-key shape to run the scrub assertions against.
///
/// Both real shapes are exercised. `DisplayDiscovery.persistenceKey(from:)`
/// returns `service.edidUUID` when there is one — the common case, and the one
/// the first version of this suite never tested — and falls back to
/// `name-manufacturer-serial` when there is not.
struct PersistenceKeyShape: Sendable, CustomTestStringConvertible {
  let description: String
  let key: String
  /// Fragments that must not appear in any emitted line, beyond the key itself.
  /// Empty for a shape with no separately-nameable secret inside it.
  let forbiddenFragments: [String]

  var testDescription: String { description }
}

@Suite("Diagnostics non-default pref summary")
struct DiagnosticsPrefSummaryTests {
  private static let serial = "CN0ABCD1234567"

  static let keyShapes: [PersistenceKeyShape] = [
    PersistenceKeyShape(
      description: "EDID UUID",
      key: "4C2D0000-0000-1A2B-3C4D-5E6F70819AB2",
      forbiddenFragments: []
    ),
    PersistenceKeyShape(
      description: "name-manufacturer-serial fallback",
      key: "DELL U2725QE-DEL-\(serial)",
      forbiddenFragments: [serial]
    ),
  ]

  private static let defaultShape = keyShapes[1]

  private func prefs(_ shape: PersistenceKeyShape = defaultShape) -> DisplayPrefs {
    DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: shape.key)
  }

  private func summary(_ prefs: DisplayPrefs, remembersMode: Bool = false) -> [String] {
    DiagnosticsPrefSummary.nonDefaultPrefs(prefs, remembersMode: remembersMode)
  }

  /// Moves EVERY per-display setting the summary reads off its default. Shared
  /// by the scrub test and the coverage test, so the two can never disagree
  /// about what "a fully non-default display" means.
  ///
  /// `rememberDisplayMode` is not a `DisplayPrefs` property — it lives in
  /// `ModePersistence` — so it can only arrive from the caller; every call site
  /// here passes `remembersMode: true` alongside this helper.
  private func moveEverythingOffDefault(_ prefs: DisplayPrefs) {
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
    // Every OLED-care value off its Recommended-preset default (the accessor
    // defaults, pinned by `oledDefaultsAreTheRecommendedPreset`).
    prefs.oledCareEnrolled = true
    prefs.oledIdleDimSeconds = 120
    prefs.oledIdleDimBrightness = 0.8
    prefs.oledLockDim = false
    prefs.oledBlackoutEnabled = true
    prefs.oledBlackoutSeconds = 2400
    prefs.oledUnfocusedDimEnabled = true
    prefs.oledUnfocusedDimSeconds = 900
    prefs.oledUnfocusedDimBrightness = 0.4
    prefs.oledHoursTracking = false
    for command in DDCCommand.allCases {
      prefs.setTuning(
        CommandTuning(
          unavailableDDC: true, minDDCOverride: 10, maxDDCOverride: 90,
          curveIndex: 7, invert: true, remapCodes: [0x1A]
        ),
        for: command
      )
    }
  }

  /// An emitted line's leading name, with any `.command` scope removed, mapped
  /// back to its `PrefName`.
  private func reportedName(in line: String) -> PrefName? {
    guard let head = line.split(separator: " ", maxSplits: 1).first,
          let bare = head.split(separator: ".").first
    else { return nil }
    return PrefName(rawValue: String(bare))
  }

  // MARK: - Coverage

  /// Every `PrefName` this summary is NOT expected to report, each for a stated
  /// reason. Anything else is per-display and must appear.
  ///
  /// This is the list a NEW `PrefName` case forces someone to look at: an
  /// addition lands in neither this set nor the summary, and the test below
  /// fails until it is classified deliberately.
  private static let notReportedPerDisplay: Set<PrefName> = [
    // App-level: one value for the whole app, not a fact about a display.
    .menuIcon, .hideBuiltInDisplay, .showContrast,
    .enableSliderSnap, .enableSliderPercent,
    .disableCombinedBrightness, .allowZeroSwBrightness, .enableBrightnessSync, .startupAction,
    .separateCombinedScale,
    .keyboardBrightness, .keyboardVolume, .disableAltBrightnessKeys,
    .multiKeyboardBrightness, .multiKeyboardVolume,
    .useFineScaleBrightness, .useFineScaleVolume,
    // App-level, and about a display SET rather than a display.
    .restoreArrangement, .savedArrangements,
    // Per-display, deliberately not summarised: it is the pinned mode
    // descriptor, and `rememberDisplayMode = true` already reports that a pin
    // is in force. The descriptor belongs in the report's `current mode` line,
    // not in a list of settings.
    .storedDisplayMode,
  ]

  /// Closes the gap this suite's comments used to CLAIM was closed. A fixture
  /// that only sets the prefs someone remembered to add covers exactly what it
  /// covers, and nothing made a new pref appear in it. Driving both sides off
  /// `PrefName.allCases` is what makes the claim true:
  ///
  /// - a new per-display `PrefName` the summary ignores → missing from
  ///   `emitted` → fails;
  /// - a pref the summary reports but this fixture never sets → missing from
  ///   `emitted` → fails;
  /// - a new app-level `PrefName` → absent from the exclusion set → fails,
  ///   until someone classifies it.
  ///
  /// All three were verified by construction, not by argument: a temporary
  /// `PrefName` case reported `unreported: ["futurePerDisplayThing"]`, and
  /// deleting one line from the fixture reported `unreported: ["hideOsd"]`.
  @Test func theFixtureCoversEveryPerDisplayPrefName() {
    let prefs = prefs()
    moveEverythingOffDefault(prefs)

    let emitted = Set(summary(prefs, remembersMode: true).compactMap(reportedName))
    let expected = Set(PrefName.allCases).subtracting(Self.notReportedPerDisplay)

    #expect(
      emitted == expected,
      """
      unreported: \(expected.subtracting(emitted).map(\.rawValue).sorted()); \
      unexpected: \(emitted.subtracting(expected).map(\.rawValue).sorted())
      """
    )
  }

  /// Every emitted line parses back to a known `PrefName`. Without this, a
  /// typo'd or hand-composed name would simply vanish from the coverage set
  /// above, taking the evidence of its own absence with it.
  @Test func everyEmittedLineNamesAKnownPref() {
    let prefs = prefs()
    moveEverythingOffDefault(prefs)
    for line in summary(prefs, remembersMode: true) {
      #expect(reportedName(in: line) != nil, "unparseable summary line: \(line)")
    }
  }

  // MARK: - The PII contract

  /// THE PII CONTRACT. `DisplayPrefs` stores under `"<name>.<persistenceKey>"`
  /// and a persistence key is an EDID UUID or `name-manufacturer-serial`, so a
  /// summary that named its settings by their real storage keys would put the
  /// display's identity into every report — straight past the `hasSerial` flag
  /// that exists to keep it out of public issues.
  ///
  /// Asserted over EVERY emitted line, against the fully-non-default fixture
  /// whose completeness the coverage test above enforces, and against BOTH real
  /// key shapes.
  @Test(arguments: DiagnosticsPrefSummaryTests.keyShapes)
  func noEmittedLineCarriesAComposedStorageKey(shape: PersistenceKeyShape) {
    let prefs = prefs(shape)
    moveEverythingOffDefault(prefs)

    let lines = summary(prefs, remembersMode: true)
    #expect(!lines.isEmpty, "a fixture that produced nothing could not fail this test")

    // The composed key's tell, DERIVED from the fixture rather than spelled
    // out: every stored key ends `.<persistenceKey>`, and no bare pref name
    // may. A hardcoded `".DELL"` would have silently matched nothing the day
    // the fixture's key changed shape — which is precisely what adding the
    // EDID-UUID shape above would have done to it.
    let composedTell = "." + shape.key.prefix(4)

    for line in lines {
      #expect(!line.contains(shape.key), "leaked the persistence key: \(line)")
      #expect(!line.contains(composedTell), "leaked a composed storage key: \(line)")
      for fragment in shape.forbiddenFragments {
        #expect(!line.contains(fragment), "leaked \(fragment): \(line)")
      }
    }
  }

  // MARK: - Format

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
    // `rememberDisplayMode` can only arrive from the caller. Pinned so a
    // refactor that drops the parameter is a failing test rather than a
    // silently shorter report.
    #expect(lines.contains("rememberDisplayMode = true"))
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

    #expect(summary(prefs) == ["unavailableDDC.volume = true"])
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
