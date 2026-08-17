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

  // MARK: - D24, the volume capability verdict

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
}
