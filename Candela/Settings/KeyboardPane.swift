import CandelaKit
import KeyboardShortcuts
import SwiftUI

/// The Keyboard pane's navigation path, owned by `SettingsRootView` and injected
/// because the registry builds the pane root with no arguments. The default is a
/// no-op, so a view rendered outside the injection renders but never navigates.
private struct KeyboardPathKey: EnvironmentKey {
  static let defaultValue: Binding<[KeyboardPage]> = .constant([])
}

extension EnvironmentValues {
  var keyboardPath: Binding<[KeyboardPage]> {
    get { self[KeyboardPathKey.self] }
    set { self[KeyboardPathKey.self] = newValue }
  }
}

/// Keyboard input settings as a hub (KMR1): the keycap hero answers "what do my
/// keys do right now", the mode pickers and their recorders stay on the root as
/// the change-often controls, and the legend and the set-once controls sit one
/// push deeper behind chevron rows that preview their value (KMR4).
///
/// The Accessibility warning sits at the TOP (HIG reading order, layout.md): a
/// mode that wants the media-key tap does nothing without the grant, so every
/// control below it is inert until that is fixed.
///
/// `@MainActor` is load-bearing: `SettingsActions` is `@MainActor`, and a plain
/// `struct … : View` has nonisolated properties under Swift 6 complete
/// concurrency.
@MainActor
struct KeyboardPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  @Environment(\.keyboardPath) private var keyboardPath

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // `.refreshUI` is the ONLY invalidation signal this pane has; `DisplayPrefs`
    // is plain UserDefaults and not observable. Without this reference the
    // recorder rows never appear and a picker looks like it snapped back.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      // "Set to take" rather than "handled here": lit-ness is
      // `KeyModePolicy.watchesMediaKeys` and knows nothing about the grant, so a
      // subtitle claiming achieved reach would be refuted by the warning below.
      SettingsPageHeader(
        title: "Keyboard",
        subtitle:
          "Which keys \(AppInfo.productName) takes, and which display they reach. Lit keys are the ones it is set to take; grey ones go straight to macOS."
      )
      accessibilitySection
      heroSection
      brightnessSection
      volumeSection
      moreSection
    }
  }

  // MARK: - Accessibility

  /// Shown only when a mode needing the CGEvent tap is selected AND the grant is
  /// missing: custom shortcuts are Carbon hotkeys and work without it
  /// (`KeyModePolicy.requiresAccessibility`), so an all-custom rig is never
  /// warned about a permission it does not use.
  ///
  /// The predicate is `AccessibilityPermission.isWarningWarranted`, the same one
  /// the panel's banner gates on: two copies of the rule is how the pane and the
  /// banner end up disagreeing on an all-custom rig.
  @ViewBuilder private var accessibilitySection: some View {
    if model.accessibility.isWarningWarranted {
      SettingsNotice {
        Text("Keyboard control needs Accessibility access")
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
        SettingsCaption(
          "\(AppInfo.productName) watches the brightness and volume keys through the system event tap, which macOS gates behind Accessibility. Custom shortcuts work without it."
        )
        // The page's one action while the grant is missing, so it takes the
        // primary style. Trailing ellipsis: it opens another app (buttons.md).
        Button("Open System Settings…") {
          AccessibilityPermission.openSystemSettings()
        }
        .buttonStyle(SettingsPrimaryButtonStyle())
        .accessibilityLabel("Open System Settings…")
        .padding(.top, 2)
      }
    }
  }

  // MARK: - Hero

  /// The self-annotating keycap strip (KMR2), derived from the same prefs and
  /// policies the engine uses (KMR3). The good-news Accessibility line gates
  /// itself inside the hero, so it and the warning above never both speak.
  /// Uncarded: the deadspace around it is what makes it read as a hero.
  private var heroSection: some View {
    KeyboardKeysHero(
      brightnessMode: prefs.keyboardBrightness,
      volumeMode: prefs.keyboardVolume,
      brightnessTarget: prefs.multiKeyboardBrightness,
      volumeTarget: prefs.multiKeyboardVolume,
      alternateAccepted: prefs.interceptAlternateBrightnessKeys,
      accessibilityGranted: model.accessibility.isGranted
    )
  }

  // MARK: - Brightness

  @ViewBuilder private var brightnessSection: some View {
    SettingsCardSection(title: "Brightness and Contrast Keys") {
      SettingRow {
        // Explicit enum tags, never `enumerated()` positions (fork QUIRK): the
        // raw values are shipped on-disk schema (D22), and UI order is not raw
        // order.
        ThemedChoiceRow(label: "Control brightness with:", selection: Binding(
          get: { prefs.keyboardBrightness },
          set: { setBrightnessMode($0) }
        )) {
          Text("The keyboard's brightness keys").tag(KeyMode.media)
          Text("Custom shortcuts").tag(KeyMode.custom)
          Text("Both").tag(KeyMode.both)
          // D25: the fork's "Disable keyboard" disables no keyboard, it stops
          // this app from handling one key family. Under a "Control brightness
          // with:" label the honest item is "Nothing".
          Text("Nothing").tag(KeyMode.disabled)
        }
        .prefIdentifier(.keyboardBrightness)
      }

      if KeyModePolicy.firesCustomShortcuts(prefs.keyboardBrightness) {
        // KeyboardShortcuts' own control, framed by the row. A titled recorder
        // is a `LabeledContent`, so the scaffold's style gives it this window's
        // row grammar for free.
        SettingsCardDivider()
        KeyboardShortcuts.Recorder("Brightness down:", name: .brightnessDown)
        SettingsCardDivider()
        KeyboardShortcuts.Recorder("Brightness up:", name: .brightnessUp)
        SettingsCardDivider()
        KeyboardShortcuts.Recorder("Contrast down:", name: .contrastDown)
        SettingsCardDivider()
        SettingRow(Self.modifierHint) {
          KeyboardShortcuts.Recorder("Contrast up:", name: .contrastUp)
        }
        SettingsRowNote("Contrast works on displays controlled over their data cable (DDC) only.")
      }

      if KeyModePolicy.watchesMediaKeys(prefs.keyboardBrightness) {
        SettingsCardDivider()
        SettingRow("F14 and F15 are Scroll Lock and Pause on PC keyboards, and the brightness keys on some Logitech keyboards.") {
          Toggle("Also accept F14 and F15", isOn: Binding(
            get: { prefs.interceptAlternateBrightnessKeys }, // D1 positive accessor
            set: { setInterceptAlternateKeys($0) }
          ))
          .themedSwitch()
          .prefIdentifier(.disableAltBrightnessKeys)
        }
      }
    }
  }

  // MARK: - Volume

  @ViewBuilder private var volumeSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsCardSection(title: "Volume Keys") {
        SettingRow("Volume applies to external displays that accept volume commands over their data cable (DDC).") {
          ThemedChoiceRow(label: "Control volume with:", selection: Binding(
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
          SettingsCardDivider()
          KeyboardShortcuts.Recorder("Volume down:", name: .volumeDown)
          SettingsCardDivider()
          KeyboardShortcuts.Recorder("Volume up:", name: .volumeUp)
          SettingsCardDivider()
          SettingRow(Self.modifierHint) {
            KeyboardShortcuts.Recorder("Mute:", name: .mute)
          }
        }
      }

      if KeyModePolicy.watchesMediaKeys(prefs.keyboardVolume) {
        // Under the card: it is about the whole family, not one row. The
        // output-device rule is NOT restated here; it does not hold in every
        // mode (name matching never consults it), and the Targeting page states
        // it beside the picker that decides whether it applies.
        SettingsCaption("While macOS reports an output device, the volume keys go to it instead whenever no display those keys would reach can take the command they send. Option on its own opens Sound settings.")
      }
    }
  }

  /// Why a bare letter looks like it does nothing: a recorder silently ignores a
  /// key pressed without a modifier. These are system-wide hotkeys, so a bare key
  /// would capture that key in every other app.
  private static let modifierHint: LocalizedStringKey =
    "Click a field and press the keys you want. A shortcut has to include ⌘, ⌃, ⌥ or ⇧. A letter or number on its own is ignored, because it would be captured in every app."

  // MARK: - More (KMR4)

  /// Both rows are always present: a nav row that appears and disappears breaks
  /// path retention (KMR5), so inactivity is stated on the page rather than by
  /// hiding the way there.
  private var moreSection: some View {
    SettingsCardSection(title: "More") {
      NavigationRow(
        title: "Modifier Keys",
        value: KeyboardHeroModel.modifiersPreview,
        action: { keyboardPath.wrappedValue.append(.modifiers) })
      SettingsCardDivider()
      NavigationRow(
        title: "Targeting & Precision",
        value: KeyboardHeroModel.targetingPreview(
          brightnessMode: prefs.keyboardBrightness,
          target: prefs.multiKeyboardBrightness,
          fineBrightness: prefs.useFineScaleBrightness,
          fineVolume: prefs.useFineScaleVolume),
        action: { keyboardPath.wrappedValue.append(.targeting) })
    }
  }

  // MARK: - Writes
  //
  // Every write goes pref → shortcut registration → `prefDidChange`, with a
  // `PrefName` case, never a string (D27). The engine reads prefs at
  // construction and at key time, not reactively (D20), so a control that
  // writes a pref and does not propagate is broken.

  /// Without this call site a mode change never re-arms the media-key tap, so
  /// the setting appears to do nothing until relaunch. The `.keyboardBrightness`
  /// row also rechecks permissions (D2 bug 2: the fork never re-prompts for
  /// Accessibility when switching INTO a media-key mode).
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
    // only the label and the accessor are positive.
    actions.prefDidChange(.disableAltBrightnessKeys)
  }
}
