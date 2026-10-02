import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

/// A prefs domain a test can write to and hand back to a derivation, which the
/// per-call `TestFixtures.prefs` suite cannot do: the factory has to answer
/// from the same storage the test seeded.
private struct PrefsDomain {
  let defaults = InMemoryDefaults()

  func prefs(_ persistenceKey: String) -> DisplayPrefs {
    DisplayPrefs(defaults: defaults, persistenceKey: persistenceKey)
  }

  func edit(_ persistenceKey: String, _ change: (inout DisplayPrefs) -> Void) {
    var prefs = prefs(persistenceKey)
    change(&prefs)
  }
}

@Suite("Panel row model")
@MainActor
struct PanelRowModelTests {
  private static func state(
    id: CGDirectDisplayID, name: String, key: String
  ) -> AppModel.DisplayState {
    TestFixtures.displayState(id: id, name: name, persistenceKey: key)
  }

  // MARK: - visibleDisplays

  @Test func externalsSortAscendingByNameTheWayTheFinderOrdersThem() {
    let domain = PrefsDomain()
    let states = [
      Self.state(id: 1, name: "Display 10", key: "ten"),
      Self.state(id: 2, name: "Zed", key: "zed"),
      Self.state(id: 3, name: "Display 2", key: "two"),
      Self.state(id: 4, name: "Alpha", key: "alpha"),
    ]
    let visible = PanelView.visibleDisplays(states, prefs: domain.prefs)
    #expect(visible.map(\.display.name) == ["Alpha", "Display 2", "Display 10", "Zed"])
  }

  @Test func theFriendlyNameIsWhatTheOrderSortsOn() {
    let domain = PrefsDomain()
    domain.edit("zed") { $0.friendlyName = "Aardvark" }
    let states = [
      Self.state(id: 1, name: "Zed", key: "zed"),
      Self.state(id: 2, name: "Beta", key: "beta"),
    ]
    let visible = PanelView.visibleDisplays(states, prefs: domain.prefs)
    #expect(visible.map(\.display.persistenceKey) == ["zed", "beta"])
  }

  @Test func aHiddenDisplayDropsOutAndTheRestKeepTheirOrder() {
    let domain = PrefsDomain()
    domain.edit("beta") { $0.hideDisplay = true }
    let states = [
      Self.state(id: 1, name: "Gamma", key: "gamma"),
      Self.state(id: 2, name: "Beta", key: "beta"),
      Self.state(id: 3, name: "Alpha", key: "alpha"),
    ]
    let visible = PanelView.visibleDisplays(states, prefs: domain.prefs)
    #expect(visible.map(\.display.name) == ["Alpha", "Gamma"])
  }

  @Test func hidingEveryDisplayLeavesNoRows() {
    let domain = PrefsDomain()
    for key in ["a", "b"] { domain.edit(key) { $0.hideDisplay = true } }
    let states = [
      Self.state(id: 1, name: "A", key: "a"),
      Self.state(id: 2, name: "B", key: "b"),
    ]
    #expect(PanelView.visibleDisplays(states, prefs: domain.prefs).isEmpty)
  }

  @Test func identicallyNamedPanelsKeepDiscoveryOrder() {
    // Two of the same model: no reshuffle between refreshes.
    let domain = PrefsDomain()
    let states = [
      Self.state(id: 9, name: "MAG 341C", key: "second"),
      Self.state(id: 4, name: "MAG 341C", key: "first"),
    ]
    let visible = PanelView.visibleDisplays(states, prefs: domain.prefs)
    #expect(visible.map(\.display.persistenceKey) == ["second", "first"])
  }

  @Test func anEmptyListRendersNoRows() {
    #expect(PanelView.visibleDisplays([], prefs: PrefsDomain().prefs).isEmpty)
  }

  @Test func theModelFormAsksOnlyTheExternalSlot() {
    // The built-in lives in its own slot, so a model with no externals renders
    // no external rows whatever the built-in is doing.
    let model = TestFixtures.appModel()
    #expect(PanelView.visibleDisplays(model).isEmpty)
    #expect(PanelView.showsBuiltIn(model) == false)
  }

  // MARK: - showsBuiltIn

  @Test func theBuiltInSectionNeedsABuiltInAndTheAppPref() {
    let domain = PrefsDomain()
    #expect(PanelView.showsBuiltIn(hasBuiltIn: true, appPrefs: domain.prefs("app")))
    #expect(PanelView.showsBuiltIn(hasBuiltIn: false, appPrefs: domain.prefs("app")) == false)
  }

  @Test func hideBuiltInDisplayRemovesTheSectionWithABuiltInAttached() {
    let domain = PrefsDomain()
    domain.edit("app") { $0.hideBuiltInDisplay = true }
    #expect(PanelView.showsBuiltIn(hasBuiltIn: true, appPrefs: domain.prefs("app")) == false)
  }

  // MARK: - title

  @Test func aRenamedDisplayShowsItsFriendlyName() {
    let domain = PrefsDomain()
    domain.edit("mag") { $0.friendlyName = "Ultrawide" }
    let display = ExternalDisplay(id: 1, name: "MAG 341C", persistenceKey: "mag")
    #expect(PanelView.title(for: display, prefs: domain.prefs) == "Ultrawide")
  }

  @Test func anUnsetOrClearedFriendlyNameFallsBackToTheHardwareName() {
    let domain = PrefsDomain()
    domain.edit("cleared") { $0.friendlyName = "   " }
    let cleared = ExternalDisplay(id: 1, name: "DELL U2725QE", persistenceKey: "cleared")
    let untouched = ExternalDisplay(id: 2, name: "MAG 341C", persistenceKey: "untouched")
    #expect(PanelView.title(for: cleared, prefs: domain.prefs) == "DELL U2725QE")
    #expect(PanelView.title(for: untouched, prefs: domain.prefs) == "MAG 341C")
  }

  // MARK: - Volume slider visibility

