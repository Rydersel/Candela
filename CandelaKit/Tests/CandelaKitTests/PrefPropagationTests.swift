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
    // observable. `AppModel.prefsRevision` is the only invalidation signal, so a
    // pref with no `.refreshUI` row is a control that writes to disk and never
    // moves: the picker snaps back, the dependent section never opens.
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
    #expect(PrefName(rawValue: "showModelComparison") == nil)
    #expect(PrefName(rawValue: "longerDelay") == nil)
    // `wireTimingGuard` has no UI by design (D26). Being read at use is not the
    // reason (`pollingMode` is read at use and IS a case); having no pane to
    // write it through is, so nothing can route a change.
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
    // D22: the raw values compose real on-disk key strings, so the ones that
    // invite a typo are pinned by hand. The rest are the case name verbatim.
    #expect(PrefName.forceSw.rawValue == "forceSw") // NOT "forceSW"
    #expect(PrefName.unavailableDDC.rawValue == "unavailableDDC")
    #expect(PrefName.disableAltBrightnessKeys.rawValue == "disableAltBrightnessKeys")
    #expect(PrefName.rememberDisplayMode.rawValue == "rememberDisplayMode")
    #expect(PrefName.storedDisplayMode.rawValue == "storedDisplayMode")
    #expect(PrefName.restoreArrangement.rawValue == "restoreArrangement")
    #expect(PrefName.savedArrangements.rawValue == "savedArrangements")
    // These are keys `DisplayPrefs` already writes: a typo strands every value
    // a user has already set.
    #expect(PrefName.pollingMode.rawValue == "pollingMode")
    #expect(PrefName.pollingCount.rawValue == "pollingCount")
    #expect(PrefName.separateCombinedScale.rawValue == "separateCombinedScale")
    // `oledLockDim` and `oledHoursTracking` store INVERTED (`…Off`), so their
    // raw value is a propagation identifier rather than the on-disk key.
    #expect(PrefName.oledCareEnrolled.rawValue == "oledCareEnrolled")
    #expect(PrefName.oledLockDim.rawValue == "oledLockDim")
    // `oledWindowObservation` is inverted too (`oledWindowObservationOff`).
    #expect(PrefName.oledTelemetry.rawValue == "oledTelemetry")
    #expect(PrefName.oledWindowObservation.rawValue == "oledWindowObservation")
    // A typo in either moves one pill and strands the position chosen for the
    // other.
    #expect(PrefName.hudPositionBrightness.rawValue == "hudPositionBrightness")
    #expect(PrefName.hudPositionVolume.rawValue == "hudPositionVolume")
    #expect(PrefName.hudStyle.rawValue == "hudStyle")
    // Base names `DisplayPrefs` composes with `.<slot>`.
    #expect(PrefName.virtualSlotConfigured.rawValue == "virtualSlotConfigured")
    #expect(PrefName.virtualSlotUUID.rawValue == "virtualSlotUUID")
    #expect(PrefName.virtualSlotDefined.rawValue == "virtualSlotDefined")
    #expect(PrefName.sizeRecommendationDismissed.rawValue == "sizeRecommendationDismissed")
    // `storedSyntheticSize` holds a JSON descriptor; both are keys
    // `DisplayPrefs` composes with `.<pk>` (SS4).
    #expect(PrefName.offerSyntheticSizes.rawValue == "offerSyntheticSizes")
    #expect(PrefName.storedSyntheticSize.rawValue == "storedSyntheticSize")
    // Hide-shaped like `hideBuiltInDisplay`: an absent key means row shown.
    #expect(PrefName.hideKeepAwake.rawValue == "hideKeepAwake")
    #expect(PrefName.hideCombinedBrightness.rawValue == "hideCombinedBrightness")
    #expect(PrefName.allCases.count == 70)
  }

  // MARK: - Rows

  @Test func tapRearmCoversEveryTapConfigInputPlusTheKeyModes() {
    // Derived by reading `AppModel.tapConfig`, not transcribed. The last three
    // are in because the watched set is gated on whether a volume or mute press
    // could land at all: `audioSinkOverride` is the user's half of that verdict,
    // `enableMuteUnmute` picks which register the mute key writes, and
    // `unavailableDDC` is checked before every DDC write.
    for name: PrefName in [.multiKeyboardVolume, .forceSw, .audioDeviceNameOverride,
                           .disableAltBrightnessKeys, .keyboardBrightness, .keyboardVolume,
                           .audioSinkOverride, .enableMuteUnmute, .unavailableDDC] {
      #expect(PrefPropagation.effects(forChange: name).contains(.rearmTap), "\(name.rawValue)")
    }
    // NOT `isDisabled`, by ruling: a display whose keyboard control is off
    // swallows the press (R1) rather than handing it to macOS, so the keys stay
    // armed. Only what makes the press impossible releases them.
    #expect(!PrefPropagation.effects(forChange: .isDisabled).contains(.rearmTap))
    // Fork bug 3 (D2) is closed by construction, not by this table:
    // `StatusItemController` builds `KeyRouterConfig` inside the press closure,
    // so the fine-scale prefs are read at event time on every press.
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
    // `hasVisibleSlider` derives from `hideDisplay` and `hideBuiltInDisplay`,
    // not just `menuIcon`. With only a `menuIcon` row, `.sliderOnly` never
    // re-evaluates from the panes: hiding your last display leaves the icon in
    // the menu bar until the next hotplug.
    for name: PrefName in [.menuIcon, .hideDisplay, .hideBuiltInDisplay] {
      #expect(PrefPropagation.effects(forChange: name).contains(.updateStatusItem), "\(name.rawValue)")
    }
    #expect(!PrefPropagation.effects(forChange: .showContrast).contains(.updateStatusItem))
  }

  // MARK: - Exactness (an over-broad row is as wrong as a missing one)

  @Test func representativeRowsAreExactNotJustNonEmpty() {
    // `.reapplyDimming` on a UI-only pref costs a DDC transaction per toggle,
    // and on a write-only panel a visible brightness re-assert.
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
    // Exact, not merely non-empty: OLED care runs its own dimming leg, so a
    // stray `.reapplyDimming` re-writes the DDC bus on every timeout tweak.
    #expect(PrefPropagation.effects(forChange: .oledCareEnrolled) == [.refreshUI, .reapplyOledCare])
  }

  // MARK: - Batch fan-out (the per-display reset rides on this)

  @Test func aBatchWriteFansOutToTheUnionAndForceSwAloneIsNotEnough() {
    // The per-display reset writes this batch and must fan out once. The union
    // is NOT `forceSw`'s row: reset un-hides a display, which can change
    // status-item visibility under `.sliderOnly`. Use
    // `prefsDidChange(_:persistenceKey:)`, not `prefDidChange(.forceSw)`.
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
    // These have UI, so D27 requires cases, but they are read at use, so
    // `refreshUI` alone is the deliberate answer rather than a missing row.
    for name in [PrefName.pollingMode, .pollingCount, .separateCombinedScale] {
      #expect(PrefPropagation.effects(forChange: name) == [.refreshUI])
    }
  }

  @Test func virtualSlotLifecycleRidesOnConfiguredAlone() {
    // VD14/VD17: only the `configured` write converges live displays, so
    // editing a running slot's fields never yanks a display under the user;
    // the pane's Create/Apply/Remove buttons are `configured` writes.
    #expect(PrefPropagation.effects(forChange: .virtualSlotConfigured)
      == [.refreshUI, .syncVirtualDisplays])
    for name in [PrefName.virtualSlotName, .virtualSlotWidth, .virtualSlotHeight,
                 .virtualSlotHiDPI, .virtualSlotRefreshHz, .virtualSlotRecreateAtLaunch,
                 .virtualSlotUUID, .virtualSlotDefined] {
      #expect(PrefPropagation.effects(forChange: name) == [.refreshUI], "\(name.rawValue)")
    }
  }

  @Test func theSizeSuggestionDismissalRefreshesTheUIAndNothingElse() {
    // A button writes this, so D27 makes it a case (unlike
    // `oledStandbyNoteDismissed`, which the hours tracker writes). Nothing else
    // may ride on it: the suggestion names a resolution but changes none, so any
    // display work would turn a "not now" into a mode change.
    #expect(PrefPropagation.effects(forChange: .sizeRecommendationDismissed) == [.refreshUI])
  }

  @Test func indicatorPositionsRefreshTheUIAndNothingElse() {
    // `KeyActionExecutor` reads these as it announces a pill, so the next press
    // already uses the new position. `.reapplyDimming` would put a DDC write on
    // the bus every time someone tried a position out.
    for name in [PrefName.hudPositionBrightness, .hudPositionVolume, .hudStyle] {
      #expect(PrefPropagation.effects(forChange: name) == [.refreshUI])
    }
  }

  @Test func synthesisPrefsRefreshTheUIAndNothingElse() {
    // Same answer as the remembered-mode rows (SS11): the caller does the
    // verified engine work AROUND the write, so a row fanning out to display
    // work would run it again, unsequenced, from the pref edit.
    for name in [PrefName.offerSyntheticSizes, .storedSyntheticSize] {
      #expect(PrefPropagation.effects(forChange: name) == [.refreshUI], "\(name.rawValue)")
    }
  }
}
