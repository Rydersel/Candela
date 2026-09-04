import CandelaKit
import SwiftUI

/// Targeting & Precision, pushed from Keyboard: the set-once controls.
/// Every write goes pref then `prefDidChange` with a `PrefName` case.
///
/// `@MainActor` is load-bearing: `SettingsActions` is `@MainActor`, and a plain
/// `struct … : View` has nonisolated properties under Swift 6 complete
/// concurrency.
@MainActor
struct KeyboardTargetingPage: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // `.refreshUI` is the ONLY invalidation signal this page has;
    // `DisplayPrefs` is plain UserDefaults and not observable.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SubPageHeader(
        title: KeyboardPage.targeting.title,
        currentKey: "", displays: [], onSwitch: { _ in })

      targetSection
      precisionSection
    }
  }

  // MARK: - Targeting

  @ViewBuilder private var targetSection: some View {
    SettingsCardSection(title: "Target Display") {
      SettingRow {
        VStack(alignment: .leading, spacing: 6) {
          ThemedChoiceRow(label: "Brightness keys affect:", selection: Binding(
            get: { prefs.multiKeyboardBrightness },
            set: { setBrightnessTarget($0) }
          )) {
            Text("The display under the pointer").tag(MultiKeyboardBrightness.mouse)
            Text("Every display").tag(MultiKeyboardBrightness.allScreens)
            Text("The display with the active window").tag(MultiKeyboardBrightness.focusInsteadOfMouse)
          }
          .prefIdentifier(.multiKeyboardBrightness)
          .disabled(prefs.keyboardBrightness == .disabled)
          if prefs.multiKeyboardBrightness == .focusInsteadOfMouse {
            SettingsRowNote("Window focus may not resolve correctly for full-screen apps.")
          }
        }
      }

      SettingsCardDivider()

      SettingRow(volumeTargetCaption) {
        ThemedChoiceRow(label: "Volume keys affect:", selection: Binding(
          get: { prefs.multiKeyboardVolume },
          set: { setVolumeTarget($0) }
        )) {
          Text("The display under the pointer").tag(MultiKeyboardVolume.mouse)
          Text("Every display").tag(MultiKeyboardVolume.allScreens)
          Text("The display matching the audio output device").tag(MultiKeyboardVolume.audioDeviceNameMatching)
        }
        .prefIdentifier(.multiKeyboardVolume)
        .disabled(prefs.keyboardVolume == .disabled)
      }
    }
  }

  private var volumeTargetCaption: LocalizedStringKey {
    prefs.multiKeyboardVolume == .audioDeviceNameMatching
      ? "Matches on the display's name, which you can override under Sound on that display's page."
      : "Applies when the selected audio device has no volume control of its own."
  }

  // MARK: - Precision

  @ViewBuilder private var precisionSection: some View {
    SettingsCardSection(title: "Precision") {
      SettingRow {
        Toggle("Fine steps for brightness and contrast", isOn: Binding(
          get: { prefs.useFineScaleBrightness },
          set: { setFineScaleBrightness($0) }
        ))
        .themedSwitch()
        .accessibilityLabel("Fine steps for brightness and contrast")
        .prefIdentifier(.useFineScaleBrightness)
        .disabled(prefs.keyboardBrightness == .disabled)
      }

      SettingsCardDivider()

      // The fork's "Fine OSD scale for…" leaked internal vocabulary.
      // "On-screen indicator" is the house term for the HUD.
      SettingRow("A key press normally moves one notch of the on-screen indicator, and holding Shift and Option moves a quarter of that. Turning these on swaps the two, so every press is fine by default.") {
        Toggle("Fine steps for volume", isOn: Binding(
          get: { prefs.useFineScaleVolume },
          set: { setFineScaleVolume($0) }
        ))
        .themedSwitch()
        .accessibilityLabel("Fine steps for volume")
        .prefIdentifier(.useFineScaleVolume)
        .disabled(prefs.keyboardVolume == .disabled)
      }
      SettingsRowNote("Custom shortcuts have no modifiers of their own, so they always use the step size selected here.")

      SettingsCardDivider()

      // Relitigated here: it is a key-step setting and the
      // decision behind it is one a person can make. `separateCombinedScale`
      // stays app-level and stays a documented `defaults write` key.
      // "A normal press" is load-bearing, not hedging: `DimmingMath.step`
      // branches on `isFine` BEFORE it reads the chiclet count, so a fine step
      // is a flat ±0.01 on both scales and this toggle does nothing to it.
      SettingRow("Halves how far a normal press moves on a display that is dimming past its minimum; fine steps are unchanged.") {
        Toggle("Extra-fine steps while combined dimming is active", isOn: Binding(
          get: { prefs.separateCombinedScale },
          set: { setSeparateCombinedScale($0) }
        ))
        .themedSwitch()
        .accessibilityLabel("Extra-fine steps while combined dimming is active")
        .prefIdentifier(.separateCombinedScale)
        .disabled(prefs.keyboardBrightness == .disabled)
      }
    }
  }

  // MARK: - Writes
  //
  // Every write goes pref → `prefDidChange`, and the name argument is a
  // `PrefName` case, never a string.

  /// Inert in the engine: the executor reads this live per press, so the row is
  /// `.refreshUI` alone. The call site still exists, because the page must not
  /// be the one place that decides a pref needs no propagation.
  private func setBrightnessTarget(_ target: MultiKeyboardBrightness) {
    prefs.multiKeyboardBrightness = target
    actions.prefDidChange(.multiKeyboardBrightness)
  }

  /// Unlike the brightness target, this one feeds `AppModel.tapConfig` through
  /// `volumeMode`, so its row carries `.rearmTap`.
  private func setVolumeTarget(_ target: MultiKeyboardVolume) {
    prefs.multiKeyboardVolume = target
    actions.prefDidChange(.multiKeyboardVolume)
  }

  /// No `.rearmTap` row, and that is correct rather than missing:
  /// `KeyRouterConfig` is built INSIDE the tap's press closure, so the fine
  /// scale is read at event time on every press (fork bug 3).
  private func setFineScaleBrightness(_ fine: Bool) {
    prefs.useFineScaleBrightness = fine
    actions.prefDidChange(.useFineScaleBrightness)
  }

  private func setFineScaleVolume(_ fine: Bool) {
    prefs.useFineScaleVolume = fine
    actions.prefDidChange(.useFineScaleVolume)
  }

  /// No `persistenceKey:`. The parameter is not a defaults domain: it is a
  /// FILTER on which display's controller `.reapplyDimming` reaches
  /// (`SettingsActions.apply`), and `separateCombinedScale` is app-level, so
  /// `"app"` would match zero displays and silently swallow a future reapply
  /// row. `.refreshUI` alone today because `BrightnessController.step` reads the
  /// pref at key time.
  private func setSeparateCombinedScale(_ separate: Bool) {
    prefs.separateCombinedScale = separate
    actions.prefDidChange(.separateCombinedScale)
  }
}