  @Test func theVolumeRowRendersForAnAvailableCommandThatIsNotHidden() {
    let domain = PrefsDomain()
    let state = Self.state(id: 1, name: "MAG 341C", key: "mag")
    #expect(PanelView.showsVolumeSlider(for: state, prefs: domain.prefs("mag")))
  }

  @Test func hideVolumeSliderRemovesTheRow() {
    let domain = PrefsDomain()
    domain.edit("mag") { $0.hideVolumeSlider = true }
    let state = Self.state(id: 1, name: "MAG 341C", key: "mag")
    #expect(PanelView.showsVolumeSlider(for: state, prefs: domain.prefs("mag")) == false)
  }

  @Test func anUnavailableVolumeCommandRemovesTheRow() {
    // unavailableDDC or forceSoftware, both through DDCValueController.
    #expect(
      PanelView.showsVolumeSlider(commandIsAvailable: false, hideVolumeSlider: false) == false)
    #expect(
      PanelView.showsVolumeSlider(commandIsAvailable: false, hideVolumeSlider: true) == false)
    #expect(PanelView.showsVolumeSlider(commandIsAvailable: true, hideVolumeSlider: false))
  }

  // MARK: - The volume capability verdict

  @Test func aCleanCapabilitiesStringWithoutVCP62GreysTheSlider() {
    // The Dell's shape: parsed end to end, and 62 is not in the list.
    let deniesVolume = "(prot(monitor)type(lcd)vcp(02 10 12 60(01 03) 8D)mccs_ver(2.1))"
    let verdict = CapabilityString.support(forVCP: 0x62, in: deniesVolume)
    #expect(verdict == .unsupported)
    #expect(VolumeSliderPolicy.isEnabled(override: .auto, volumeSupport: verdict) == false)
  }

  @Test func anUnknownVerdictLeavesTheSliderEnabled() {
    // The MAG answers no read at all, and a truncated answer is not a denial.
    let truncated = "(prot(monitor)type(lcd)vcp(02 04 05 08 10 12 14(05"
    #expect(CapabilityString.support(forVCP: 0x62, in: truncated) == .unknown)
    #expect(VolumeSliderPolicy.isEnabled(override: .auto, volumeSupport: .unknown))
    #expect(VolumeSliderPolicy.isEnabled(override: .auto, volumeSupport: .supported))
  }

  @Test func anUnprobedDisplayIsEnabledBeforeAnyDDCHappens() {
    // The verdict lands seconds after the display appears; an absent entry must
    // not grey the row in the meantime.
    let model = TestFixtures.appModel()
    let state = Self.state(id: 1, name: "MAG 341C", key: "unprobed")
    #expect(model.volumeSupport["unprobed"] == nil)
    #expect(model.volumeSliderEnabled(state))
  }

  @Test func aDeniedRegisterGreysTheRowRatherThanRemovingIt() {
    // Visibility and enablement are separate questions: the denial disables,
    // the per-display hide removes.
    let domain = PrefsDomain()
    let state = Self.state(id: 1, name: "DELL U2725QE", key: "dell")
    #expect(PanelView.showsVolumeSlider(for: state, prefs: domain.prefs("dell")))
    #expect(VolumeSliderPolicy.isEnabled(override: .auto, volumeSupport: .unsupported) == false)
  }

  @Test func theOverrideOutranksTheMonitorsOwnVerdictInBothDirections() {
    #expect(VolumeSliderPolicy.isEnabled(override: .forcePresent, volumeSupport: .unsupported))
    #expect(
      VolumeSliderPolicy.isEnabled(override: .forceNone, volumeSupport: .supported) == false)
  }

  // MARK: - Contrast slider visibility

  @Test func theContrastRowIsOffUntilTheAppPrefTurnsItOn() {
    let domain = PrefsDomain()
    let state = Self.state(id: 1, name: "MAG 341C", key: "mag")
    #expect(PanelView.showsContrastSlider(for: state, prefs: domain.prefs("mag")) == false)
    domain.edit("mag") { $0.showContrast = true }
    #expect(PanelView.showsContrastSlider(for: state, prefs: domain.prefs("mag")))
  }

  @Test func theContrastPrefIsAppLevelSoAnyDisplaysPrefsAnswerForIt() {
    // showContrast is stored unkeyed: setting it through one display's prefs
    // shows the row on every display in the same domain.
    let domain = PrefsDomain()
    domain.edit("mag") { $0.showContrast = true }
    let dell = Self.state(id: 2, name: "DELL U2725QE", key: "dell")
    #expect(PanelView.showsContrastSlider(for: dell, prefs: domain.prefs("dell")))
  }

  @Test func anUnavailableContrastCommandRemovesTheRowEvenWithThePrefOn() {
    #expect(PanelView.showsContrastSlider(commandIsAvailable: false, showContrast: true) == false)
    #expect(PanelView.showsContrastSlider(commandIsAvailable: true, showContrast: false) == false)
    #expect(PanelView.showsContrastSlider(commandIsAvailable: true, showContrast: true))
  }

  // MARK: - Keep awake row visibility

  @Test func theKeepAwakeRowShowsUnlessTheMenuBarPrefHidesIt() {
    let domain = PrefsDomain()
    #expect(PanelView.showsKeepAwake(appPrefs: domain.prefs("app")))

    domain.edit("app") { $0.hideKeepAwake = true }

    #expect(PanelView.showsKeepAwake(appPrefs: domain.prefs("app")) == false)
  }

  // MARK: - Through the model, not beside it

  /// Everything above hands the derivation an array the test built. These drive
  /// a real refresh instead, so the states carry controllers the model itself
  /// constructed and reconciled.
  ///
  /// This one is the production call: `visibleDisplays(model)` reads the app's
  /// own prefs domain, so the keys are ones no real display has and no test
  /// writes to, and the assertion is about membership and order.
  @Test func theModelsOwnDisplayListIsWhatThePanelOrders() async {
    let discovery = ScriptedDiscovery([
      (id: 2, key: "row-model-zed", name: "Zed"),
      (id: 3, key: "row-model-alpha", name: "Alpha"),
    ])
    let model = TestFixtures.appModel(discovery: discovery)
    await model.refresh()

    let visible = PanelView.visibleDisplays(model)
    #expect(visible.map(\.display.name) == ["Alpha", "Zed"])
  }

  /// The built-in occupies its own slot and must never arrive in the external
  /// list the panel orders. Stated as an absence rather than a count, because
  /// `refreshBuiltIn` reads `BuiltInDisplayDiscovery` directly: a count would
  /// pass on a laptop and fail on a headless runner, or the reverse.
  @Test func theBuiltInSlotNeverLeaksIntoThePanelsExternalRows() async {
    let discovery = ScriptedDiscovery([(id: 2, key: "row-model-only", name: "Only External")])
    let model = TestFixtures.appModel(discovery: discovery)
    await model.refresh()

    #expect(model.displays.map(\.display.persistenceKey) == ["row-model-only"])
    #expect(PanelView.visibleDisplays(model).contains { $0.display.persistenceKey == "builtIn" } == false)
  }

  /// A departure reaches the rows. Not reachable beside the model: the input
  /// array is whatever the test passes, so dropping an element proves only that
  /// the test dropped an element. Here the topology changes and the model's own
  /// reconciliation is what removes the row.
  @Test func aDepartedDisplayLeavesThePanelsRowsAndTheSurvivorKeepsItsController() async {
    let discovery = ScriptedDiscovery([
      (id: 2, key: "row-model-stays", name: "Stays"),
      (id: 3, key: "row-model-goes", name: "Goes"),
    ])
    let model = TestFixtures.appModel(discovery: discovery)
    await model.refresh()
    #expect(PanelView.visibleDisplays(model).count == 2)
    let survivor = model.displays.first { $0.display.persistenceKey == "row-model-stays" }?.controller

    discovery.topology = [(id: 2, key: "row-model-stays", name: "Stays")]
    await model.refresh()

    let visible = PanelView.visibleDisplays(model)
    #expect(visible.map(\.display.persistenceKey) == ["row-model-stays"])
    // The survivor is the SAME row, not a rebuilt one: a refresh that rebuilt
    // everything would also pass the membership check above.
    #expect(survivor != nil)
    #expect(visible.first?.controller === survivor)
  }

  /// Hiding runs off prefs, so this drives the model for its states and an
  /// isolated domain for the answer: the production `visibleDisplays(model)`
  /// reads the app's real domain, and a test may not write `hideDisplay` there.
  @Test func hidingADisplayRemovesTheRowTheModelProduced() async {
    let discovery = ScriptedDiscovery([
      (id: 2, key: "row-model-shown", name: "Shown"),
      (id: 3, key: "row-model-hidden", name: "Hidden"),
    ])
    let model = TestFixtures.appModel(discovery: discovery)
    await model.refresh()
    let domain = PrefsDomain()
    #expect(PanelView.visibleDisplays(model.displays, prefs: domain.prefs).count == 2)

    domain.edit("row-model-hidden") { $0.hideDisplay = true }

    let visible = PanelView.visibleDisplays(model.displays, prefs: domain.prefs)
    #expect(visible.map(\.display.persistenceKey) == ["row-model-shown"])
  }

  // MARK: - The HDR button's refusal

  @Test func theHDRButtonExplainsItselfWhileASynthesizedSizeIsShowing() {
    let reason = PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: true, isHDREngaged: false,
      supportsHDR: true, capabilityProbed: true
    )
    #expect(reason == SynthesisCopy.hdrBlockedBySynthesizedSize)
  }

  @Test func theHDRButtonIsUnrefusedWithNoSizeEngaged() {
    #expect(PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: false, isHDREngaged: false,
      supportsHDR: true, capabilityProbed: true
    ) == nil)
    #expect(PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: false, isHDREngaged: true,
      supportsHDR: true, capabilityProbed: true
    ) == nil)
  }

  /// The exit direction is never refused, so the one control that can take a
  /// display out of the HDR-over-a-size combination is never the greyed one.
  @Test func theHDRExitIsOfferedEvenWithASizeEngaged() {
    #expect(PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: true, isHDREngaged: true,
      supportsHDR: true, capabilityProbed: true
    ) == nil)
  }

  /// The panel's own sentence, not the diagnostics row's, which is written to be
  /// read with the two causes that follow it there.
  @Test func theHDRButtonExplainsItselfOnADisplayThatReportsNoHDRModes() {
    #expect(PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: false, isHDREngaged: false,
      supportsHDR: false, capabilityProbed: true
    ) == PanelView.hdrNoModesCaption)
  }

  /// The libel case: `supportsHDR` reads false before the async capability refresh
  /// answers, so an unprobed display must say nothing rather than say no.
  @Test func theHDRButtonSaysNothingBeforeTheCapabilityRefreshLands() {
    #expect(PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: false, isHDREngaged: false,
      supportsHDR: false, capabilityProbed: false
    ) == nil)
  }

  /// A size engaged on a display with no HDR modes: dropping the size would not
  /// bring HDR, so the caption names the capability rather than the size.
  @Test func theCapabilityRefusalOutranksTheSizeRefusal() {
    #expect(PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: true, isHDREngaged: false,
      supportsHDR: false, capabilityProbed: true
    ) == PanelView.hdrNoModesCaption)
  }

  /// HDR live on a display whose last probe said it has none: the exit stays
  /// offered and unexplained, the recovery-control rule the engaged guard exists for.
  @Test func theHDRExitIsOfferedEvenWhenTheProbeSaysNoHDR() {
    #expect(PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: false, isHDREngaged: true,
      supportsHDR: false, capabilityProbed: true
    ) == nil)
  }

  /// Greying and caption move together: grey and silent before the probe lands,
  /// grey and captioned after a no, live after a yes.
  @Test func theHDRButtonGreysUntilTheProbeAnswersAndThenAgreesWithItsCaption() {
    func enabled(supportsHDR: Bool, probed: Bool) -> Bool {
      PanelView.hdrButtonIsEnabled(
        isHDREngaged: false, capabilityProbed: probed, supportsHDR: supportsHDR,
        refusalReason: PanelView.hdrRefusalReason(
          isShowingSynthesizedSize: false, isHDREngaged: false,
          supportsHDR: supportsHDR, capabilityProbed: probed
        )
      )
    }
    // Unprobed, either reading of a cache nothing has filled for this panel yet.
    #expect(!enabled(supportsHDR: false, probed: false))
    #expect(!enabled(supportsHDR: true, probed: false))
    #expect(!enabled(supportsHDR: false, probed: true))
    #expect(enabled(supportsHDR: true, probed: true))
  }

  /// A refusal greys the button even where the capability is there, which is how
  /// the synthesized-size caption gets a control to sit under.
  @Test func aRefusalGreysAnOtherwiseCapableHDRButton() {
    #expect(!PanelView.hdrButtonIsEnabled(
      isHDREngaged: false, capabilityProbed: true, supportsHDR: true,
      refusalReason: SynthesisCopy.hdrBlockedBySynthesizedSize
    ))
  }

  /// With HDR live this button is the only way out. A panel swap drops the probe
  /// flag while the engaged cache still reads true, which used to grey the exit.
  @Test func theHDRExitStaysLiveEvenWhileTheProbeIsOutstanding() {
    for probed in [false, true] {
      for supportsHDR in [false, true] {
        #expect(PanelView.hdrButtonIsEnabled(
          isHDREngaged: true, capabilityProbed: probed, supportsHDR: supportsHDR,
          refusalReason: PanelView.hdrRefusalReason(
            isShowingSynthesizedSize: true, isHDREngaged: true,
            supportsHDR: supportsHDR, capabilityProbed: probed
          )
        ))
      }
    }
  }

  /// Says what was looked for and not found, never that the app does not know.
  @Test func theNoHDRCaptionNamesTheObservationRatherThanTheAppsIgnorance() {
    #expect(PanelView.hdrNoModesCaption == "No HDR modes were found for this display.")
    #expect(PanelView.hdrNoModesCaption != DiagnosticsCopy.hdrNoAnswer(app: AppInfo.productName))
  }

  /// The sentence is the mirror of the synthesized-size refusal, and it names
  /// neither the mechanism nor a display: the panel row it sits under has the
  /// name.
  @Test func theRefusalNamesTheMoveThatClearsIt() {
    let copy = SynthesisCopy.hdrBlockedBySynthesizedSize
    #expect(copy.contains("HDR"))
    #expect(copy.contains(AppInfo.productName))
    #expect(!copy.contains("—"))
  }

  // MARK: - The care line

  /// The keys here are ones no real display has and no test writes hours to, so
  /// the tracker answers zero.
  @Test func anUnenrolledDisplayWithNoHoursHasNoCareLine() {
    let domain = PrefsDomain()
    let model = TestFixtures.appModel()
    let line = PanelView.careLine(
      persistenceKey: "row-model-plain", prefs: domain.prefs("row-model-plain"),
      care: model.oledCare, safeMode: model.isSafeMode)
    #expect(line == nil)
  }

  @Test func aFreshlyEnrolledDisplaySaysOnlyThatCareIsOn() {
    let domain = PrefsDomain()
    domain.edit("row-model-enrolled") { $0.oledCareEnrolled = true }
    let model = TestFixtures.appModel()
    let line = PanelView.careLine(
      persistenceKey: "row-model-enrolled", prefs: domain.prefs("row-model-enrolled"),
      care: model.oledCare, safeMode: model.isSafeMode)
    #expect(line == PanelCareLine.enrolledSegment)
  }

  /// The care loop does not run in a Safe Mode session, so an enrolled display
  /// with nothing counted has no line at all.
  @Test func safeModeNeverClaimsCareIsOn() {
    let domain = PrefsDomain()
    domain.edit("row-model-safe") { $0.oledCareEnrolled = true }
    let model = TestFixtures.appModel(safeMode: true)
    let line = PanelView.careLine(
      persistenceKey: "row-model-safe", prefs: domain.prefs("row-model-safe"),
      care: model.oledCare, safeMode: model.isSafeMode)
    #expect(line == nil)
  }

  /// The coordinator's counter reads the process defaults and there is no seam
  /// to inject through, so the key is unique per run and cleaned up in a `defer`.
  @Test func theHoursAreTheCoordinatorsOwnCounter() {
    let key = "row-model-hours-\(UUID().uuidString)"
    UserDefaults.standard.set(178.4 * 3600, forKey: "oledPanelSeconds.\(key)")
    defer { UserDefaults.standard.removeObject(forKey: "oledPanelSeconds.\(key)") }
    let domain = PrefsDomain()
    domain.edit(key) { $0.oledCareEnrolled = true }
    let model = TestFixtures.appModel()

    let enrolled = PanelView.careLine(
      persistenceKey: key, prefs: domain.prefs(key), care: model.oledCare, safeMode: false)
    #expect(enrolled == "OLED Care on · 178 h")

    domain.edit(key) { $0.oledCareEnrolled = false }
    let unenrolled = PanelView.careLine(
      persistenceKey: key, prefs: domain.prefs(key), care: model.oledCare, safeMode: false)
    #expect(unenrolled == "178 h")
  }

  // MARK: - Paused care line

  /// Fixed so the words do not follow the machine running the suite.
  static let clock: (now: Date, calendar: Calendar, locale: Locale) = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    // Thursday 2026-10-01, 14:00 local.
    let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 14))!
    return (now, calendar, Locale(identifier: "en_US"))
  }()

  static func deadline(days: Int, hour: Int, minute: Int) -> Date {
    let (now, calendar, _) = clock
    let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
    return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
  }

  static func pausedLine(
    until deadline: Date, enrolled: Bool = true, hours: Double = 178.4,
    safeMode: Bool = false, suspended: Bool = false
  ) -> String? {
    let (now, calendar, locale) = clock
    return PanelView.careLine(
      enrolled: enrolled, hours: hours, summary: nil, safeMode: safeMode,
      suspended: suspended, pausedUntil: deadline, now: now, calendar: calendar, locale: locale
    ).map(plainSpaces)
  }

  /// ICU puts a narrow no-break space before AM and PM.
  static func plainSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ")
  }

  @Test func aPausedDisplayNamesWhenDimmingReturns() {
    #expect(Self.pausedLine(until: Self.deadline(days: 0, hour: 15, minute: 45))
      == "Dimming paused until 3:45 PM")
    #expect(Self.pausedLine(until: Self.deadline(days: 1, hour: 4, minute: 0))
      == "Dimming paused until tomorrow, 4:00 AM")
    #expect(Self.pausedLine(until: Self.deadline(days: 3, hour: 4, minute: 0), hours: 0)
      == "Dimming paused until Sun, 4:00 AM")
  }

  /// The engine suspends before it checks the pause, so the panel must not
  /// claim the pause is what is holding dimming off.
  @Test func aSuspensionOutranksThePause() {
    let line = Self.pausedLine(until: Self.deadline(days: 0, hour: 15, minute: 45), suspended: true)
    #expect(line == "OLED Care on · 178 h")
  }

  static func measuredSummary(hottest: Double) -> PanelHealthSummary {
    PanelHealthSummary(
      confidence: .measured, observationEnabled: true,
      cells: [Double](repeating: 0, count: PanelGrid.cellCount),
      hottestRelative: hottest, hottestOwner: nil, sampleCount: 500,
      lastSample: nil, dominantOwnerByCell: nil, topOwnersByHours: [])
  }

  /// The form the coordinator reads through. A suspended display that is also
  /// paused shows its ordinary line, so the summary has to be read for it: the
  /// pause existing used to skip the read and drop the hottest-area segment.
  @Test func aSuspendedAndPausedDisplayKeepsItsHottestArea() {
    let (now, calendar, locale) = Self.clock
    var reads = 0
    let line = PanelView.careLine(
      enrolled: true, hours: 178.4, safeMode: false, suspended: true,
      pausedUntil: Self.deadline(days: 0, hour: 15, minute: 45),
      summary: { reads += 1; return Self.measuredSummary(hottest: 2.49) },
      now: now, calendar: calendar, locale: locale)
    #expect(line == "OLED Care on · 178 h · hottest area 2.5×")
    #expect(reads == 1)
  }

  /// The control: an unsuspended pause says only the pause, and its line never
  /// pays for a store decode it would not show.
  @Test func aPausedLineDoesNotReadTheSummary() {
    let (now, calendar, locale) = Self.clock
    var reads = 0
    let line = PanelView.careLine(
      enrolled: true, hours: 178.4, safeMode: false, suspended: false,
      pausedUntil: Self.deadline(days: 0, hour: 15, minute: 45),
      summary: { reads += 1; return Self.measuredSummary(hottest: 2.49) },
      now: now, calendar: calendar, locale: locale).map(Self.plainSpaces)
    #expect(line == "Dimming paused until 3:45 PM")
    #expect(reads == 0)
  }

  @Test func safeModeAndAnUnenrolledDisplayNeverReadTheSummary() {
    var reads = 0
    let summary: () -> PanelHealthSummary? = { reads += 1; return Self.measuredSummary(hottest: 2.49) }
    #expect(PanelView.careLine(
      enrolled: true, hours: 178.4, safeMode: true, suspended: false, pausedUntil: nil,
      summary: summary) == "178 h")
    #expect(PanelView.careLine(
      enrolled: false, hours: 178.4, safeMode: false, suspended: false, pausedUntil: nil,
      summary: summary) == "178 h")
    #expect(reads == 0)
  }

  @Test func safeModeAndAnUnenrolledDisplayIgnoreAPause() {
    let deadline = Self.deadline(days: 0, hour: 15, minute: 45)
    #expect(Self.pausedLine(until: deadline, safeMode: true) == "178 h")
    #expect(Self.pausedLine(until: deadline, enrolled: false) == "178 h")
  }

  @Test func theCompactEndTimeNamesTheDayWithoutAYear() {
    let (now, calendar, locale) = Self.clock
    func text(_ date: Date) -> String {
      Self.plainSpaces(CompactEndTimeText.string(date, now: now, calendar: calendar, locale: locale))
    }
    #expect(text(Self.deadline(days: 0, hour: 23, minute: 5)) == "11:05 PM")
    #expect(text(Self.deadline(days: 1, hour: 0, minute: 30)) == "tomorrow, 12:30 AM")
    #expect(text(Self.deadline(days: 2, hour: 9, minute: 0)) == "Sat, 9:00 AM")
    #expect(text(Self.deadline(days: 6, hour: 9, minute: 0)) == "Wed, 9:00 AM")
    #expect(text(Self.deadline(days: 7, hour: 9, minute: 0)) == "Oct 8, 9:00 AM")
    #expect(text(Self.deadline(days: 364, hour: 9, minute: 0)) == "Sep 30, 9:00 AM")
    // A year out lands on today's month and day, which alone would read as today.
    #expect(text(Self.deadline(days: 365, hour: 9, minute: 0)) == "Oct 1, 2027, 9:00 AM")
  }

  /// English names whatever the system language, because the words around them
  /// are English; only the clock follows the person's locale.
  @Test func theCompactEndTimeKeepsEnglishNamesAndTheLocalesClock() {
    let (now, calendar, _) = Self.clock
    let german = Locale(identifier: "de_DE")
    func text(_ date: Date) -> String {
      Self.plainSpaces(CompactEndTimeText.string(date, now: now, calendar: calendar, locale: german))
    }
    #expect(text(Self.deadline(days: 0, hour: 14, minute: 0)) == "14:00")
    #expect(text(Self.deadline(days: 1, hour: 9, minute: 5)) == "tomorrow, 09:05")
    #expect(text(Self.deadline(days: 3, hour: 14, minute: 0)) == "Sun, 14:00")
    #expect(text(Self.deadline(days: 7, hour: 14, minute: 0)) == "Oct 8, 14:00")
  }

  @Test func theKeepAwakeTitleUsesTheCompactEndTime() {
    let (now, calendar, locale) = Self.clock
    #expect(PanelView.keepAwakeTitle(expiresAt: nil) == "Keep display awake")
    #expect(Self.plainSpaces(PanelView.keepAwakeTitle(
      expiresAt: Self.deadline(days: 1, hour: 4, minute: 0),
      now: now, calendar: calendar, locale: locale)) == "Until tomorrow, 4:00 AM")
  }

  // MARK: - Keep Awake duration slider

  private final class Holder: PowerAssertionHolding {
    private(set) var created = 0
    private(set) var held = 0
    func createPreventDisplaySleep(named name: String) -> UInt32? {
      created += 1; held += 1; return UInt32(created)
    }
    func release(_ id: UInt32) { held -= 1 }
  }

  private final class TimeSource {
    var now = Date(timeIntervalSince1970: 1_000)
  }

  /// The guide's promise: choosing a stop starts the hold for that long.
  @Test func movingTheSliderWhileOffStartsAHold() {
    let holder = Holder()
    let clock = TimeSource()
    let awake = KeepAwake(holder: holder, now: { clock.now }, clockNotifications: NotificationCenter())
    defer { awake.setOn(false) }
    let chosen = PanelView.chooseAwakeDuration(
      Double(KeepAwakeDuration.oneHour.rawValue), keepAwake: awake)
    #expect(chosen == .oneHour)
    #expect(awake.isOn)
    #expect(awake.expiresAt == Date(timeIntervalSince1970: 4_600))
    #expect(holder.held == 1)
  }

  /// The slider opens on the stop nearest the time left, so clicking that stop
  /// must restart it from now; ignoring it made the click do nothing.
  @Test func reChoosingTheCurrentStopResetsTheDeadline() {
    let holder = Holder()
    let clock = TimeSource()
    let awake = KeepAwake(holder: holder, now: { clock.now }, clockNotifications: NotificationCenter())
    defer { awake.setOn(false) }
    KeepAwakeDuration.oneHour.apply(to: awake)
    clock.now = Date(timeIntervalSince1970: 1_000 + 40 * 60)
    let shown = KeepAwakeDuration.closest(to: awake.expiresAt!.timeIntervalSince(clock.now))
    #expect(shown == .fifteenMinutes)
    PanelView.chooseAwakeDuration(Double(shown.rawValue), keepAwake: awake)
    #expect(awake.expiresAt == clock.now.addingTimeInterval(15 * 60))
    clock.now = clock.now.addingTimeInterval(5 * 60)
    PanelView.chooseAwakeDuration(Double(shown.rawValue), keepAwake: awake)
    #expect(awake.expiresAt == clock.now.addingTimeInterval(15 * 60))
    #expect(holder.created == 1, "A restart replaces the deadline on the one assertion")
    #expect(holder.held == 1)
  }

  /// A custom hold no stop describes reads as Custom, never as the nearest
  /// stop, which is the hold the switch would start if turned off and on.
  @Test func theDurationRowNamesOnlyAStopThatDescribesTheHold() {
    let clock = TimeSource()
    let awake = KeepAwake(holder: Holder(), now: { clock.now }, clockNotifications: NotificationCenter())
    defer { awake.setOn(false) }
    #expect(KeepAwakeDuration.describing(awake) == nil)

    #expect(KeepAwakeDuration.start(awake, until: clock.now.addingTimeInterval(3 * 86_400), now: clock.now))
    #expect(KeepAwakeDuration.describing(awake) == nil)
    #expect(KeepAwakeDuration.start(awake, until: clock.now.addingTimeInterval(7_200 + 30), now: clock.now))
    #expect(KeepAwakeDuration.describing(awake) == .twoHours)
    #expect(KeepAwakeDuration.start(awake, until: clock.now.addingTimeInterval(5_000), now: clock.now))
    #expect(KeepAwakeDuration.describing(awake) == nil)

    // A stop's own hold keeps its name while the time left runs down.
    KeepAwakeDuration.oneHour.apply(to: awake)
    clock.now = clock.now.addingTimeInterval(40 * 60)
    #expect(KeepAwakeDuration.describing(awake) == .oneHour)

    KeepAwakeDuration.untilTurnedOff.apply(to: awake)
    #expect(KeepAwakeDuration.describing(awake) == .untilTurnedOff)
  }

  /// The name is decided when the hold starts: re-matching the time left on
  /// every expand read "1 hour" in the first minute and "Custom" after it.
  @Test func aHoldFromTheDialogKeepsOneNameAsItRunsDown() {
    let clock = TimeSource()
    let awake = KeepAwake(holder: Holder(), now: { clock.now }, clockNotifications: NotificationCenter())
    defer { awake.setOn(false) }
    let start = clock.now
    #expect(KeepAwakeDuration.start(awake, until: start.addingTimeInterval(3_630), now: start))
    let first = KeepAwakeDuration.describing(awake)
    clock.now = start.addingTimeInterval(120)
    #expect(first == .oneHour)
    #expect(KeepAwakeDuration.describing(awake) == first)
  }

  /// Confirming the dialog unchanged hands back the hold's own deadline; the
  /// stop it started from must keep its name rather than re-match the time left.
  @Test func anUnchangedReopenKeepsTheStopsName() {
    let clock = TimeSource()
    let awake = KeepAwake(holder: Holder(), now: { clock.now }, clockNotifications: NotificationCenter())
    defer { awake.setOn(false) }
    let start = clock.now
    KeepAwakeDuration.oneHour.apply(to: awake)
    let deadline = awake.expiresAt!
    clock.now = start.addingTimeInterval(20 * 60)
    #expect(KeepAwakeDuration.start(awake, until: deadline, now: clock.now))
    #expect(KeepAwakeDuration.describing(awake) == .oneHour)
  }

  /// A hold that ended on its own must not leave "Custom" beside an off switch.
  @Test func theDurationRowNeverReadsCustomWhileTheHoldIsOff() {
    for duration in KeepAwakeDuration.allCases {
      for isCustom in [false, true] {
        #expect(PanelView.awakeDurationLabel(duration, isCustom: isCustom, isOn: false) == duration.title)
      }
      #expect(PanelView.awakeDurationLabel(duration, isCustom: false, isOn: true) == duration.title)
      #expect(PanelView.awakeDurationLabel(duration, isCustom: true, isOn: true) == "Custom")
    }
  }

  private final class RefusingHolder: PowerAssertionHolding {
    func createPreventDisplaySleep(named name: String) -> UInt32? { nil }
    func release(_ id: UInt32) {}
  }

  /// A refused assertion leaves the switch off, so the row must not name the
  /// stop as if it were holding.
  @Test func aRefusedAssertionNamesNoStop() {
    let awake = KeepAwake(holder: RefusingHolder(), clockNotifications: NotificationCenter())
    for duration in KeepAwakeDuration.allCases {
      #expect(PanelView.chooseAwakeDuration(Double(duration.rawValue), keepAwake: awake) == nil)
      #expect(!awake.isOn)
    }
  }

  @Test func aValueOffTheStopsChangesNothing() {
    let awake = KeepAwake(holder: Holder(), clockNotifications: NotificationCenter())
    defer { awake.setOn(false) }
    #expect(PanelView.chooseAwakeDuration(99, keepAwake: awake) == nil)
    #expect(!awake.isOn)
  }

  // MARK: - The care disclosure

  @Test func theCareDisclosureOpensOnlyForAnEnrolledDisplayOutsideSafeMode() {
    #expect(PanelView.offersCareActions(enrolled: true, safeMode: false))
    #expect(!PanelView.offersCareActions(enrolled: false, safeMode: false))
    #expect(!PanelView.offersCareActions(enrolled: true, safeMode: true))
    #expect(PanelView.careActions(enrolled: false, safeMode: false, paused: true).isEmpty)
    #expect(PanelView.careActions(enrolled: true, safeMode: true, paused: true).isEmpty)
  }

  @Test func resumeNowLeadsTheRowsOnlyWhileAPauseRuns() {
    let idle = PanelView.careActions(enrolled: true, safeMode: false, paused: false)
    #expect(idle.map(\.title) == [
      "Pause Dimming for 15 Minutes", "Pause Dimming for 1 Hour", "Pause Dimming Until…",
    ])
    let paused = PanelView.careActions(enrolled: true, safeMode: false, paused: true)
    #expect(paused.map(\.title) == [
      "Resume Now", "Pause Dimming for 15 Minutes", "Pause Dimming for 1 Hour",
      "Pause Dimming Until…",
    ])
  }

  /// This form reads the app's own prefs domain, so the key is one nothing has
  /// written to and the answer is nil.
  @Test func theModelFormReadsTheDisplaysOwnPrefs() {
    let model = TestFixtures.appModel()
    let state = Self.state(
      id: 1, name: "MAG 341C", key: "row-model-care-\(UUID().uuidString)")
    #expect(PanelView.careLine(for: state, model: model) == nil)
  }

  // MARK: - Brightness row reason

  /// Drives the wire until the display is demoted, or gives up. A bounded wait
  /// rather than a sleep: the verdict lands on a task the last write wakes.
  private static func demote(_ state: AppModel.DisplayState) async {
    (state.writer as? FakeDDCWriter)?.writesSucceed = false
    for step in 0 ..< 3 {
      state.controller.setBrightness(0.9 - Double(step) * 0.05)
      await state.controller.waitForPendingWrites()
    }
    for _ in 0 ..< 200 where !state.controller.isWireUnresponsive {
      await Task.yield()
    }
  }

  @Test func aWorkingWireLeavesTheBrightnessRowWithNothingToSay() async {
    let model = TestFixtures.appModel()
    let state = Self.state(id: 1, name: "MAG 341C", key: "mag")
    state.controller.setBrightness(0.8)
    await state.controller.waitForPendingWrites()
    #expect(!state.controller.isWireUnresponsive)
    #expect(model.brightnessSliderCompactReason(state) == nil)
  }

  /// The words come from the policy, not from the row: the display still dims in
  /// software, so the caption explains rather than apologizes.
  @Test func aWireThatStoppedAnsweringPutsItsReasonOnTheBrightnessRow() async {
    let model = TestFixtures.appModel()
    let state = Self.state(id: 1, name: "MAG 341C", key: "mag")
    await Self.demote(state)
    #expect(state.controller.isWireUnresponsive)
    #expect(model.brightnessSliderCompactReason(state)
      == BrightnessSliderPolicy.wireUnresponsiveReason)
  }

  /// Recovery on a route that is neither a replug nor a relaunch. A stale
  /// sentence outliving its cause is the failure this row is specified against.
  @Test func theReasonGoesWhenTheWireAnswersAgain() async {
    let model = TestFixtures.appModel()
    let state = Self.state(id: 1, name: "MAG 341C", key: "mag")
    await Self.demote(state)
    (state.writer as? FakeDDCWriter)?.writesSucceed = true
    state.controller.noteWake()
    #expect(model.brightnessSliderCompactReason(state) == nil)
  }
}

