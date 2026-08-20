import CandelaKit
import SwiftUI

/// Targeting & Precision, pushed from Keyboard (KMR6): the set-once controls,
/// moved verbatim from the pane root. Same bindings, same captions, same
/// disable-with-family rules; every write still goes pref then
/// `prefDidChange` with a `PrefName` case (D27).
///
/// `@MainActor` is load-bearing: `SettingsActions` is `@MainActor`, and a
/// plain `struct … : View` has nonisolated stored and computed properties
/// under Swift 6 complete concurrency.
@MainActor
struct KeyboardTargetingPage: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // `.refreshUI` (on every known PrefName) is the ONLY invalidation signal
    // this page has; `DisplayPrefs` is plain UserDefaults and not observable.
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
            rowNote("Window focus may not resolve correctly for full-screen apps.")
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

  /// A sentence qualifying the row it follows, drawn the way `SettingRow` draws
  /// its own caption: small and faint, so the two kinds of qualifier in one card
  /// carry the same weight. Callers standing it alone on the card add the
  /// row's bottom padding; inside a row the row already has it.
  private func rowNote(_ sentence: LocalizedStringKey) -> some View {
    SettingsCaption(sentence)
      .text
      .font(.caption)
      .foregroundStyle(SettingsTheme.faintColor)
      .fixedSize(horizontal: false, vertical: true)
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
        .prefIdentifier(.useFineScaleBrightness)
        .disabled(prefs.keyboardBrightness == .disabled)
      }

      SettingsCardDivider()

      // D25: the fork's "Fine OSD scale for…" leaked internal vocabulary. "On-screen
      // indicator" is the house term for the HUD across this pane and the Displays pane.
      SettingRow("A key press normally moves one notch of the on-screen indicator, and holding Shift and Option moves a quarter of that. Turning these on swaps the two, so every press is fine by default.") {
        Toggle("Fine steps for volume", isOn: Binding(
          get: { prefs.useFineScaleVolume },
          set: { setFineScaleVolume($0) }
        ))
        .themedSwitch()
        .prefIdentifier(.useFineScaleVolume)
        .disabled(prefs.keyboardVolume == .disabled)
      }
      rowNote("Custom shortcuts have no modifiers of their own, so they always use the step size selected here.")
        .padding(.bottom, 6)

      SettingsCardDivider()

      // A1 relitigated D26 for this one: it is a key-step setting, which is
      // what this section is, and the decision behind it ("how far does one
      // press move while a display is dimming past its minimum") is one a
      // person can make. `separateCombinedScale` stays app-level and stays a
      // documented `defaults write` key.
      // "A normal press" is load-bearing, not hedging: `DimmingMath.step`
      // branches on `isFine` BEFORE it reads the chiclet count, so a fine step
      // is a flat ±0.01 on both scales and this toggle does nothing to it.
      // With "Fine steps for brightness and contrast" on two rows above, that
      // is every press; a caption promising otherwise would contradict its
      // own neighbour (the D11 defect class).
      SettingRow("Halves how far a normal press moves on a display that is dimming past its minimum; fine steps are unchanged.") {
        Toggle("Extra-fine steps while combined dimming is active", isOn: Binding(
          get: { prefs.separateCombinedScale },
          set: { setSeparateCombinedScale($0) }
        ))
        .themedSwitch()
        .prefIdentifier(.separateCombinedScale)
        .disabled(prefs.keyboardBrightness == .disabled)
      }
    }
  }

  // MARK: - Writes
  //
  // Every write goes pref → `prefDidChange`, and the name argument is a
  // `PrefName` case, never a string (D27). Moved with their controls from the
  // pane root (KMR6); bodies unchanged.

  /// Deliberately inert in the engine: the executor reads this live per press,
  /// so the row is `.refreshUI` alone. The call site still exists; the page
  /// must not be the one place that decides a pref needs no propagation.
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
  /// scale is read at event time on every press (fork bug 3 closed by
  /// construction, D2).
  private func setFineScaleBrightness(_ fine: Bool) {
    prefs.useFineScaleBrightness = fine
    actions.prefDidChange(.useFineScaleBrightness)
  }

  private func setFineScaleVolume(_ fine: Bool) {
    prefs.useFineScaleVolume = fine
    actions.prefDidChange(.useFineScaleVolume)
  }

  /// No `persistenceKey:`, like every other write in this page. The parameter
  /// is not a defaults domain: it is a FILTER on which display's controller
  /// `.reapplyDimming` reaches (`SettingsActions.apply`), and `separateCombinedScale`
  /// is app-level, so `"app"` would match zero displays and silently swallow a
  /// future reapply row. The row is `.refreshUI` alone today because
  /// `BrightnessController.step` reads the pref at key time (D20).
  private func setSeparateCombinedScale(_ separate: Bool) {
    prefs.separateCombinedScale = separate
    actions.prefDidChange(.separateCombinedScale)
  }
}
