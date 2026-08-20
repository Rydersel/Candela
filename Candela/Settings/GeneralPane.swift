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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var loginItem = LoginItem()
  @State private var confirmingReset = false

  /// The login-item failure as RENDERED, mirroring `loginItem.lastError` one
  /// update behind. `LoginItem` writes it only from `setEnabled` (a refresh
  /// does not clear it), and neither placement of a keyed `.animation` fades a
  /// `Form` row symmetrically (measured 2026-08-17, on the grouped `Form` this
  /// page was then): on a `Group` wrapping the conditional row it animates
  /// nothing in either direction, and on an always-present container inside the
  /// row the child fades IN and then SNAPS out. The snap-out asymmetry is why
  /// the container-hung `.animation` is not enough; the mirror is what puts the
  /// arrival AND the departure inside one transaction. Retained on the card
  /// layout because SV7 pins the behavior, not because that trap was measured
  /// here. Kept in agreement by the two hooks on the toggle below and by
  /// nothing else.
  @State private var shownLoginError: String?

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults and not observable, so `.refreshUI`
    // — which is unioned into EVERY known `PrefName` — is the only thing
    // that re-evaluates this body after a write. Without this reference the
    // startup caption below would never follow its own picker.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SettingsPageHeader(
        title: "General",
        subtitle:
          "How \(AppInfo.productName) starts, how far it dims, and what it does with your saved levels."
      )
      statusStrip
      applicationSection
      brightnessSection
      syncSection
      startupSection
    }
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
      // person surprised by a display coming out of HDR. Where the user set HDR
      // themselves, that off lasts only for the DURATION: the reset needs the
      // wire unlocked for the unmute and then hands back what it was never
      // asked to change, so the copy says both or it promises an off that does
      // not hold. The stored levels are called out because on a write-only
      // panel they are the only record of where the display is, and the login
      // item because the wipe removes a registration that lives outside the
      // prefs domain.
      Text("Your displays are put into a known state first: HDR off, any display muted by \(AppInfo.productName) unmuted, and OLED care stopped with the counted hours of use cleared. HDR that was turned on in System Settings goes back on at the end. A display that cannot be reached at the time keeps its mute and its HDR as they are, rather than being sent commands that cannot be confirmed.\n\nThen every setting is removed: per-display tuning and names, custom keyboard shortcuts, saved brightness, volume and contrast levels, remembered resolutions and rotation, saved arrangements, OLED care enrollment, and the Open at Login registration. Setup will run again afterwards.")
    }
  }

  // MARK: - Hero

  /// The page's one standing object: the app itself, running, with its login
  /// state read off the same live `SMAppService` status the row below writes
  /// (D10), and its display count off `AppModel`. No float; the About icon is
  /// the window's only one (SV8).
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
        // "Open at Login" rather than the fork's "Start at Login": it is the
        // system's own wording in System Settings → General → Login Items, and
        // Setup uses the identical string (D25 — familiarity beats novelty).
        Toggle("Open at Login", isOn: Binding(
          get: { loginItem.isEnabled },
          set: { loginItem.setEnabled($0) } // D10: the readback happens inside
        ))
        .themedSwitch()
        // The failure row's mirror hooks hang on the toggle, the row that
        // caused the failure and the one row here that is always present: hooks
        // on the failure row itself would only exist while the failure does, so
        // nothing would be watching for it to arrive. Un-animated on appear, or
        // an error still standing when the pane opens would fade in as though
        // it were new.
        .onAppear { shownLoginError = loginItem.lastError }
        .onChange(of: loginItem.lastError) { _, error in
          withAnimation(Motion.notice(reduceMotion: reduceMotion)) { shownLoginError = error }
        }
      }
      if let error = shownLoginError {
        // A failed register() leaves the toggle reading OFF (the fork's lying
        // checkbox is exactly what D10 exists to fix), so the reason has to be
        // visible or the control looks broken. The symbol is not decoration:
        // color.md forbids communicating essential information by color alone.
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
        // Both titles are stated twice on purpose. SwiftUI does not publish a
        // `Button`'s own title to the accessibility layer, so without the
        // explicit label these two announce as "button" and "button": the two
        // most consequential controls in the app, one of which wipes every
        // preference. The `let` keeps the spoken and the visible string from
        // drifting apart, which is the reason `SettingRow` takes its label
        // rather than reading one.
        let quit = "Quit \(AppInfo.productName)"
        // The Menu Bar pane's caption promises this button by name when the
        // menu bar icon is hidden ("You can quit it from General") — with no
        // icon and no Dock tile there is otherwise no way out.
        Button(quit) { NSApplication.shared.terminate(nil) }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel(Text(verbatim: quit))
        // Trailing ellipsis per buttons.md: the click opens a confirmation
        // rather than destroying anything. No `.destructive` role here — the
        // role belongs on the button that actually performs the wipe.
        // Disabled only WHILE a reset runs, per-display resets included: they
        // share one latch, because the pair overlapping is what strands a
        // display behind a controller the rebuild replaced.
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
        .themedSwitch()
        .prefIdentifier(.disableCombinedBrightness)
      }

      SettingsCardDivider()

      // Deliberately NOT disabled when combined dimming is off: `applySoftware`
      // passes `allowZero:` on the software-only path too, where the whole
      // slider range IS the software leg. Disabling it there would lock a user
      // out of the one control that governs how dark that display can go. The
      // caption carries the condition instead.
      // Two sentences, not one, and spoken as part of the toggle's label rather
      // than offered as a hint: SO15's exception list names the blank display as
      // a safety case, and accessibility contract 3 puts the three safety
      // sentences where a VoiceOver user cannot switch them off.
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

  // MARK: - Startup

  private var startupSection: some View {
    SettingsCardSection(title: "Startup") {
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
        .prefIdentifier(.startupAction)
      }
      // `startupCaption` is NOT repeated here: `SettingRow` above already
      // renders it beneath the picker. Rendering it a second time printed the
      // same sentence twice, once tight under the control and once adrift
      // below the safe-mode block.
      if prefs.startupAction == .read {
        // "Write-only panels" was the house term for these; SO14 makes the
        // hardware a display everywhere in UI copy.
        //
        // Rendered at row weight rather than as a standalone caption: it
        // qualifies `startupCaption` above it, which `SettingRow` draws small
        // and faint, and a callout here would be the larger, brighter sentence
        // of the two.
        SettingsCaption("Some displays never answer DDC reads; values then stay as last saved.")
          .text
          .font(.caption)
          .foregroundStyle(SettingsTheme.faintColor)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.bottom, 6)
      }
      SettingsCardDivider()
      // The picker deliberately shows the PERSISTED choice even in a safe-mode
      // session: this pane's `DisplayPrefs` is built without the safe-mode
      // flag, so the getter reports what is on disk rather than the `.doNothing`
      // the engine is running on, and the setter writes through for the next
      // normal launch. That is right for a settings control — but on its own it
      // is also a control describing behavior that is not happening, so safe
      // mode has to be visible right here or the pane quietly lies (D11).
      //
      // One line when nobody is in it, and the notice instead during a
      // safe-mode session: the notice already says it, at length, in the state
      // it is about. Safe mode's real, final scope (D11) must NEVER be written
      // as "no DDC commands" in either place, which is the same false copy D11
      // exists to fix: sliders and keys still work and still send DDC.
      if model.isSafeMode {
        safeModeNotice
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          Image(systemName: "shift")
          Text("Hold Shift while launching for Safe Mode: saved values aren't restored.")
        }
        .font(.caption)
        .foregroundStyle(SettingsTheme.faintColor)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
        .padding(.bottom, 2)
      }
    }
  }

  /// The active state D11 requires to be visible, as a notice inside the card
  /// rather than a paragraph on the page: the full scope is shown HERE, in the
  /// state it describes, and in no always-on form. A paragraph explaining a
  /// mode nobody is in was this pane's longest block of text.
  ///
  /// The words themselves are `SafeModeCopy`'s. This pane was the only one of
  /// the three summaries that named all four suppressions, so for a milestone
  /// the launch alert and the Diagnostics row described a narrower feature than
  /// the one the app was running. Whichever surface is right, one list is what
  /// stops them disagreeing, and the enum is exhaustive so a fifth suppression
  /// cannot reach only one of them.
  private var safeModeNotice: some View {
    HStack(alignment: .top, spacing: 9) {
      // Symbol AND text: never state by color alone (color.md). No custom
      // color; the notice is monochrome against the card.
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(SettingsTheme.faintColor)
      VStack(alignment: .leading, spacing: 4) {
        Text("Safe Mode is on for this session, so this setting is not in effect.")
          .font(.callout.weight(.medium))
          .foregroundStyle(SettingsTheme.titleColor)
          .fixedSize(horizontal: false, vertical: true)
        SettingsCaption(verbatim: SafeModeCopy.generalPaneCaption(app: AppInfo.productName))
      }
    }
    .padding(11)
    .background(
      RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
        .fill(SettingsTheme.cardFill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
        .stroke(SettingsTheme.cardStroke, lineWidth: 1)
    )
    .padding(.top, 10)
    .padding(.bottom, 4)
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