// MARK: - Combined brightness row

@Suite("Combined brightness row")
@MainActor
struct CombinedBrightnessRowTests {
  private static func state(
    id: CGDirectDisplayID, name: String, key: String
  ) -> AppModel.DisplayState {
    TestFixtures.displayState(id: id, name: name, persistenceKey: key)
  }

  @Test func participantsAreTheBuiltInThenTheExternals() {
    let domain = PrefsDomain()
    let builtIn = Self.state(id: 1, name: "Built-in", key: "builtin")
    let externals = [
      Self.state(id: 2, name: "MAG", key: "mag"),
      Self.state(id: 3, name: "Dell", key: "dell"),
    ]
    let picked = CombinedBrightness.participants(
      builtIn: builtIn, externals: externals, prefs: domain.prefs)
    #expect(picked.map(\.display.persistenceKey) == ["builtin", "mag", "dell"])
  }

  @Test func aDisplayWithKeyboardControlOffIsNotCommanded() {
    let domain = PrefsDomain()
    domain.edit("mag") { $0.isDisabled = true }
    let externals = [
      Self.state(id: 2, name: "MAG", key: "mag"),
      Self.state(id: 3, name: "Dell", key: "dell"),
    ]
    let picked = CombinedBrightness.participants(
      builtIn: nil, externals: externals, prefs: domain.prefs)
    #expect(picked.map(\.display.persistenceKey) == ["dell"])
  }

