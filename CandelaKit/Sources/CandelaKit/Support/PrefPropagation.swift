/// The closed set of pref names the settings UI may write (D27).
///
/// Raw values ARE the on-disk key names, UNSUFFIXED: per-display prefs are
/// named `forceSw`, never `forceSw.<pk>`, and per-command prefs are named
/// `unavailableDDC`, never `unavailableDDC.volume.<pk>`. The caller scopes
/// per-display effects with a persistence key; `DisplayPrefs` composes the
/// real key.
///
/// Membership rule — a name belongs here when some pane writes it, or when a
/// batch write needs its effects unioned in. Deliberate exclusions:
/// - `muted`, `hdrMode`: engine state, not settings (D8/D22). `hdrMode` must
///   go through `BrightnessController.setHDRMode`.
/// - `menuItemStyle`, `showTickMarks`, `longerDelay`: reserved keys with no
///   reader anywhere in Candela (D32). A row for them would be a lie.
/// - `pollingMode`, `pollingCount`: read at DDC-read time; nothing to fan out.
/// - `separateCombinedScale`: read only inside `step()`, at key time.
/// - `oledPanelSeconds`, `oledStandbySeconds`: accumulated usage written by the
///   hours tracker — engine state, not a setting (same rule as `muted`).
public enum PrefName: String, Sendable, CaseIterable {
  // App-level — panel and menu-bar presentation
  case menuIcon, hideBuiltInDisplay, showContrast
  case enableSliderSnap, enableSliderPercent
  // App-level — dimming
  case disableCombinedBrightness, allowZeroSwBrightness, enableBrightnessSync, startupAction
  // App-level — keyboard
  case keyboardBrightness, keyboardVolume, disableAltBrightnessKeys
  case multiKeyboardBrightness, multiKeyboardVolume
  case useFineScaleBrightness, useFineScaleVolume
  // Per-display
  case friendlyName, hideDisplay, isDisabled, hideVolumeSlider, hideOsd
  case forceSw, avoidGamma, combinedSwitchingPoint
  case enableMuteUnmute, audioSinkOverride, audioDeviceNameOverride
  // Per-display — display configuration (W2 SP1)
  case rememberDisplayMode, storedDisplayMode
  // Per-display — OLED care (W3a). The accessor defaults ARE the Recommended
  // preset. Two of these are the exception to the "raw values ARE the key
  // names" rule above: `oledLockDim` and `oledHoursTracking` default to TRUE
  // and so store INVERTED, under `oledLockDimOff`/`oledHoursTrackingOff`. The
  // case names stay positive because a PrefName is a propagation identifier,
  // not a key (precedent: the `forceSw` accessor is named `forceSoftware`).
  case oledCareEnrolled, oledIdleDimSeconds, oledIdleDimLevel, oledLockDim
  case oledBlackoutEnabled, oledBlackoutSeconds
  case oledUnfocusedDimEnabled, oledUnfocusedDimSeconds, oledUnfocusedDimLevel
  case oledHoursTracking
  // App-level — display arrangement (#13). `savedArrangements` names a FAMILY
  // of keys, one per topology signature, the way `storedDisplayMode` names one
  // per display identity — a layout is a statement about a display SET, not
  // about a display.
  case restoreArrangement, savedArrangements
  // Per-command (base names; `DisplayPrefs.setTuning` adds the `.<cmd>` part)
  case unavailableDDC, minDDCOverride, maxDDCOverride, curveDDC, invertDDC, remapDDC
}

/// Engine work a pref edit fans out to (D20). The settings UI writes a pref,
/// then asks this table what must happen — never ad-hoc calls per control.
public enum PrefEffect: Sendable, Hashable {
  /// Re-evaluate every view bound to this pref. EVERY known pref carries it:
  /// panes bind two-way to `DisplayPrefs`, which is plain `UserDefaults` and
  /// not observable, so `AppModel.prefsRevision` is the only invalidation.
  case refreshUI
  case rearmTap // media-key tap config re-evaluation
  case reapplyDimming // BrightnessController.reapplyAfterPrefChange() (D28)
  case rebuildPanel // this pref also changes what the menu-bar panel renders
  case updateStatusItem // status-item visibility re-evaluation
  case recheckPermissions // Accessibility prompt re-check
  /// `OledCareCoordinator.reapplyAfterPrefChange()`: re-arm the idle/blackout
  /// timers and re-evaluate the care dim. Distinct from `.reapplyDimming` —
  /// OLED care owns its own dimming leg and must not drag the DDC bus.
  case reapplyOledCare
}

