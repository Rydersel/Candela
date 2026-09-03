import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// A prefs domain a test can write to and hand back to a derivation, which the
/// per-call `TestFixtures.prefs` suite cannot do: the factory has to answer
/// from the same storage the test seeded.
private struct PrefsDomain {
  let defaults = UserDefaults(suiteName: "panel-row-tests-\(UUID().uuidString)")!

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
      isShowingSynthesizedSize: true, isHDREngaged: false
    )
    #expect(reason == SynthesisCopy.hdrBlockedBySynthesizedSize)
  }

  @Test func theHDRButtonIsUnrefusedWithNoSizeEngaged() {
    #expect(PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: false, isHDREngaged: false
    ) == nil)
    #expect(PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: false, isHDREngaged: true
    ) == nil)
  }

  /// The exit direction is never refused, so the one control that can take a
  /// display out of the HDR-over-a-size combination is never the greyed one.
  @Test func theHDRExitIsOfferedEvenWithASizeEngaged() {
    #expect(PanelView.hdrRefusalReason(
      isShowingSynthesizedSize: true, isHDREngaged: true
    ) == nil)
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
    let hint = PanelView.unhideHint(hasExternals: false)
    #expect(hint.contains("Menu Bar"))
    #expect(hint.contains("Displays") == false)
  }

  @Test func aHiddenExternalIsUndoneOnItsOwnPage() {
    let hint = PanelView.unhideHint(hasExternals: true)
    #expect(hint.contains("Displays"))
    #expect(hint.contains("Menu Bar") == false)
  }
}