  @Test func theRowNeedsTwoParticipantsAndTheAppPref() {
    let domain = PrefsDomain()
    #expect(CombinedBrightness.shows(participantCount: 1, appPrefs: domain.prefs("app")) == false)
    #expect(CombinedBrightness.shows(participantCount: 2, appPrefs: domain.prefs("app")))
    domain.edit("app") { $0.hideCombinedBrightness = true }
    #expect(CombinedBrightness.shows(participantCount: 2, appPrefs: domain.prefs("app")) == false)
  }

  @Test func theHandleRestsAtTheMeanAndAnEmptySetReadsZero() {
    #expect(CombinedBrightness.mean([0.2, 0.8]) == 0.5)
    #expect(CombinedBrightness.mean([1.0]) == 1.0)
    #expect(CombinedBrightness.mean([]) == 0)
  }

  @Test func aDragWritesOneValueToEveryParticipant() {
    let a = Self.state(id: 2, name: "MAG", key: "cb-mag")
    let b = Self.state(id: 3, name: "Dell", key: "cb-dell")
    a.controller.setBrightness(0.2)
    b.controller.setBrightness(0.9)
    let row = CombinedSliderRow(participants: [a, b], snapsToStops: false, showsPercent: false)
    #expect(row.value == 0.55)
    row.setValue(0.4)
    #expect(a.controller.brightness == 0.4)
    #expect(b.controller.brightness == 0.4)
    #expect(row.value == 0.4)
  }
}

