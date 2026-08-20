import CandelaKit
import KeyboardShortcuts
import SwiftUI

/// The Keyboard pane's navigation path, owned by `SettingsRootView` beside the
/// display destinations' and the OLED pane's paths, and injected here because
/// the pane's root is built by the registry with no arguments. The default is
/// a no-op constant, so any view rendered outside the injection can render but
/// never navigate.
private struct KeyboardPathKey: EnvironmentKey {
  static let defaultValue: Binding<[KeyboardPage]> = .constant([])
}

extension EnvironmentValues {
  var keyboardPath: Binding<[KeyboardPage]> {
    get { self[KeyboardPathKey.self] }
    set { self[KeyboardPathKey.self] = newValue }
  }
}

/// Keyboard input settings as a hub (KMR1): the keycap hero answers "what do
/// my keys do right now", the two mode pickers and their conditional recorders
/// stay on the root because they are the change-often controls, and the
/// reference legend and the set-once targeting and precision controls live one
/// push deeper behind chevron rows that preview their value (KMR4).
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
  @Environment(\.keyboardPath) private var keyboardPath

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // `.refreshUI` (on every known PrefName) is the ONLY invalidation signal
    // this pane has; `DisplayPrefs` is plain UserDefaults and not observable.
    // Without this reference `body` never re-evaluates after a picker writes,
    // so the recorder rows below would never appear and the picker would look
    // like it snapped back.
    let _ = model.prefsRevision
    Form {
      accessibilitySection
      heroSection
      brightnessSection
      volumeSection
      moreSection
    }
    .formStyle(.grouped)
  }

  // MARK: - Accessibility

  /// Shown only when a mode that actually needs the CGEvent tap is selected
  /// AND the grant is missing. Custom shortcuts are Carbon hotkeys and work
  /// without the grant (`KeyModePolicy.requiresAccessibility`), so an
  /// all-custom rig is never warned about a permission it does not use: the
  /// same gate as on `SettingsActions.recheckPermissions`.
  ///
  /// `AppModel.accessibility` polls while the grant is missing, so this row
  /// clears itself the moment the grant appears; no reopen, no relaunch.
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
          // (color.md, inclusive color). No custom color: the row is
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

  // MARK: - Hero

  /// The self-annotating keycap strip (KMR2). Every input comes from the same
  /// prefs and policies the engine uses (KMR3), read here so the strip
  /// re-derives on the same `prefsRevision` bump the controls below cause.
  /// The good-news Accessibility line gates itself inside the hero; while the
  /// warning above is warranted it stays silent, so the two never both speak.
  private var heroSection: some View {
    Section {
      KeyboardKeysHero(
        brightnessMode: prefs.keyboardBrightness,
        volumeMode: prefs.keyboardVolume,
        brightnessTarget: prefs.multiKeyboardBrightness,
        volumeTarget: prefs.multiKeyboardVolume,
        alternateAccepted: prefs.interceptAlternateBrightnessKeys,
        accessibilityGranted: model.accessibility.isGranted
      )
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
      .prefIdentifier(.keyboardBrightness)

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
          .prefIdentifier(.disableAltBrightnessKeys)
        }
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
        .prefIdentifier(.keyboardVolume)
      }

      if KeyModePolicy.firesCustomShortcuts(prefs.keyboardVolume) {
        KeyboardShortcuts.Recorder("Volume down:", name: .volumeDown)
        KeyboardShortcuts.Recorder("Volume up:", name: .volumeUp)
        SettingRow(Self.modifierHint) {
          KeyboardShortcuts.Recorder("Mute:", name: .mute)
        }
      }

      if KeyModePolicy.watchesMediaKeys(prefs.keyboardVolume) {
        // The output-device rule is NOT restated here. It does not hold in every
        // mode (name matching never consults it), and the Targeting page's
        // `volumeTargetCaption` already states it beside the picker that decides
        // whether it applies.
        SettingsCaption("While macOS reports an output device, the volume keys go to it instead whenever no display those keys would reach can take the command they send. Option on its own opens Sound settings.")
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

  // MARK: - More (KMR4)

  /// The two pushed pages: the reference legend and the set-once controls.
  /// Both rows are always present; a nav row that appears and disappears
  /// breaks path retention (KMR5), so inactivity is stated on the page rather
  /// than by hiding the way there.
  private var moreSection: some View {
    Section {
      NavigationRow(
        title: "Modifier Keys",
        value: KeyboardHeroModel.modifiersPreview,
        action: { keyboardPath.wrappedValue.append(.modifiers) })
      NavigationRow(
        title: "Targeting & Precision",
        value: KeyboardHeroModel.targetingPreview(
          brightnessMode: prefs.keyboardBrightness,
          target: prefs.multiKeyboardBrightness,
          fineBrightness: prefs.useFineScaleBrightness,
          fineVolume: prefs.useFineScaleVolume),
        action: { keyboardPath.wrappedValue.append(.targeting) })
    } header: {
      Text("More").settingsHeading()
    }
  }

  // MARK: - Writes
  //
  // Every write goes pref → shortcut registration → `prefDidChange`. A control
  // that writes a pref and does not propagate is a broken control: the engine
  // reads prefs at construction and at key time, not reactively (D20).
  // `prefDidChange` takes a `PrefName` case, never a string (D27).
  // The targeting and precision writes moved to `KeyboardTargetingPage` with
  // their controls (KMR6).

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
}
