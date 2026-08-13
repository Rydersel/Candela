import Testing
@testable import CandelaKit

@Suite("Pref propagation table (D20, D27)")
struct PrefPropagationTests {
  // MARK: - Completeness (D27): the invariants a hand-typed table cannot hold

  @Test func everyKnownPrefFansOutToSomething() {
    for name in PrefName.allCases {
      #expect(!PrefPropagation.effects(forChange: name).isEmpty, "\(name.rawValue) fans out to nothing")
    }
  }

  @Test func everyKnownPrefRefreshesTheUI() {
    // Panes bind two-way to DisplayPrefs, which is plain UserDefaults and NOT
    // observable. `AppModel.prefsRevision` is the only invalidation signal, so
    // a pref with no `.refreshUI` row is a control that writes to disk and
    // never moves — the picker snaps back, the dependent section never opens.
    for name in PrefName.allCases {
      #expect(PrefPropagation.effects(forChange: name).contains(.refreshUI), "\(name.rawValue)")
    }
  }

  @Test func engineStateIsNotAPrefName() {
    // D8: `muted` is engine state, not a setting. D22: `hdrMode` goes through
    // the controller's state machine and must never be written by a pane.
    // Neither may become a PrefName case, or a pane could route through it.
    #expect(PrefName(rawValue: "muted") == nil)
    #expect(PrefName(rawValue: "hdrMode") == nil)
    #expect(PrefName(rawValue: "notARealPref") == nil)
    // D32 inert keys: reserved in DisplayPrefs, but nothing reads them, so
    // they get no row and no case. Adding one would be a lie in the table.
    #expect(PrefName(rawValue: "menuItemStyle") == nil)
    #expect(PrefName(rawValue: "showTickMarks") == nil)
    #expect(PrefName(rawValue: "longerDelay") == nil)
    // #110's escape hatch has no UI by design (D26) — being read at use is not
    // the reason (`pollingMode` is read at use and IS a case); having no pane
    // to write it through is. Nothing can route a change, so it gets no row.
    #expect(PrefName(rawValue: "wireTimingGuard") == nil)
  }

  @Test func oledEngineStateIsNotAPrefName() {
    // Hours accumulation is engine state written by the tracker, not a
    // setting a pane may route through (same rule as `muted`).
    #expect(PrefName(rawValue: "oledPanelSeconds") == nil)
    #expect(PrefName(rawValue: "oledStandbySeconds") == nil)
    // Same rule for the note's dismissal: the tracker persists it, no pane
    // writes it, so it must never become a case a pane could route through.
    #expect(PrefName(rawValue: "oledStandbyNoteDismissed") == nil)
    // The two inverted storage keys are keys, not propagation identifiers.
    #expect(PrefName(rawValue: "oledLockDimOff") == nil)
    #expect(PrefName(rawValue: "oledHoursTrackingOff") == nil)
  }

  @Test func prefNameRawValuesAreTheOnDiskKeys() {
    // D22: the raw values compose real key strings. The three that invite a
    // typo are pinned by hand; the rest are the case name verbatim.
    #expect(PrefName.forceSw.rawValue == "forceSw") // NOT "forceSW"
    #expect(PrefName.unavailableDDC.rawValue == "unavailableDDC")
    #expect(PrefName.disableAltBrightnessKeys.rawValue == "disableAltBrightnessKeys")
    // W2 SP1 added `rememberDisplayMode`/`storedDisplayMode`: 33 -> 35.
    #expect(PrefName.rememberDisplayMode.rawValue == "rememberDisplayMode")
    #expect(PrefName.storedDisplayMode.rawValue == "storedDisplayMode")
    // #13 added the two arrangement keys: 35 -> 37.
    #expect(PrefName.restoreArrangement.rawValue == "restoreArrangement")
    #expect(PrefName.savedArrangements.rawValue == "savedArrangements")
    // The settings overhaul promoted three read-at-use prefs: 37 -> 40. Their
    // raw values are the keys `DisplayPrefs` already writes, so a typo here
    // would strand every value a user has already set.
    #expect(PrefName.pollingMode.rawValue == "pollingMode")
    #expect(PrefName.pollingCount.rawValue == "pollingCount")
    #expect(PrefName.separateCombinedScale.rawValue == "separateCombinedScale")
    // W3a added ten OLED-care keys: 40 -> 50. Two of them are the exception to
    // the heading above — `oledLockDim` and `oledHoursTracking` store INVERTED
    // (`…Off`), so their raw value is a propagation identifier, not the key
    // (precedent: the `forceSw` accessor is named `forceSoftware`).
    #expect(PrefName.oledCareEnrolled.rawValue == "oledCareEnrolled")
    #expect(PrefName.oledLockDim.rawValue == "oledLockDim")
    // W3b-1 added two: 50 -> 52. `oledWindowObservation` is a third member of
    // the inverted-storage exception above (`oledWindowObservationOff`).
    //
    // The 52 is the UNION of two branches that each counted from 47: W3b-1 saw
    // 47 -> 49, the settings overhaul saw 47 -> 50, and both landed. Counted
    // from the enum, not arithmetic on the two claims.
    #expect(PrefName.oledTelemetry.rawValue == "oledTelemetry")
    #expect(PrefName.oledWindowObservation.rawValue == "oledWindowObservation")
    #expect(PrefName.allCases.count == 53)
  }