/// The empty state's second line names a pane, and the two panes are different
/// pages: a laptop sent to Displays finds no switch there.
@Suite("Panel empty state")
@MainActor
struct PanelEmptyStateTests {
  @Test func aHiddenBuiltInAloneIsUndoneOnTheMenuBarPane() {
    let hint = PanelView.unhideHint(builtInHidden: true, externalsHidden: false)
    #expect(hint.contains("Menu Bar"))
    #expect(hint.contains("Displays") == false)
  }

  @Test func aHiddenExternalIsUndoneOnItsOwnPage() {
    let hint = PanelView.unhideHint(builtInHidden: false, externalsHidden: true)
    #expect(hint.contains("Displays"))
    #expect(hint.contains("Menu Bar") == false)
  }

  /// A clamshell rig opened later with both kinds hidden.
  @Test func bothKindsHiddenNamesBothPanes() {
    let hint = PanelView.unhideHint(builtInHidden: true, externalsHidden: true)
    #expect(hint.contains("Menu Bar"))
    #expect(hint.contains("Displays"))
  }
}

/// The OLED Care page's Status line and pause row, derived where the panel's
/// care line is, so the two surfaces agree on what outranks what.
@Suite("OLED Care page row model")
@MainActor
struct OledCarePageRowModelTests {
  private static let clock = PanelRowModelTests.clock

