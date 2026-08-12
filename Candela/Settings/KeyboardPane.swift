import CandelaKit
import KeyboardShortcuts
import SwiftUI

/// Keyboard input settings: which machinery each key family engages, the custom
/// shortcut recorders, which display the keys act on, and the step size.
///
/// Layout follows the HIG's reading-order rule (layout.md): the Accessibility
/// warning is the pane's most important state, so it sits at the TOP — a mode
/// that wants the media-key tap does nothing at all without the grant, and
/// every control below it is inert until that is fixed.
///
/// `@MainActor` is load-bearing: `SettingsActions` is
/// `@MainActor`, and a plain `struct … : View` has nonisolated stored and
/// computed properties under Swift 6 complete concurrency.
@MainActor
struct KeyboardPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // `.refreshUI` (on every known PrefName) is the ONLY invalidation signal
    // this pane has — `DisplayPrefs` is plain UserDefaults and not observable.
    // Without this reference `body` never re-evaluates after a picker writes,
    // so the recorder rows below would never appear and the picker would look
    // like it snapped back.
    let _ = model.prefsRevision
    Form {
      accessibilitySection
      brightnessSection
      modifierSection
      volumeSection
      targetSection
      precisionSection
    }
    .formStyle(.grouped)
  }

  // MARK: - Accessibility

  /// Shown only when a mode that actually needs the CGEvent tap is selected
  /// AND the grant is missing. Custom shortcuts are Carbon hotkeys and work
  /// without the grant (`KeyModePolicy.requiresAccessibility`), so an
  /// all-custom rig is never warned about a permission it does not use — the
  /// same gate as on `SettingsActions.recheckPermissions`.
  ///
  /// `AppModel.accessibility` polls while the grant is missing, so this row
  /// clears itself the moment the grant appears — no reopen, no relaunch.
  ///
  /// The predicate is `AccessibilityPermission.isWarningWarranted`, the SAME
  /// property the panel's banner gates on, not a second local copy of the rule.
  /// Two implementations of one rule is exactly how the pane and the banner end
  /// up disagreeing on an all-custom rig.
  @ViewBuilder private var accessibilitySection: some View {
    if model.accessibility.isWarningWarranted {
      Section {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          // Symbol AND text: the state is never signalled by color alone
          // (color.md, inclusive color). No custom color — the row is
          // monochrome in both appearances.
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text("Keyboard control needs Accessibility access")
            SettingsCaption(
              "\(AppInfo.productName) watches the brightness and volume keys through the system event tap, which macOS gates behind Accessibility. Custom shortcuts work without it."
            )
          }
          Spacer(minLength: 8)
          // Trailing ellipsis: this button opens another app (buttons.md).
          Button("Open System Settings…") {
            AccessibilityPermission.openSystemSettings()
          }
          .accessibilityLabel("Open System Settings…")
        }
      }
    }
  }

  // MARK: - Brightness

  @ViewBuilder private var brightnessSection: some View {
    Section("Brightness and Contrast Keys") {
      // Explicit enum tags, never `enumerated()` positions (fork QUIRK): the
      // raw values are shipped on-disk schema (D22) and the UI order is not
      // the raw order.
      Picker("Control brightness with:", selection: Binding(
        get: { prefs.keyboardBrightness },
        set: { setBrightnessMode($0) }
      )) {
        Text("The keyboard's brightness keys").tag(KeyMode.media)
        Text("Custom shortcuts").tag(KeyMode.custom)
        Text("Both").tag(KeyMode.both)
        // D25: the fork's "Disable keyboard" disables no keyboard — it stops
        // THIS APP from handling one key family. Under a "Control brightness
        // with:" row label the honest item is "Nothing".
        Text("Nothing").tag(KeyMode.disabled)
      }

      if KeyModePolicy.firesCustomShortcuts(prefs.keyboardBrightness) {
        KeyboardShortcuts.Recorder("Brightness down:", name: .brightnessDown)
        KeyboardShortcuts.Recorder("Brightness up:", name: .brightnessUp)
        KeyboardShortcuts.Recorder("Contrast down:", name: .contrastDown)
        SettingRow(Self.modifierHint) {
          KeyboardShortcuts.Recorder("Contrast up:", name: .contrastUp)
        }
        SettingsCaption("Contrast works on displays controlled over their data cable (DDC) only.")
      }

      if KeyModePolicy.watchesMediaKeys(prefs.keyboardBrightness) {
        SettingRow("F14 and F15 are Scroll Lock and Pause on PC keyboards, and the brightness keys on some Logitech keyboards.") {
          Toggle("Also accept F14 and F15", isOn: Binding(
            get: { prefs.interceptAlternateBrightnessKeys }, // D1 positive accessor
            set: { setInterceptAlternateKeys($0) }
          ))
        }
      }
    }
  }

  // MARK: - Modifier keys

  /// The two prose captions that used to explain the modifiers, as one row per
  /// mapping (spec §8, SO16 — each row's spoken label IS the sentence it
  /// replaced, so nothing a screen reader could hear was lost by the change).
  ///
  /// Gated on `watchesMediaKeys`, i.e. shown for "Both" as well as for the
  /// media-key mode — the fork hid this documentation under "Both" while the
  /// modifiers stayed live (ch.1 QUIRK, fixed). Deliberately NOT shown for
  /// "Custom shortcuts": `AppModel.tapConfig` puts no brightness key in the
  /// watched set in that mode, so the physical keys go to macOS and every
  /// combination below would be describing something that cannot happen.
  /// A shortcut carries its own fixed modifiers and none of these rules reach
  /// it — `KeyRouter` routes `MediaKeyPress` only.
  @ViewBuilder private var modifierSection: some View {
    if KeyModePolicy.watchesMediaKeys(prefs.keyboardBrightness) {
      Section("Modifier Keys") {
        ModifierLegendRow(
          title: "Built-in display",
          combination: "⌃ + brightness key",
          spoken: "Control plus a brightness key adjusts the built-in display."
        )
        ModifierLegendRow(
          title: "All external displays",
          combination: "⌃⌘ + brightness key",
          spoken: "Control Command plus a brightness key adjusts every external display."
        )
        // Kept from the deleted prose: the contrast combination is documented
        // nowhere else in the pane, unlike the fine-step modifiers, which the
        // Precision section below still spells out.
        ModifierLegendRow(
          title: "Contrast",
          combination: "⌃⌥⌘ + brightness key",
          spoken: "Control Option Command plus a brightness key adjusts contrast."
        )
        // "+ brightness key" is accuracy, not column symmetry: `KeyRouter`
        // rule 2 needs a brightness key, and Option on a VOLUME key opens Sound
        // settings instead (`routeVolume`).
        ModifierLegendRow(
          title: "Open Displays settings",
          combination: "⌥ + brightness key",
          spoken: "Option with a brightness key opens Displays settings."
        )
        // Its own row, not a variation on the ones above: it is a different
        // action on a specific key, and `KeyRouter` rule 1 treats it that way.
        ModifierLegendRow(
          title: "Toggle mirroring",
          combination: "⌘ + brightness down",
          spoken: "Command with the brightness-down key switches mirroring on or off."
        )
      }
    }
  }

  // MARK: - Volume

  @ViewBuilder private var volumeSection: some View {
    Section("Volume Keys") {
      SettingRow("Volume applies to external displays that accept volume commands over their data cable (DDC).") {
        Picker("Control volume with:", selection: Binding(
          get: { prefs.keyboardVolume },
          set: { setVolumeMode($0) }
        )) {
          Text("The keyboard's volume and mute keys").tag(KeyMode.media)
          Text("Custom shortcuts").tag(KeyMode.custom)
          Text("Both").tag(KeyMode.both)
          Text("Nothing").tag(KeyMode.disabled)
        }
      }

      if KeyModePolicy.firesCustomShortcuts(prefs.keyboardVolume) {
        KeyboardShortcuts.Recorder("Volume down:", name: .volumeDown)
        KeyboardShortcuts.Recorder("Volume up:", name: .volumeUp)
        SettingRow(Self.modifierHint) {
          KeyboardShortcuts.Recorder("Mute:", name: .mute)
        }
      }

      if KeyModePolicy.watchesMediaKeys(prefs.keyboardVolume) {
        SettingsCaption("The volume keys go to macOS instead whenever the current audio output device has a volume control of its own, or when no connected display can take a volume command. Option on its own opens Sound settings.")
      }
    }
  }

  /// Why a bare letter looks like it does nothing.
  ///
  /// A recorder silently ignores a key pressed without a modifier, which reads
  /// as a broken control — press "k", nothing happens, conclude the field is
  /// dead. The rule is not arbitrary: these are system-wide hotkeys, so a
  /// bare key would capture that key in every other app.
  private static let modifierHint: LocalizedStringKey =
    "Click a field and press the keys you want. A shortcut has to include ⌘, ⌃, ⌥ or ⇧. A letter or number on its own is ignored, because it would be captured in every app."

  // MARK: - Targeting

  @ViewBuilder private var targetSection: some View {
    Section("Target Display") {
      SettingRow {
        Picker("Brightness keys affect:", selection: Binding(
          get: { prefs.multiKeyboardBrightness },
          set: { setBrightnessTarget($0) }
        )) {
          Text("The display under the pointer").tag(MultiKeyboardBrightness.mouse)
          Text("Every display").tag(MultiKeyboardBrightness.allScreens)
          Text("The display with the active window").tag(MultiKeyboardBrightness.focusInsteadOfMouse)
        }
        .disabled(prefs.keyboardBrightness == .disabled)
        if prefs.multiKeyboardBrightness == .focusInsteadOfMouse {
          SettingsCaption("Window focus may not resolve correctly for full-screen apps.")
        }
      }

      SettingRow(volumeTargetCaption) {
        Picker("Volume keys affect:", selection: Binding(
          get: { prefs.multiKeyboardVolume },
          set: { setVolumeTarget($0) }
        )) {
          Text("The display under the pointer").tag(MultiKeyboardVolume.mouse)
          Text("Every display").tag(MultiKeyboardVolume.allScreens)
          Text("The display matching the audio output device").tag(MultiKeyboardVolume.audioDeviceNameMatching)
        }
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
    Section("Precision") {
      Toggle("Fine steps for brightness and contrast", isOn: Binding(
        get: { prefs.useFineScaleBrightness },
        set: { setFineScaleBrightness($0) }
      ))
      .disabled(prefs.keyboardBrightness == .disabled)

      // D25: the fork's "Fine OSD scale for…" leaked internal vocabulary. "On-screen
      // indicator" is the house term for the HUD across this pane and the Displays pane.
      SettingRow("A key press normally moves one notch of the on-screen indicator, and holding Shift and Option moves a quarter of that. Turning these on swaps the two, so every press is fine by default.") {
        Toggle("Fine steps for volume", isOn: Binding(
          get: { prefs.useFineScaleVolume },
          set: { setFineScaleVolume($0) }
        ))
        .disabled(prefs.keyboardVolume == .disabled)
      }
      SettingsCaption("Custom shortcuts have no modifiers of their own, so they always use the step size selected here.")

      // A1 relitigated D26 for this one: it is a key-step setting, which is
      // what this section is, and the decision behind it ("how far does one
      // press move while a display is dimming past its minimum") is one a
      // person can make. `separateCombinedScale` stays app-level and stays a
      // documented `defaults write` key.
      // "A normal press" is load-bearing, not hedging: `DimmingMath.step`
      // branches on `isFine` BEFORE it reads the chiclet count, so a fine step
      // is a flat ±0.01 on both scales and this toggle does nothing to it.
      // With "Fine steps for brightness and contrast" on two rows above, that
      // is every press — a caption promising otherwise would contradict its
      // own neighbour (the D11 defect class).
      SettingRow("Halves how far a normal press moves on a display that is dimming past its minimum; fine steps are unchanged.") {
        Toggle("Extra-fine steps while combined dimming is active", isOn: Binding(
          get: { prefs.separateCombinedScale },
          set: { setSeparateCombinedScale($0) }
        ))
        .disabled(prefs.keyboardBrightness == .disabled)
      }
    }
  }

  // MARK: - Writes
  //
  // Every write goes pref → shortcut registration → `prefDidChange`. A control
  // that writes a pref and does not propagate is a broken control: the engine
  // reads prefs at construction and at key time, not reactively (D20).
  // `prefDidChange` takes a `PrefName` case, never a string (D27).

  /// Without this call site a mode change never re-arms the media-key tap, so
  /// the setting appears to do nothing until relaunch.
  /// `.keyboardBrightness` fans out to rearmTap + recheckPermissions + refreshUI
  /// — the recheck is D2 bug 2 (the fork's `handleListenForChanged` has zero
  /// call sites, so switching INTO a media-key mode never re-prompts for
  /// Accessibility).
  private func setBrightnessMode(_ mode: KeyMode) {
    prefs.keyboardBrightness = mode
    // Registration follows the mode: a shortcut whose family is switched off
    // must release its key combination back to the system.
    ShortcutManager.syncRegistration()
    actions.prefDidChange(.keyboardBrightness)
  }

  private func setVolumeMode(_ mode: KeyMode) {
    prefs.keyboardVolume = mode
    ShortcutManager.syncRegistration()
    actions.prefDidChange(.keyboardVolume)
  }

  private func setInterceptAlternateKeys(_ accept: Bool) {
    prefs.interceptAlternateBrightnessKeys = accept
    // The persisted key stays inverted (`disableAltBrightnessKeys`, D1/D22);
    // only the label and the accessor are positive. It feeds `tapConfig`, so
    // its row is rearmTap + refreshUI.
    actions.prefDidChange(.disableAltBrightnessKeys)
  }

  /// Deliberately inert in the engine: the executor reads this live per press,
  /// so the row is `.refreshUI` alone. The call site still exists — the pane
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

  /// No `persistenceKey:`, like every other write in this pane. The parameter
  /// is not a defaults domain — it is a FILTER on which display's controller
  /// `.reapplyDimming` reaches (`SettingsActions.apply`), and `separateCombinedScale`
  /// is app-level, so `"app"` would match zero displays and silently swallow a
  /// future reapply row. The row is `.refreshUI` alone today because
  /// `BrightnessController.step` reads the pref at key time (D20).
  private func setSeparateCombinedScale(_ separate: Bool) {
    prefs.separateCombinedScale = separate
    actions.prefDidChange(.separateCombinedScale)
  }
}

/// One modifier combination and what it does.
///
/// ONE accessibility element (SO16 + contract 5's shape): the label is the
/// whole sentence the caption used to say, so the glyphs are never spelled out
/// character by character and the combination is described in words. At
/// accessibility text sizes the combination drops onto its own line rather than
/// truncating (contract 10), the same `ViewThatFits` measurement `NavigationRow`
/// uses.
private struct ModifierLegendRow: View {
  let title: LocalizedStringKey
  let combination: String
  let spoken: String

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        Text(title)
        Spacer(minLength: 8)
        // Only on this candidate: a wrapping combination would let the row
        // "fit" at any width and the fallback would never be reached.
        combinationText.lineLimit(1)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        combinationText
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  private var combinationText: some View {
    Text(verbatim: combination).foregroundStyle(.secondary)
  }
}
