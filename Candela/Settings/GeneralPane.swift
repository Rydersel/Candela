import AppKit // NSApplication.shared.terminate
import CandelaKit
import SwiftUI

/// The app-level pane: how `AppInfo.productName` starts and stops, how far it is
/// allowed to dim, and whether it mirrors the built-in display. The startup and
/// wake restore choice lives on Protection instead, with its pref and its
/// safe-mode visibility.
///
/// Section order follows the HIG's reading-order and bottom-edge rules: people
/// push a window's bottom edge off screen, so Quit and Reset live in the FIRST
/// section and every section below them is a setting rather than an action.
///
/// `@MainActor` because `LoginItem` is a `@MainActor @Observable` type and a
/// `View`'s stored-property default expressions are nonisolated under complete
/// concurrency; a plain `struct GeneralPane: View` cannot construct one.
@MainActor
struct GeneralPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var loginItem = LoginItem()
  @State private var confirmingReset = false

  /// The login-item failure as RENDERED, mirroring `loginItem.lastError` one
  /// update behind. Neither placement of a keyed `.animation` fades the row
  /// symmetrically (measured 2026-08-17): on a `Group` around the conditional row
  /// nothing animates either way, and on an always-present container the child
  /// fades IN and then SNAPS out. The mirror is what puts the arrival AND the
  /// departure inside one transaction. Kept in agreement by the two hooks on the
  /// toggle below and by nothing else.
  @State private var shownLoginError: String?

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults, not observable, so `.refreshUI`
    // (unioned into EVERY known `PrefName`) is the only thing that re-evaluates
    // this body after a write. Without it the switches below keep drawing the
    // value they were built with after a reset or an outside write.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SettingsPageHeader(
        title: "General",
        subtitle:
          "How \(AppInfo.productName) opens, how far it dims, and whether your other displays follow the built-in one."
      )
      statusStrip
      applicationSection
      brightnessSection
      syncSection
    }
    // `SMAppService.mainApp.status` is the single source of truth, but a
    // live read is not a live render. `LoginItem.isEnabled` observes
    // `refreshToken`, which nothing outside this app bumps, so a login item
    // switched off in System Settings while this window sits elsewhere leaves the
    // rendered toggle stale. `refresh()` is that bump, not a mirror.
    .onAppear { loginItem.refresh() }
    .alert("Reset all settings?", isPresented: $confirmingReset) {
      // Cancel is the default (Return) button: without the explicit shortcut the
      // destructive button takes Return, and a destructive action never holds the
      // primary role.
      Button("Cancel", role: .cancel) {}
        .keyboardShortcut(.defaultAction)
      Button("Reset All Settings", role: .destructive) { actions.performReset() }
    } message: {
      // Name what is destroyed, and what the reset DOES to the
      // hardware on the way there. `runSettingsReset` turns HDR off, unmutes,
      // ends every lock dim and clears the hour counters before the wipe (its own
      // ordering). Where the user set HDR themselves that off lasts only for
      // the DURATION, so the copy says both or it promises an off that does not
      // hold. The stored levels are called out because on a write-only panel they
      // are the only record of where the display is, and the login item because
      // the wipe removes a registration outside the prefs domain.
      Text("Your displays are put into a known state first: HDR off, any display muted by \(AppInfo.productName) unmuted, and OLED care stopped with the counted hours of use cleared. HDR that was turned on in System Settings goes back on at the end. A display that cannot be reached at the time keeps its mute and its HDR as they are, rather than being sent commands that cannot be confirmed.\n\nThen every setting is removed: per-display tuning and names, custom keyboard shortcuts, saved brightness, volume and contrast levels, remembered resolutions and rotation, saved arrangements, OLED care enrollment, and the Open at Login registration. Setup will run again afterwards.")
    }
  }

  // MARK: - Hero

  /// The page's one standing object: the app itself, with its login state read
  /// off the same live `SMAppService` status the row below writes. No
  /// float; the About icon is the window's only one.
  private var statusStrip: some View {
    SettingsCard {
      HStack(spacing: 16) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 54, height: 54)
          .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 4) {
          // Both sentences are `LSUIElement`, which is settled in the bundle
          // rather than read at runtime.
          Text("Running from the menu bar")
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(SettingsTheme.titleColor)
          Text("No Dock icon and no window to lose: the controls live behind the icon.")
            .font(.caption)
            .foregroundStyle(SettingsTheme.bodyColor)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 12)

        VStack(alignment: .trailing, spacing: 6) {
          SettingsBadge(text: loginItem.isEnabled ? "Opens at Login" : "Manual start")
          Text(verbatim: connectedLine)
            .font(.caption2)
            .foregroundStyle(SettingsTheme.faintColor)
        }
      }
    }
    .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
  }

  /// `AppModel.displays` is external-only (the built-in has its own slot), so
  /// the line says external rather than counting a panel it excludes.
  private var connectedLine: String {
    switch model.displays.count {
    case 0: "No external displays connected"
    case 1: "1 external display connected"
    case let count: "\(count) external displays connected"
    }
  }

  // MARK: - Application

  private var applicationSection: some View {
    SettingsCardSection(title: "Application") {
      SettingRow {
        // The system's own wording in System Settings, and Setup uses the
        // identical string (familiarity beats novelty).
        Toggle("Open at Login", isOn: Binding(
          get: { loginItem.isEnabled },
          set: { loginItem.setEnabled($0) } // the live-status rule: the readback happens inside
        ))
        .themedSwitch()
        // The mirror hooks hang on the toggle, the row that causes the failure
        // and the one row always present: hooks on the failure row would exist
        // only while the failure does, so nothing would watch for it to arrive.
        // Un-animated on appear, or an error still standing when the pane opens
        // would fade in as though it were new.
        .onAppear { shownLoginError = loginItem.lastError }
        .onChange(of: loginItem.lastError) { _, error in
          withAnimation(Motion.notice(reduceMotion: reduceMotion)) { shownLoginError = error }
        }
      }
      if let error = shownLoginError {
        // A failed register() leaves the toggle reading OFF (the lying checkbox
        // the live-status rule exists to fix), so the reason has to be visible or the control
        // looks broken. The symbol is not decoration: essential information is
        // never carried by colour alone.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "exclamationmark.triangle.fill")
          Text(verbatim: error) // system error text, never a lookup key
        }
        .font(.callout)
        .foregroundStyle(SettingsTheme.dangerTint)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 6)
        .transition(.opacity)
      }
      SettingsCardDivider()
      HStack(spacing: 10) {
        // Both titles are stated twice on purpose: SwiftUI does not publish a
        // `Button`'s own title to the accessibility layer, so without the
        // explicit label these announce as "button" and "button", and one of them
        // wipes every preference. The `let` keeps the spoken and visible strings
        // from drifting apart.
        let quit = "Quit \(AppInfo.productName)"
        // The Menu Bar pane's caption promises this button by name when the
        // menu-bar icon is hidden: with no icon and no Dock tile there is
        // otherwise no way out.
        Button(quit) { NSApplication.shared.terminate(nil) }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel(Text(verbatim: quit))
        // Trailing ellipsis: the click opens a confirmation rather than
        // destroying anything, and the `.destructive` role belongs on the button
        // that performs the wipe. Disabled only WHILE a reset runs, per-display
        // resets included: they share one latch, because the pair overlapping is
        // what strands a display behind a controller the rebuild replaced.
        Button("Reset All Settings…") { confirmingReset = true }
          .buttonStyle(SettingsDangerButtonStyle())
          .accessibilityLabel("Reset All Settings…")
          .disabled(model.isResetting)
        Spacer(minLength: 0)
      }
      .padding(.top, 8)
      .padding(.bottom, 2)
    }
  }

  // MARK: - Brightness

  private var brightnessSection: some View {
    SettingsCardSection(title: "Brightness") {
      // Names the outcome, with the mechanism in the caption.
      SettingRow("Keeps dimming in software once a DDC-controlled display reaches its hardware minimum.") {
        Toggle("Dim past the display's minimum", isOn: Binding(
          get: { prefs.combinedBrightness },
          set: { enabled in
          // Positive accessor over an inverted key. `combinedBrightness`
          // is `!disableCombinedBrightness`; the on-disk key keeps its name.
          prefs.combinedBrightness = enabled
          // A re-conversion of the SAME published value, not a reset.
          // `.reapplyDimming` reaches
          // `BrightnessController.reapplyAfterPrefChange()`, which re-writes the
          // DDC register AND the software leg and tears down the abandoned
          // backend. Re-running the software leg alone returns early in pure-DDC
          // mode, which left a display at its DDC floor with the gamma table
          // still scaled: near-black until replug.
            actions.prefDidChange(.disableCombinedBrightness)
          }
        ))
        .themedSwitch()
        .prefIdentifier(.disableCombinedBrightness)
      }

      SettingsCardDivider()

      // Deliberately NOT disabled when combined dimming is off: `applySoftware`
      // passes `allowZero:` on the software-only path too, where the whole slider
      // range IS the software leg, so disabling it there would lock a user out of
      // how dark that display can go. The caption carries the condition instead,
      // spoken as part of the toggle's label rather than offered as a hint: the
      // safety-copy convention names the blank display as a safety case, and a11y contract 3 puts the
      // safety sentences where a VoiceOver user cannot switch them off.
      SettingRow(safety: .blankDisplay, label: "Allow a fully dark display") { label in
        Toggle(label, isOn: Binding(
          get: { prefs.allowZeroSwBrightness },
          set: { enabled in
            prefs.allowZeroSwBrightness = enabled
            actions.prefDidChange(.allowZeroSwBrightness)
          }
        ))
        .themedSwitch()
        .prefIdentifier(.allowZeroSwBrightness)
      }
    }
  }

  // MARK: - Sync

  private var syncSection: some View {
    SettingsCardSection(title: "Sync") {
      SettingRow("Brightness changes made by the ambient light sensor, Control Center or System Settings are mirrored to your other displays.") {
        Toggle("Match other displays to the built-in display", isOn: Binding(
          get: { prefs.enableBrightnessSync },
          set: { enabled in
            prefs.enableBrightnessSync = enabled
            actions.prefDidChange(.enableBrightnessSync)
          }
        ))
        .themedSwitch()
        .prefIdentifier(.enableBrightnessSync)
      }
    }
  }

}
