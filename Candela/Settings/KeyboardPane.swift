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
    SettingsPageScaffold {
      // "Set to take" rather than "handled here": lit-ness is
      // `KeyModePolicy.watchesMediaKeys` and knows nothing about the
      // Accessibility grant, so a subtitle claiming achieved reach would be
      // refuted by the warning card one line below it whenever the grant is
      // missing. This wording is true in both grant states.
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
      SettingsCard {
        HStack(alignment: .top, spacing: 9) {
          // Symbol AND text: the state is never signalled by color alone
          // (color.md, inclusive color). No custom color: the notice is
          // monochrome against the card.
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(SettingsTheme.faintColor)
          VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard control needs Accessibility access")
              .font(.callout.weight(.medium))
              .foregroundStyle(SettingsTheme.titleColor)
              .fixedSize(horizontal: false, vertical: true)
            SettingsCaption(
              "\(AppInfo.productName) watches the brightness and volume keys through the system event tap, which macOS gates behind Accessibility. Custom shortcuts work without it."
            )
            // The page's one action while the grant is missing, so it takes the
            // primary style. Trailing ellipsis: it opens another app
            // (buttons.md).
            Button("Open System Settings…") {
              AccessibilityPermission.openSystemSettings()
            }
            .buttonStyle(SettingsPrimaryButtonStyle())
            .accessibilityLabel("Open System Settings…")
            .padding(.top, 2)
          }
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
  ///
  /// Uncarded: the strip is the page's subject rather than one more group of
  /// rows, and the deadspace around it is what makes it read as a hero.
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
        // raw values are shipped on-disk schema (D22) and the UI order is not
        // the raw order.
        ThemedChoiceRow(label: "Control brightness with:", selection: Binding(
          get: { prefs.keyboardBrightness },
          set: { setBrightnessMode($0) }
        )) {
          Text("The keyboard's brightness keys").tag(KeyMode.media)
          Text("Custom shortcuts").tag(KeyMode.custom)
          Text("Both").tag(KeyMode.both)
          // D25: the fork's "Disable keyboard" disables no keyboard; it stops
          // THIS APP from handling one key family. Under a "Control brightness
          // with:" row label the honest item is "Nothing".
          Text("Nothing").tag(KeyMode.disabled)
        }
        .prefIdentifier(.keyboardBrightness)
      }

      if KeyModePolicy.firesCustomShortcuts(prefs.keyboardBrightness) {
        // The recorder is KeyboardShortcuts' own control: the row frames it and
        // its internals stay the package's. A titled recorder is a
        // `LabeledContent`, so the scaffold's style gives it this window's row
        // grammar for free.
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
        rowNote("Contrast works on displays controlled over their data cable (DDC) only.")
          .padding(.bottom, 6)
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

  /// A sentence that qualifies the rows above it, at row weight rather than
  /// standalone weight: on a card a callout here would be the brightest line in
  /// the group it only annotates.
  private func rowNote(_ sentence: LocalizedStringKey) -> some View {
    SettingsCaption(sentence)
      .text
      .font(.caption)
      .foregroundStyle(SettingsTheme.faintColor)
      .fixedSize(horizontal: false, vertical: true)
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
        // Under the card, where a section footer went: it is about the whole
        // family rather than any one row. The output-device rule is NOT
        // restated here. It does not hold in every mode (name matching never
        // consults it), and the Targeting page's `volumeTargetCaption` already
        // states it beside the picker that decides whether it applies.
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