  private static func status(
    enrolled: Bool = true, safeMode: Bool = false, suspended: Bool = false, pausedUntil: Date?
  ) -> OledCareDisplayPage.StatusSource {
    let (now, calendar, locale) = clock
    let source = OledCareDisplayPage.statusSource(
      enrolled: enrolled, safeMode: safeMode, suspended: suspended, pausedUntil: pausedUntil,
      now: now, calendar: calendar, locale: locale)
    if case let .paused(line) = source { return .paused(PanelRowModelTests.plainSpaces(line)) }
    return source
  }

  private static let deadline = PanelRowModelTests.deadline(days: 0, hour: 15, minute: 45)

  @Test func aPauseNamesItsEndOnTheStatusLine() {
    #expect(Self.status(pausedUntil: Self.deadline) == .paused("Dimming paused until 3:45 PM"))
    #expect(Self.status(pausedUntil: nil) == .engine)
  }

  /// The engine suspends before it checks the pause, so a mirror or a checkup
  /// field keeps its own reason on screen for the whole pause.
  @Test func aSuspensionOutranksThePause() {
    #expect(Self.status(suspended: true, pausedUntil: Self.deadline) == .engine)
  }

  @Test func safeModeOutranksEverything() {
    #expect(Self.status(safeMode: true, suspended: true, pausedUntil: Self.deadline) == .safeMode)
    #expect(Self.status(safeMode: true, pausedUntil: nil) == .safeMode)
  }