  // MARK: - Rows

  @Test func tapRearmCoversEveryTapConfigInputPlusTheKeyModes() {
    // Derived from `AppModel.tapConfig`, not transcribed. It reads exactly
    // FOUR prefs today (D32 corrects D20's "five"):
    //   multiKeyboardVolume      — via `volumeMode`
    //   forceSw                  — via `ddcCapableStates()`
    //   audioDeviceNameOverride  — via `audioMatchingDisplays(for:)`
    //   disableAltBrightnessKeys — directly, in the WatchConfig
    // Task 7 adds two more (`keyboardBrightness`/`keyboardVolume` decide
    // whether the tap runs at all), for six. Gating the watched set on whether a
    // volume or mute press could land at all adds the last three:
    //   audioSinkOverride: the user's override half of that verdict
    //   enableMuteUnmute: picks WHICH register the mute key would write, so it
    //                     picks which verdict arms the mute key
    //   unavailableDDC: the engine's own switch, checked before every DDC write,
    //                   so a volume command switched off can take no key
    for name: PrefName in [.multiKeyboardVolume, .forceSw, .audioDeviceNameOverride,
                           .disableAltBrightnessKeys, .keyboardBrightness, .keyboardVolume,
                           .audioSinkOverride, .enableMuteUnmute, .unavailableDDC] {
      #expect(PrefPropagation.effects(forChange: name).contains(.rearmTap), "\(name.rawValue)")
    }
    // NOT `isDisabled`, and that is a ruling rather than an oversight: a display
    // whose keyboard control is off swallows its press (R1), the same as it does
    // for brightness, so it must keep the keys armed rather than hand them to
    // macOS. Only what makes the press impossible releases them.
    #expect(!PrefPropagation.effects(forChange: .isDisabled).contains(.rearmTap))
    // Fork bug 3 (D2) is closed by CONSTRUCTION, not by this table:
    // `StatusItemController` builds `KeyRouterConfig` inside the tap's press
    // closure, so the fine-scale prefs are read at event time on every press.
    // A `.rearmTap` row for them would be cargo-culted from the fork.
    #expect(!PrefPropagation.effects(forChange: .useFineScaleBrightness).contains(.rearmTap))
    #expect(!PrefPropagation.effects(forChange: .useFineScaleVolume).contains(.rearmTap))
  }

  @Test func keyModeChangesRecheckPermissions() {
    // Fork bug 2 (D2): switching a keyboard mode never re-prompted for AX.
    #expect(PrefPropagation.effects(forChange: .keyboardBrightness).contains(.recheckPermissions))
    #expect(PrefPropagation.effects(forChange: .keyboardVolume).contains(.recheckPermissions))
    #expect(!PrefPropagation.effects(forChange: .showContrast).contains(.recheckPermissions))
  }

  @Test func dimmingPathPrefsReapply() {
    for name: PrefName in [.disableCombinedBrightness, .allowZeroSwBrightness,
                           .combinedSwitchingPoint, .forceSw, .avoidGamma,
                           .unavailableDDC, .minDDCOverride, .maxDDCOverride,
                           .curveDDC, .invertDDC, .remapDDC] {
      #expect(PrefPropagation.effects(forChange: name).contains(.reapplyDimming), "\(name.rawValue)")
    }
    // Purely cosmetic / key-time prefs must NOT drag the DDC bus.
    for name: PrefName in [.hideDisplay, .friendlyName, .showContrast, .enableSliderSnap,
                           .menuIcon, .multiKeyboardBrightness] {
      #expect(!PrefPropagation.effects(forChange: name).contains(.reapplyDimming), "\(name.rawValue)")
    }
  }

  @Test func panelRenderingPrefsRebuildThePanel() {
    for name: PrefName in [.friendlyName, .hideDisplay, .hideBuiltInDisplay, .hideVolumeSlider,
                           .showContrast, .audioSinkOverride, .audioDeviceNameOverride,
                           .enableSliderSnap, .enableSliderPercent, .menuIcon,
                           .forceSw, .unavailableDDC, .isDisabled, .hideOsd,
                           .avoidGamma, .enableBrightnessSync] {
      #expect(PrefPropagation.effects(forChange: name).contains(.rebuildPanel), "\(name.rawValue)")
    }
  }

  @Test func sliderVisibilityPrefsUpdateTheStatusItem() {
    // `MenuIconPolicy.isStatusItemVisible` takes THREE inputs, and
    // `hasVisibleSlider` derives from `hideDisplay` (PanelView.visibleDisplays)
    // and `hideBuiltInDisplay` (PanelView.showsBuiltIn) — not just `menuIcon`.
    // With only a `menuIcon` row, `.sliderOnly` silently never re-evaluates
    // when driven from the panes: hiding your last display in Settings leaves
    // the icon in the menu bar until the next hotplug, and un-hiding leaves it
    // absent with no obvious way back.
    for name: PrefName in [.menuIcon, .hideDisplay, .hideBuiltInDisplay] {
      #expect(PrefPropagation.effects(forChange: name).contains(.updateStatusItem), "\(name.rawValue)")
    }
    #expect(!PrefPropagation.effects(forChange: .showContrast).contains(.updateStatusItem))
  }

