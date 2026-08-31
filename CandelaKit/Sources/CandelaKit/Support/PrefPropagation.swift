/// The closed set of pref names the settings UI may write (D27).
///
/// Raw values ARE the on-disk key names, UNSUFFIXED: per-display prefs are
/// named `forceSw`, never `forceSw.<pk>`, and per-command prefs are named
/// `unavailableDDC`, never `unavailableDDC.volume.<pk>`. The caller scopes
/// per-display effects with a persistence key; `DisplayPrefs` composes the
/// real key.
///
/// A name belongs here when some pane writes it, or when a batch write needs its
/// effects unioned in. Deliberate exclusions:
/// - `muted`, `hdrMode`: engine state, not settings (D8/D22). `hdrMode` must go
///   through `BrightnessController.setHDRMode`.
/// - `menuItemStyle`, `showTickMarks`, `longerDelay`: reserved keys with no reader
///   anywhere in Candela (D32). A row for them would be a lie.
/// - `oledPanelSeconds`, `oledStandbySeconds`, `oledStandbyNoteDismissed`: written by
///   the hours tracker, so engine state, same rule as `muted`.
///
/// Prefs read at use rather than at write time are still cases (D27 makes a written
/// pref a case); they fan out to `refreshUI` alone.
public enum PrefName: String, Sendable, CaseIterable {
  // App-level: panel and menu-bar presentation
  case menuIcon, hideBuiltInDisplay, showContrast
  // App-level: the panel's Keep Display Awake row, for a more minimal panel.
  // Hide-shaped like `hideBuiltInDisplay`, so an absent key means shown.
  case hideKeepAwake
  // App-level: the panel's "All displays" brightness row, same hide shape.
  case hideCombinedBrightness
  case enableSliderSnap, enableSliderPercent
  // App-level: where the on-screen indicator pills sit. Two keys so each KIND gets a
  // stable home of its own. Not a way to see both at once, which the island's
  // one-window-per-display keying rules out either way.
  case hudPositionBrightness, hudPositionVolume
  // App-level: how every pill draws (KMR-A3). One key for all kinds, since the
  // styles differ in anatomy rather than in per-kind meaning.
  case hudStyle
  // App-level: dimming
  case disableCombinedBrightness, allowZeroSwBrightness, enableBrightnessSync, startupAction
  case separateCombinedScale
  // App-level: keyboard
  case keyboardBrightness, keyboardVolume, disableAltBrightnessKeys
  case multiKeyboardBrightness, multiKeyboardVolume
  case useFineScaleBrightness, useFineScaleVolume
  // Per-display
  case friendlyName, hideDisplay, isDisabled, hideVolumeSlider, hideOsd
  case forceSw, avoidGamma, combinedSwitchingPoint
  case enableMuteUnmute, audioSinkOverride, audioDeviceNameOverride
  case pollingMode, pollingCount
  // Per-display: display configuration
  case rememberDisplayMode, storedDisplayMode
  // Per-display: synthesized sizes (SS4). The opt-in that makes synthesized rows
  // visible in the picker, and the stop the display is set to, stored as a JSON
  // descriptor the way `storedDisplayMode` is.
  case offerSyntheticSizes, storedSyntheticSize
  // Per-display: the density model's hub suggestion, closed by its own button. A
  // dismissal with a button is a setting; the OLED standby note's, written by the
  // hours tracker, is engine state and stays out.
  case sizeRecommendationDismissed
  // Per-display: OLED care. The accessor defaults ARE the Recommended preset. Two
  // of these are the exception to the "raw values ARE the key names" rule above:
  // `oledLockDim` and `oledHoursTracking` default to TRUE and so store INVERTED,
  // under `oledLockDimOff` and `oledHoursTrackingOff`. The case names stay positive
  // because a PrefName is a propagation identifier, not a key.
  case oledCareEnrolled, oledIdleDimSeconds, oledIdleDimLevel, oledLockDim
  case oledBlackoutEnabled, oledBlackoutSeconds
  case oledUnfocusedDimEnabled, oledUnfocusedDimSeconds, oledUnfocusedDimLevel
  case oledHoursTracking
  // `oledTelemetry` needs Screen Recording and so defaults OFF.
  // `oledWindowObservation` needs no permission and is the degraded mode's only data
  // source, so it defaults TRUE and joins the inverted-storage exception above.
  case oledTelemetry, oledWindowObservation
  // Detection-driven region dimming, off by default: the only care feature that
  // alters the screen during active use.
  case oledDetectionDimming
  // App-level: display arrangement. `savedArrangements` names a FAMILY of keys, one
  // per topology signature, because a layout is a statement about a display SET
  // rather than about a display.
  case restoreArrangement, savedArrangements
  // Per-command (base names; `DisplayPrefs.setTuning` adds the `.<cmd>` part)
  case unavailableDDC, minDDCOverride, maxDDCOverride, curveDDC, invertDDC, remapDDC
  // App-level: virtual display slots (VD14). Base names; `DisplayPrefs` composes the
  // real key with `.<slot>`. Only `virtualSlotConfigured` converges live displays,
  // so editing a running slot never yanks a display under the user (VD17).
  case virtualSlotConfigured, virtualSlotName, virtualSlotWidth, virtualSlotHeight
  case virtualSlotHiDPI, virtualSlotRefreshHz, virtualSlotRecreateAtLaunch, virtualSlotUUID
  // Whether the slot has a tile at all; Add/Remove write it alongside
  // `configured`, which carries the convergence.
  case virtualSlotDefined
}