  @Test func anUnenrolledDisplayIgnoresAPause() {
    #expect(Self.status(enrolled: false, pausedUntil: Self.deadline) == .engine)
  }

  private static func row(
    enrolled: Bool = true, safeMode: Bool = false, pausedUntil: Date?
  ) -> OledCareDisplayPage.PauseRow? {
    let (now, calendar, locale) = clock
    return OledCareDisplayPage.pauseRow(
      enrolled: enrolled, safeMode: safeMode, pausedUntil: pausedUntil,
      now: now, calendar: calendar, locale: locale)
  }

  @Test func withNoPauseTheRowOffersOneAndNoResume() {
    #expect(Self.row(pausedUntil: nil) == .init(
      label: "Pause dimming temporarily", menuTitle: "Pause Dimming", offersResume: false))
  }

  @Test func aRunningPauseOffersResumeAndAChangeOfDuration() {
    let row = Self.row(pausedUntil: Self.deadline)
    #expect(row.map { PanelRowModelTests.plainSpaces($0.label) } == "Paused until 3:45 PM")
    #expect(row?.menuTitle == "Change Duration")
    #expect(row?.offersResume == true)
  }

  @Test func thereIsNoPauseRowWhereNothingDims() {
    #expect(Self.row(enrolled: false, pausedUntil: nil) == nil)
    #expect(Self.row(safeMode: true, pausedUntil: Self.deadline) == nil)
  }
}