  // MARK: - Exactness (an over-broad row is as wrong as a missing one)

  @Test func representativeRowsAreExactNotJustNonEmpty() {
    // Adding `.reapplyDimming` to a UI-only pref costs a DDC transaction on
    // every show/hide toggle — and on a write-only panel, a visible
    // brightness re-assert. Membership assertions alone cannot see that.
    #expect(PrefPropagation.effects(forChange: .hideDisplay)
      == [.refreshUI, .rebuildPanel, .updateStatusItem])
    #expect(PrefPropagation.effects(forChange: .menuIcon)
      == [.refreshUI, .rebuildPanel, .updateStatusItem])
    #expect(PrefPropagation.effects(forChange: .keyboardBrightness)
      == [.refreshUI, .rearmTap, .recheckPermissions])
    #expect(PrefPropagation.effects(forChange: .forceSw)
      == [.refreshUI, .rearmTap, .reapplyDimming, .rebuildPanel])
    #expect(PrefPropagation.effects(forChange: .startupAction) == [.refreshUI])
    // Both halves of the volume verdict, exact: neither may drag the DDC bus.
    // `audioSinkOverride` greys a slider and releases a key; it writes nothing.
    #expect(PrefPropagation.effects(forChange: .audioSinkOverride)
      == [.refreshUI, .rearmTap, .rebuildPanel])
    #expect(PrefPropagation.effects(forChange: .enableMuteUnmute)
      == [.refreshUI, .rearmTap])
    // The engine's availability switch keeps its dimming and panel work; the tap
    // row is added to it, not swapped in.
    #expect(PrefPropagation.effects(forChange: .unavailableDDC)
      == [.refreshUI, .rearmTap, .reapplyDimming, .rebuildPanel])
  }

  @Test func oledCarePrefsFanOutToOledCare() {
    let oled: [PrefName] = [
      .oledCareEnrolled, .oledIdleDimSeconds, .oledIdleDimLevel, .oledLockDim,
      .oledBlackoutEnabled, .oledBlackoutSeconds,
      .oledUnfocusedDimEnabled, .oledUnfocusedDimSeconds, .oledUnfocusedDimLevel,
      .oledHoursTracking, .oledTelemetry, .oledWindowObservation,
      .oledDetectionDimming,
    ]
    for name in oled {
      #expect(PrefPropagation.effects(forChange: name).contains(.reapplyOledCare), "\(name.rawValue)")
      #expect(PrefPropagation.effects(forChange: name).contains(.refreshUI), "\(name.rawValue)")
    }
    // Exact, not merely non-empty: OLED care runs its own timers and dimming
    // leg, so a stray `.reapplyDimming` here would re-write the DDC bus on
    // every idle-timeout tweak.
    #expect(PrefPropagation.effects(forChange: .oledCareEnrolled) == [.refreshUI, .reapplyOledCare])
  }

  // MARK: - Batch fan-out (the per-display reset rides on this)

  @Test func aBatchWriteFansOutToTheUnionAndForceSwAloneIsNotEnough() {
    // Task 14's per-display reset writes this batch and must fan out ONCE.
    // Its original reasoning — "the union is exactly `forceSw`'s row" — is
    // FALSE once `hideDisplay` carries `.updateStatusItem`: resetting a
    // display un-hides it, which can change status-item visibility under
    // `.sliderOnly`. Use `prefsDidChange(_:persistenceKey:)`, not a single
    // `prefDidChange(.forceSw)`.
    let batch: [PrefName] = [.friendlyName, .hideDisplay, .isDisabled, .hideOsd, .forceSw,
                             .avoidGamma, .enableMuteUnmute, .audioSinkOverride,
                             .audioDeviceNameOverride, .hideVolumeSlider,
                             .combinedSwitchingPoint, .unavailableDDC, .minDDCOverride,
                             .maxDDCOverride, .curveDDC, .invertDDC, .remapDDC]
    let union = PrefPropagation.effects(forChanges: batch)
    #expect(union == [.refreshUI, .rearmTap, .reapplyDimming, .rebuildPanel, .updateStatusItem])
    #expect(union != PrefPropagation.effects(forChange: .forceSw))
    #expect(PrefPropagation.effects(forChanges: []).isEmpty)
  }

  @Test func promotedReadAtUsePrefsAreCasesWithUIOnlyRows() {
    // Settings overhaul SO/A1: these gained real UI, so D27 requires cases.
    // They are read at use (DDC-read time / key time), so their row is
    // refreshUI alone, which is a deliberate answer rather than a missing one.
    // `enableMuteUnmute` used to sit here and no longer does: it also decides
    // which register the mute key would write, and so which verdict arms it.
    for name in [PrefName.pollingMode, .pollingCount, .separateCombinedScale] {
      #expect(PrefPropagation.effects(forChange: name) == [.refreshUI])
    }
  }
}
