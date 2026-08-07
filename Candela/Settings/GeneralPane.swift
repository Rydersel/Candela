import AppKit // NSApplication.shared.terminate
import CandelaKit
import SwiftUI

/// The app-level pane: how `AppInfo.productName` starts and stops, how far it
/// is allowed to dim, whether it mirrors the built-in display, and what it does
/// with saved values at launch and wake.
///
/// Section order follows the HIG's reading-order and bottom-edge rules
/// (layout.md — "avoid placing controls or critical information at the bottom
/// of a window", because people push a window's bottom edge off screen). The
/// two window-level actions, Quit and Reset, therefore live in the FIRST
/// section rather than trailing the pane, and every section below them is a
/// setting rather than an action.
///
/// One fork control is deliberately absent: "Enable smooth brightness
/// transitions" has nothing left to control — the spec amendment of 2026-07-30
/// removed the smooth-brightness animator. The fork's "Separate scales for
/// hardware and software dimming" was cut here by D26 and came back under A1 as
/// a key-step setting in Keyboard › Precision, which is what it always was.
///
/// `@MainActor` because `LoginItem` is a `@MainActor @Observable` type and a
/// `View`'s stored-property default expressions are nonisolated under
/// `SWIFT_STRICT_CONCURRENCY: complete`; a plain `struct GeneralPane: View`
/// cannot construct one.
@MainActor
struct GeneralPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  @State private var loginItem = LoginItem()
  @State private var confirmingReset = false

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults and not observable, so `.refreshUI`
    // — which is unioned into EVERY known `PrefName` — is the only thing
    // that re-evaluates this body after a write. Without this reference the
    // startup caption below would never follow its own picker.
    let _ = model.prefsRevision
    Form {
      applicationSection
      brightnessSection
      syncSection
      startupSection
    }
    .formStyle(.grouped)
    // D10: `SMAppService.mainApp.status` is the single source of truth, but a
    // live read is not a live *render*. `LoginItem.isEnabled` registers its
    // observation on `refreshToken`, and nothing outside this app mutates that
    // — so when the login item is switched off in System Settings → General →
    // Login Items while this window sits on another tab, the already-rendered
    // toggle keeps its old value until something bumps the token. Re-reading
    // on appearance is what `LoginItem.refresh()` is documented for; it is the
    // mechanism that makes the single source of truth visible, not a mirror.
    .onAppear { loginItem.refresh() }
    .alert("Reset all settings?", isPresented: $confirmingReset) {
      // Cancel is the default (Return) button. buttons.md: "don't assign the
      // primary role to a button that performs a destructive action, even if
      // that action is the most likely choice" — without the explicit shortcut
      // the destructive button takes the Return key.
      Button("Cancel", role: .cancel) {}
        .keyboardShortcut(.defaultAction)
      Button("Reset All Settings", role: .destructive) { actions.performReset() }
    } message: {
      // D12(a) and SO20: name what is destroyed, and name what the reset DOES
      // to the hardware on its way there. `runSettingsReset` turns HDR off,
      // unmutes, ends every lock dim and clears the hour counters before the
      // wipe (its own D29 ordering); copy that mentioned only the prefs left a
      // person surprised by a display coming out of HDR. The stored levels are
      // called out because on a write-only panel they are the only record of
      // where the display is, and the login item because the wipe removes a
      // registration that lives outside the prefs domain.
      Text("Your displays are put into a known state first: HDR off, any display muted by \(AppInfo.productName) unmuted, and OLED care stopped with the panel hour counters cleared.\n\nThen every setting is removed: per-display tuning and names, custom keyboard shortcuts, saved brightness, volume and contrast levels, remembered resolutions and rotation, saved arrangements, OLED care enrollment, and the Open at Login registration. Setup will run again afterwards.")
    }
  }

  // MARK: - Application

  private var applicationSection: some View {
    Section("Application") {
      // "Open at Login" rather than the fork's "Start at Login": it is the
      // system's own wording in System Settings → General → Login Items, and
      // Setup uses the identical string (D25 — familiarity beats novelty).
      Toggle("Open at Login", isOn: Binding(
        get: { loginItem.isEnabled },
        set: { loginItem.setEnabled($0) } // D10: the readback happens inside
      ))
      if let error = loginItem.lastError {
        // A failed register() leaves the toggle reading OFF — the fork's lying
        // checkbox is exactly what D10 exists to fix — so the reason has to be
        // visible or the control looks broken. The symbol is not decoration:
        // color.md forbids communicating essential information by color alone.
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Image(systemName: "exclamationmark.triangle.fill")
          Text(verbatim: error) // system error text — never a lookup key
        }
        .font(.callout)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        // The Menu Bar pane's caption promises this button by name when the
        // menu bar icon is hidden ("You can quit it from General") — with no
        // icon and no Dock tile there is otherwise no way out.
        Button("Quit \(AppInfo.productName)") { NSApplication.shared.terminate(nil) }
        // Trailing ellipsis per buttons.md: the click opens a confirmation
        // rather than destroying anything. No `.destructive` role here — the
        // role belongs on the button that actually performs the wipe.
        Button("Reset All Settings…") { confirmingReset = true }
      }
    }
  }

  // MARK: - Brightness

  private var brightnessSection: some View {
    Section("Brightness") {
      // The fork's "Combine hardware and software dimming" named the
      // mechanism; this names the outcome and moves the mechanism into the
      // caption (D25).
      SettingRow("Keeps dimming in software once a DDC-controlled display reaches its hardware minimum.") {
        Toggle("Dim past the display's minimum", isOn: Binding(
          get: { prefs.combinedBrightness },
          set: { enabled in
          // D1: positive accessor over an inverted key. `combinedBrightness`
          // is `!disableCombinedBrightness`; the on-disk key keeps its name.
          prefs.combinedBrightness = enabled
          // D4 + D28: this is a re-conversion of the SAME published value, not
          // a reset. `.reapplyDimming` reaches
          // `BrightnessController.reapplyAfterPrefChange()`, which re-writes
          // the DDC register AND the software leg and tears down the abandoned
          // backend. The effect it replaced re-ran the software leg only and
          // returned early in pure-DDC mode, which is what left a display at
          // its DDC floor with the gamma table still scaled — near-black until
          // replug.
            actions.prefDidChange(.disableCombinedBrightness)
          }
        ))
      }

      // Deliberately NOT disabled when combined dimming is off: `applySoftware`
      // passes `allowZero:` on the software-only path too, where the whole
      // slider range IS the software leg. Disabling it there would lock a user
      // out of the one control that governs how dark that display can go. The
      // caption carries the condition instead.
      // Two sentences, not one: SO15's exception list names the blank display
      // as a safety case, and the hazard is the second sentence.
      SettingRow("The slider can reach 0% on any display dimming in software, which blanks it completely. If keyboard control is also off, a blank display can be hard to undo.") {
        Toggle("Allow a fully dark display", isOn: Binding(
          get: { prefs.allowZeroSwBrightness },
          set: { enabled in
            prefs.allowZeroSwBrightness = enabled
            actions.prefDidChange(.allowZeroSwBrightness)
          }
        ))
      }
    }
  }

  // MARK: - Sync

  private var syncSection: some View {
    Section("Sync") {
      SettingRow("Brightness changes made by the ambient light sensor, Control Center or System Settings are mirrored to your other displays.") {
        Toggle("Match other displays to the built-in display", isOn: Binding(
          get: { prefs.enableBrightnessSync },
          set: { enabled in
            prefs.enableBrightnessSync = enabled
            actions.prefDidChange(.enableBrightnessSync)
          }
        ))
      }
    }
  }

  // MARK: - Startup

  private var startupSection: some View {
    Section("Startup") {
      SettingRow(startupCaption) {
        Picker("On startup and wake:", selection: Binding(
          get: { prefs.startupAction },
          set: { action in
            prefs.startupAction = action
            actions.prefDidChange(.startupAction)
          }
        )) {
          Text("Trust the last saved values (recommended)").tag(StartupAction.doNothing)
          Text("Re-send the last saved values to the display").tag(StartupAction.write)
          Text("Ask the display for its current values").tag(StartupAction.read)
        }
      }
      // The picker deliberately shows the PERSISTED choice even in a safe-mode
      // session: this pane's `DisplayPrefs` is built without the safe-mode
      // flag, so the getter reports what is on disk rather than the `.doNothing`
      // the engine is running on, and the setter writes through for the next
      // normal launch. That is right for a settings control — but on its own it
      // is also a control describing behavior that is not happening, so safe
      // mode has to be visible right here or the pane quietly lies (D11).
      if model.isSafeMode {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          // Symbol AND text — never state by color alone (color.md). No custom
          // color; the row is monochrome in both appearances.
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Text("Safe Mode is on for this session, so this setting is not in effect.")
        }
        // The full scope lives HERE, in the state it describes, and nowhere
        // else: an always-on paragraph explaining a mode nobody is in was the
        // pane's longest block of text. D11's visibility rule is about the
        // ACTIVE state, which keeps its status row above and this caption.
        // Safe mode's real, final scope (D11): no startup restore, no wake
        // restore, no brightness readback, no quit-time write, and — added by
        // W3a — no OLED-care driver loop, so no dimming overlay and no panel
        // hours. Sliders and keys still work and still send DDC, and so do the
        // OLED Care pane's two screen-chrome switches (explicit writes to a
        // system setting, not automatic behavior; that pane carries its own
        // safe-mode note) — so this must NEVER claim "no DDC commands" or that
        // OLED care is entirely off, which is the same class of false copy D11
        // exists to fix.
        SettingsCaption("Shift was held at launch, so \(AppInfo.productName) won't restore your saved values at startup or wake, won't read values back from your displays, won't write anything when it quits, and won't dim any display or count hours of use for OLED care. The sliders and keys still work, your settings are unchanged, and relaunching without Shift restores normal behavior.")
      }
      // `startupCaption` is NOT repeated here: `SettingRow` above already
      // renders it beneath the picker. Rendering it a second time printed the
      // same sentence twice, once tight under the control and once adrift
      // below the safe-mode block.
      if prefs.startupAction == .read {
        // "Write-only panels" was the house term for these; SO14 makes the
        // hardware a display everywhere in UI copy.
        SettingsCaption("Some displays never answer DDC reads; values then stay as last saved.")
      }
      // One line when nobody is in it, and nothing at all during a safe-mode
      // session — the branch above already says it, at length, in the state it
      // is about. Safe mode's real, final scope (D11) must NEVER be written as
      // "no DDC commands" in either place, which is the same false copy D11
      // exists to fix: sliders and keys still work and still send DDC.
      if !model.isSafeMode {
        SettingsCaption("Hold Shift while launching for Safe Mode: saved values aren't restored.")
      }
    }
  }

  /// Exhaustive, so a future `StartupAction` case is a compile error here
  /// rather than a silently missing caption.
  private var startupCaption: LocalizedStringKey {
    switch prefs.startupAction {
    case .write: "Useful when a display forgets its settings while asleep."
    case .read: "Reads brightness, contrast and volume back from the display. Not all hardware answers."
    case .doNothing: "Keeps using the values from last time, and sends them to the display the first time you change something."
    }
  }
}