/// Engine work a pref edit fans out to (D20). The settings UI writes a pref,
/// then asks this table what must happen, never ad-hoc calls per control.
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
  /// `OledCareCoordinator.reapplyAfterPrefChange()`: re-arm the idle and blackout
  /// timers and re-evaluate the care dim. Distinct from `.reapplyDimming`, because
  /// OLED care owns its own dimming leg and must not drag the DDC bus.
  case reapplyOledCare
  /// `AppModel.syncVirtualDisplays()`: run the reconciler and converge live
  /// virtual displays to the slot prefs (VD14). Carried by
  /// `virtualSlotConfigured` alone.
  case syncVirtualDisplays
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
         .enableBrightnessSync, .hideKeepAwake, .hideCombinedBrightness:
      // `hideKeepAwake` is presentation alone: hiding the row while keep awake is ON
      // leaves the display awake, which the Menu Bar pane's caption says out loud.
      // `isDisabled` carries no `.rearmTap` deliberately: a display whose keyboard
      // control is off swallows its press (R1) rather than handing it to macOS, so
      // it must leave the watched set alone.
      [.rebuildPanel]

    case .audioDeviceNameOverride:
      // Feeds `AppModel.audioMatchingDisplays`, i.e. `tapConfig`.
      [.rebuildPanel, .rearmTap]

    case .audioSinkOverride:
      // The user's half of the volume verdict. It greys the slider AND decides
      // whether a volume or mute key can act on this display, and the tap now
      // arms on that: an override that leaves no display able to act releases
      // the keys to macOS.
      [.rebuildPanel, .rearmTap]

    case .rememberDisplayMode, .storedDisplayMode:
      // Reapply happens at launch and reconnect only, never on the pref write itself
      // (DM7): writing the pref must not yank the user's screen.
      []

    case .offerSyntheticSizes, .storedSyntheticSize:
      // No display work on the write, the same answer the mode rows give. SS11 puts
      // a VERIFIED engine disengage before the opt-in is written false, and the
      // engage before the stop is stored, so the sequencing is the caller's and a row
      // here would re-run it out of order.
      []

    case .restoreArrangement, .savedArrangements:
      // The same answer as the mode rows above: a layout is restored when displays
      // ARRIVE, never on the pref write, so turning the switch on must not rearrange
      // anyone's screens under them. Worse than the mode case, since the menu bar and
      // the Dock follow whichever display ends up at the origin.
      []

    case .virtualSlotConfigured:
      // The one write that converges live virtual displays (VD14). The pane's
      // Create, Apply and Remove buttons all end in this write.
      [.syncVirtualDisplays]

    case .virtualSlotName, .virtualSlotWidth, .virtualSlotHeight, .virtualSlotHiDPI,
         .virtualSlotRefreshHz, .virtualSlotRecreateAtLaunch, .virtualSlotUUID,
         .virtualSlotDefined:
      // Field edits apply on the next Create or Apply (VD17), so `.refreshUI` alone
      // is a deliberate answer rather than a missing one.
      []

    case .sizeRecommendationDismissed:
      // Closing the suggestion changes what one settings row renders and nothing
      // else. No display work of any kind, or a "not now" would move the screen.
      []

    case .startupAction, .multiKeyboardBrightness,
         .useFineScaleBrightness, .useFineScaleVolume,
         .pollingMode, .pollingCount, .separateCombinedScale,
         .hudPositionBrightness, .hudPositionVolume, .hudStyle:
      // Read at key time, launch time or DDC-read time, so `.refreshUI` alone is a
      // deliberate answer and not a missing one. `KeyActionExecutor` reads the two
      // indicator positions as it announces a pill, so the next press uses the new
      // one and a pill already on screen keeps where it was drawn.
      []

    case .enableMuteUnmute:
      // Read at key time as well, but it also SELECTS the register the mute key
      // writes (0x8D with it, the volume register without it), and the tap arms on
      // that register's verdict, so flipping it hands the mute key to macOS or back.
      [.rearmTap]

    case .keyboardBrightness, .keyboardVolume:
      [.rearmTap, .recheckPermissions]

    case .disableAltBrightnessKeys, .multiKeyboardVolume:
      [.rearmTap]

    case .disableCombinedBrightness, .allowZeroSwBrightness, .combinedSwitchingPoint,
         .minDDCOverride, .maxDDCOverride, .curveDDC, .invertDDC, .remapDDC:
      [.reapplyDimming]

    case .avoidGamma:
      // Changes what the panel shows as well: the control-method caption.
      [.reapplyDimming, .rebuildPanel]

    case .unavailableDDC:
      // The same two, plus the tap: the engine checks this before any DDC write, so
      // turning the volume command off leaves nothing for a volume or mute key to do
      // and the keys go to macOS. One pref covers all three commands, so a brightness
      // or contrast flip re-arms too: idempotent, and cheaper than a per-command row
      // kept in step with which commands the tap reads.
      [.reapplyDimming, .rebuildPanel, .rearmTap]

    case .forceSw:
      [.reapplyDimming, .rebuildPanel, .rearmTap]

    case .oledCareEnrolled, .oledIdleDimSeconds, .oledIdleDimLevel, .oledLockDim,
         .oledBlackoutEnabled, .oledBlackoutSeconds,
         .oledUnfocusedDimEnabled, .oledUnfocusedDimSeconds, .oledUnfocusedDimLevel,
         .oledHoursTracking, .oledTelemetry, .oledWindowObservation,
         .oledDetectionDimming:
      // `.reapplyOledCare` and NOT `.reapplyDimming` (D28): every pref here changes
      // what the care overlay renders, which is the app's own window, and none of
      // them touches the DDC or gamma leg. Adding `.reapplyDimming` would drive a
      // brightness write on a toggle that has nothing to say about brightness.
      [.reapplyOledCare]
    }
    return engine.union([.refreshUI])
  }

  /// The union of several rows, for a batch write that must fan out exactly once.
  /// Empty input means no effects, so a caller with nothing to write does nothing.
  public static func effects(forChanges names: [PrefName]) -> Set<PrefEffect> {
    names.reduce(into: Set<PrefEffect>()) { $0.formUnion(effects(forChange: $1)) }
  }
}