public enum PrefPropagation {
  /// The row for one pref.
  ///
  /// Implemented as an EXHAUSTIVE switch on purpose: adding a `PrefName` case
  /// without giving it a row is a compile error, not a silent empty set.
  public static func effects(forChange name: PrefName) -> Set<PrefEffect> {
    // `.refreshUI` is unioned in below, so each row lists only engine work.
    let engine: Set<PrefEffect> = switch name {
    case .menuIcon, .hideBuiltInDisplay, .hideDisplay:
      // Status-item visibility is a function of `menuIcon` AND whether any
      // slider is visible (`MenuIconPolicy.isStatusItemVisible`), and
      // `hasVisibleSlider` derives from these two hide prefs.
      [.rebuildPanel, .updateStatusItem]

    case .showContrast, .enableSliderSnap, .enableSliderPercent,
         .hideVolumeSlider, .friendlyName, .isDisabled, .hideOsd,
         .audioSinkOverride, .enableBrightnessSync:
      [.rebuildPanel]

    case .audioDeviceNameOverride:
      // Feeds `AppModel.audioMatchingDisplays`, i.e. `tapConfig`.
      [.rebuildPanel, .rearmTap]

    case .rememberDisplayMode, .storedDisplayMode:
      // Reapply happens at launch and reconnect only, never on the pref write
      // itself (DM7) — writing the pref must not yank the user's screen.
      // `.refreshUI` is unioned in below and is the whole row.
      []

    case .restoreArrangement, .savedArrangements:
      // The same answer as the mode rows above, for the same reason: a layout is
      // restored when displays ARRIVE, never on the pref write itself, so
      // turning the switch on must not rearrange anyone's screens under them.
      // The failure that would cause is worse than the mode one — the menu bar
      // and the Dock follow whichever display ends up at the origin.
      // `.refreshUI` is unioned in below and is the whole row.
      []

    case .enableMuteUnmute, .startupAction, .multiKeyboardBrightness,
         .useFineScaleBrightness, .useFineScaleVolume:
      // Read at key time / launch time. `.refreshUI` alone is the whole row —
      // that is a deliberate answer, not a missing one.
      []

    case .keyboardBrightness, .keyboardVolume:
      [.rearmTap, .recheckPermissions]

    case .disableAltBrightnessKeys, .multiKeyboardVolume:
      [.rearmTap]

    case .disableCombinedBrightness, .allowZeroSwBrightness, .combinedSwitchingPoint,
         .minDDCOverride, .maxDDCOverride, .curveDDC, .invertDDC, .remapDDC:
      [.reapplyDimming]

    case .avoidGamma, .unavailableDDC:
      // Both change what the panel shows as well: the control-method caption,
      // and whether a slider renders at all.
      [.reapplyDimming, .rebuildPanel]

    case .forceSw:
      [.reapplyDimming, .rebuildPanel, .rearmTap]

    case .oledCareEnrolled, .oledIdleDimSeconds, .oledIdleDimLevel, .oledLockDim,
         .oledBlackoutEnabled, .oledBlackoutSeconds,
         .oledUnfocusedDimEnabled, .oledUnfocusedDimSeconds, .oledUnfocusedDimLevel,
         .oledHoursTracking:
      [.reapplyOledCare]
    }
    return engine.union([.refreshUI])
  }

  /// The union of several rows — for a batch write that must fan out exactly
  /// once (the per-display reset in Task 14). Empty input means no effects,
  /// so a caller with nothing to write does nothing.
  public static func effects(forChanges names: [PrefName]) -> Set<PrefEffect> {
    names.reduce(into: Set<PrefEffect>()) { $0.formUnion(effects(forChange: $1)) }
  }
}
