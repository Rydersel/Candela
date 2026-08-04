import CandelaKit
import SwiftUI

/// One connected external display's settings, as a full-window destination.
///
/// Was `DisplayCard`, one of several cards stacked inside a `DisplaysPane`.
/// Promoting displays to top-level sidebar destinations is what actually
/// separates this window from the fork's — and it retires the "Advanced"
/// disclosure, because a full window has room to simply show the controls.
/// That in turn retires the auto-open hack that used to force the disclosure
/// open when the display was stranded hardware-muted: the recovery row is now
/// unconditionally visible, which is what D29 rule 3 wanted all along.
///
/// `@MainActor` is load-bearing, not decoration: `DisplayPrefWriter` is
/// `@MainActor` (it holds `SettingsActions`), and a plain `struct … : View` has
/// nonisolated stored and computed properties under Swift 6 complete
/// concurrency, so `private var writer: DisplayPrefWriter { … }` would not
/// compile without it.
@MainActor
struct DisplayDetailView: View {
  let state: AppModel.DisplayState

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  /// Drafts, not direct pref bindings: a `TextField` bound straight to a pref
  /// would write (and fan out, and bump `prefsRevision`) on every keystroke,
  /// re-rendering the pane mid-edit. Committed on Return and on focus loss.
  @State private var nameDraft = ""
  @State private var audioNameDraft = ""
  @FocusState private var nameFocused: Bool
  @FocusState private var audioNameFocused: Bool
  @State private var confirmingReset = false

  private var persistenceKey: String { state.display.persistenceKey }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults and not observable, so this is the
    // only thing that re-evaluates the body after a write anywhere else.
    let _ = model.prefsRevision
    Form {
      identitySection
      panelSection
      displayModeSection
      rotationSection
      mirroringSection
      controlMethodSection
      volumeSection
      tuningSection
      diagnosticsSection
      resetSection
    }
    .formStyle(.grouped)
    .onAppear { seedDrafts() }
    // Mode enumeration is several CoreGraphics round-trips, so it runs here
    // rather than per body evaluation. It hangs off the Form, not off
    // `DisplayModeSection`: a modifier applied to a `Section` inside a grouped
    // Form is not reliably applied to the section itself (`listRowInsets` and
    // `listRowSeparator` are both measured no-ops there), and a lifecycle hook
    // that silently never fires would leave the resolution list empty.
    // Any LATER resolution change — ours, System Settings', or a replug —
    // re-enumerates through the coordinator's own screen-parameters observer,
    // which must run whether or not this pane is on screen: a display can
    // depart while the pane is being dismissed for exactly that reason, and its
    // outstanding preview still has to be dropped.
    .task(id: state.id) { model.displayModes.refreshCatalog(for: state.id) }
    // Drafts seeded only in `.onAppear` survive a wipe: if this pane is on
    // screen when the user resets everything from General, the card still holds
    // "Desk" and the next focus/blur re-writes friendlyName.<pk> into the
    // domain that was just emptied. Re-seed on every revision bump — which the
    // seam guarantees via `.refreshUI`.
    .onChange(of: model.prefsRevision) { _, _ in
      guard !nameFocused, !audioNameFocused else { return } // never fight a live edit
      seedDrafts()
    }
  }

  private func seedDrafts() {
    nameDraft = prefs.friendlyName
    audioNameDraft = prefs.audioDeviceNameOverride
  }

  // MARK: - Sections

  private var identitySection: some View {
    Section("Display") {
      SettingRow("Shown in the menu bar panel. Leave it empty to use the name the display reports.") {
        TextField("Name", text: $nameDraft, prompt: Text(verbatim: state.display.name))
          .focused($nameFocused)
          .onSubmit { commitName() }
          .onChange(of: nameFocused) { _, focused in
            if !focused { commitName() }
          }
      }

      // What the old card's section header carried as a subtitle. It is
      // read-only status, not a setting, so it reads as a value rather than a
      // control — but it belongs beside the identity, because it is the single
      // most useful fact about how this display is being driven.
      LabeledContent("Control method") {
        Text(controlMethodLabel)
          .foregroundStyle(.secondary)
      }
      .help(controlMethodExplanation)
    }
  }

  private var panelSection: some View {
    Section("Menu bar panel") {
      Toggle("Show this display in the menu bar panel", isOn: Binding(
        get: { !prefs.hideDisplay },
        set: { shown in writer.write(.hideDisplay) { $0.hideDisplay = !shown } }
      ))

      SettingRow("When off, the brightness and volume keys skip this display.") {
        Toggle("Control this display with the keyboard", isOn: Binding(
          get: { !prefs.isDisabled },
          set: { enabled in writer.write(.isDisabled) { $0.isDisabled = !enabled } }
        ))
      }

      // The hide-vs-disable split (panel §5.4) is only obvious once you have
      // seen both controls. This toggle removes the row; "Volume slider (when
      // shown)" below decides whether a row that IS shown takes input. Without
      // this sentence the two read as one setting worded twice.
      SettingRow("Removes the row entirely. Whether a slider that is shown accepts input is set under Volume.") {
        Toggle("Show the volume slider in the panel", isOn: Binding(
          get: { !prefs.hideVolumeSlider },
          set: { shown in writer.write(.hideVolumeSlider) { $0.hideVolumeSlider = !shown } }
        ))
      }
    }
  }

  // MARK: - Resolution

  private var displayModeSection: some View {
    DisplayModeSection(state: state, coordinator: model.displayModes, actions: actions)
  }

  // MARK: - Rotation

  /// Between resolution and mirroring, which is where it belongs in the pane's
  /// existing progression: what the display shows, then how that picture is
  /// oriented, then how the display is arranged against the others. It is also
  /// the ordering the two share a consequence through — RS3 measured that a
  /// rotation swaps the reported mode, so a curated list captured before one
  /// describes the other orientation.
  private var rotationSection: some View {
    RotationSection(state: state, coordinator: model.rotation)
  }

  // MARK: - Mirroring

  /// One line and one property, like the diagnostics section below. No
  /// `PaneID` case and no `SettingsRegistry` row — per-display destinations are
  /// not registry panes (R2, R3). No pref either: mirroring is deliberately not
  /// persisted and not reapplied (DT20).
  ///
  /// Placed after the resolution section and before control method: identity,
  /// then what the display shows, then how the display is arranged, then how
  /// Candela drives it. It does NOT belong to R16 — a control that governs
  /// whether a display *appears* must not live in that display's own
  /// destination, and mirroring does not remove a display from the sidebar. A
  /// mirror slave stays online, stays discovered, and keeps its
  /// `BrightnessController` across a toggle.
  private var mirroringSection: some View {
    MirroringSection(state: state, coordinator: model.mirroring)
  }

  /// Candela's equivalent of the fork's `controlMethod` subtitle. The BRANCH
  /// lives in CandelaKit under test (`BrightnessPathPolicy`, projected by
  /// `DisplayCardPolicy.controlMethod(for:)`); this is the presentation of its
  /// cases, in the user's terms — never the pref name (D25).
  ///
  /// Read from the CONTROLLER, not recomputed from `prefs`: the engine and this
  /// row now answer the same call, so the row cannot claim a path the engine is
  /// not on. The body's `model.prefsRevision` read is what re-evaluates it after
  /// a pref write, and `isHDREngaged` is observable, so the HDR-native path
  /// updates on its own.
  private var brightnessPath: BrightnessPath { state.controller.brightnessPath }

  private var controlMethodLabel: LocalizedStringKey {
    switch DisplayCardPolicy.controlMethod(for: brightnessPath) {
    case .hardwareDDC: "Hardware (DDC) control"
    case .softwareGamma: "Software dimming, color profile"
    case .softwareOverlay: "Software dimming, screen overlay"
    case .none: pathWithoutACardWord
    }
  }

  /// The two paths the card has no word for. Split out rather than folded into
  /// the switch above so a nil can never render as a blank value — a row that
  /// promised a fact and shows nothing is worse than one that says less.
  private var pathWithoutACardWord: LocalizedStringKey {
    if case .unavailable = brightnessPath {
      return "Nothing is controlling brightness"
    }
    return "Native brightness"
  }

  private var controlMethodExplanation: LocalizedStringKey {
    switch brightnessPath {
    case .native:
      "Brightness is set through macOS itself. Hardware commands over the data cable do not apply on this path."
    case .hardware:
      "This display accepts hardware brightness, volume and contrast commands over its data cable."
    case .combined:
      "Brightness is carried over the data cable at the top of the range and dimmed in software below it."
    // The row ruling R-A exists to make honest: the display really is dimming,
    // so "software dimming" alone would be true — and would still mislead,
    // because it implies the whole slider works. The dead zone above the split
    // is the fact the user needs, so it is the fact this sentence leads with.
    case let .softwareOnly(backend, .ddcTurnedOff, _):
      backend == .overlay
        ? "The hardware brightness command is turned off for this display, so only the lower part of the slider dims — with a dark overlay — and the rest of it moves nothing."
        : "The hardware brightness command is turned off for this display, so only the lower part of the slider dims — through the color profile — and the rest of it moves nothing."
    case .software(.gamma):
      "Brightness is dimmed by adjusting the display's color profile. Volume and contrast are unavailable on this path."
    case .software(.overlay):
      "Brightness is dimmed by drawing a dark overlay over the screen. The pointer is unaffected and full-screen transitions can flicker."
    case .unavailable(.ddcTurnedOffWithNoSoftwareLeg):
      "Combined dimming is off for this display and its hardware brightness command is turned off, so nothing is left to carry the value."
    }
  }

  // MARK: - Control method

  private var controlMethodSection: some View {
    Section("Control method") {
      SettingRow("Turn this off if hardware control misbehaves on this display — brightness then dims in software, and volume and contrast become unavailable. Your current brightness is preserved either way.") {
        Toggle("Use hardware (DDC) control", isOn: Binding(
          get: { !prefs.forceSoftware },
          set: { useDDC in
            // D29 rule 1 — the THIRD mute-stranding path, and the only one that was
            // unrecoverable. `isAvailable` is
            // `!tuning.unavailableDDC && !prefs.forceSoftware`, and `toggleMute`
            // guards on it. Turning DDC control off while the display is 0x8D-muted
            // used to make the unmute refuse FOREVER: the key path is gone, the
            // panel drops the volume slider, `restoreToHardware` is gated on the
            // same flag, and both UI escape hatches are disabled in exactly that
            // state. Unmute BEFORE persisting the disabling value.
            if !useDDC, state.volume.isMuted {
              _ = state.volume.toggleMute()
            }
            writer.write(.forceSw) { $0.forceSoftware = !useDDC }
          }
        ))
      }

      SettingRow("Software dimming normally adjusts the display's color profile. Switch to an overlay if another app keeps taking the profile back, or on virtual and AirPlay displays.") {
        Toggle("Dim with a screen overlay", isOn: Binding(
          get: { prefs.avoidGamma },
          set: { overlay in
            // D28: the seam's `.reapplyDimming` reaches `reapplyAfterPrefChange()`,
            // which TEARS DOWN the abandoned backend before re-applying. Without
            // that teardown `applySoftware` writes the newly selected backend and
            // leaves the other one engaged — the shade at alpha 1 − 0.8^1.5 on top
            // of a gamma table still at 0.8 — so the display drops to roughly the
            // product of the two and stays there until a topology change.
            writer.write(.avoidGamma) { $0.avoidGamma = overlay }
          }
        ))
      }
    }
  }

  // MARK: - Volume

  @ViewBuilder private var volumeSection: some View {
    // `defaultOutputDevice()` does a blocking HAL round-trip when the CoreAudio
    // listener has not primed its cache — read it once, not once per consumer.
    let currentOutput = model.audioDevices.defaultOutputDevice()

    Section("Volume") {
      SettingRow("Turn this off if macOS already shows its own volume indicator for this display. Brightness and contrast indicators are unaffected.") {
        Toggle("Show the on-screen volume indicator for this display", isOn: Binding(
          get: { !prefs.hideOsd },
          set: { shown in writer.write(.hideOsd) { $0.hideOsd = !shown } }
        ))
      }

    Toggle("Mute with the display's own mute command", isOn: Binding(
      get: { prefs.enableMuteUnmute },
      set: { enabled in
        // D22/D29 rule 1, and there is NO engine backstop: unmute BEFORE the
        // pref flips. Once `enableMuteUnmute` is false nothing ever sends
        // 0x8D=2 again, so persisting first strands the display hardware-muted
        // with only a CLI to recover it.
        if !enabled, state.volume.isMuted {
          _ = state.volume.toggleMute()
        }
        writer.write(.enableMuteUnmute) { $0.enableMuteUnmute = enabled }
      }
    ))
    .disabled(!state.volume.isAvailable)
    if state.volume.isAvailable {
      SettingsCaption("Off: muting sets the volume to zero. On: \(AppInfo.productName) sends the display's dedicated mute command, which some displays handle better.")
    } else {
      // Disable, don't hide (panel §5.4): the control does not apply while the
      // volume command is off, and saying so beats a missing row. Disabling it
      // does NOT make the D22 hazard unreachable — the hazard stays reachable
      // from the DDC toggle above; what it would make unreachable is the
      // RECOVERY. D29 rule 3: a recovery control is never disabled in the state
      // it exists to recover from, so the row below is offered instead, and it
      // works regardless of `isAvailable`.
      SettingsCaption("Volume control is turned off for this display, so mute is unavailable.")
    }

    if isStrandedMuted {
      // D29 rule 3 — the explicit unmute affordance. This is the ONLY control
      // that can leave the state, because `toggleMute` refuses while
      // `isAvailable` is false; it clears the two prefs that make it false
      // FIRST (D29 rule 2), then unmutes while the display's current mute
      // strategy is still in force. Never `.disabled`, and no longer behind a
      // disclosure either — the full-window layout shows it outright.
      VStack(alignment: .leading, spacing: 4) {
        Text("This display is muted in hardware.")
        Button("Turn Hardware Control Back On and Unmute") { recoverFromHardwareMute() }
      }
      SettingsCaption("Muting used the display's own mute command, and that command can only be undone over hardware control. This turns hardware control back on for this display and unmutes it.")
    }

      // "(when shown)" is load-bearing, not padding: without it this picker and
      // the "Show the volume slider in the panel" toggle above read as the same
      // setting. One hides the row, this one decides whether a visible row takes
      // input.
      SettingRow("\(AppInfo.productName) asks the display itself whether it accepts volume commands, and greys the slider only when the display says no. Override that when the answer is wrong for your setup — some displays report a volume control they ignore, and others accept volume they never advertise.") {
        Picker("Volume slider (when shown):", selection: Binding(
          get: { prefs.audioSinkOverride },
          set: { override in writer.write(.audioSinkOverride) { $0.audioSinkOverride = override } }
        )) {
          Text("Enable automatically").tag(AudioSinkOverride.auto)
          Text("Always enabled").tag(AudioSinkOverride.forcePresent)
          Text("Always disabled").tag(AudioSinkOverride.forceNone)
        }
      }

    LabeledContent("Audio device name") {
      HStack(spacing: 8) {
        TextField("", text: $audioNameDraft, prompt: Text("Automatic"))
          .focused($audioNameFocused)
          .onSubmit { commitAudioName() }
          .onChange(of: audioNameFocused) { _, focused in
            if !focused { commitAudioName() }
          }
          .frame(width: 180)
        Button("Use Current") {
          audioNameDraft = currentOutput?.name ?? ""
          commitAudioName()
        }
        .disabled(currentOutput == nil)
      }
    }
    SettingsCaption("Used when the volume keys pick a display by matching the current audio output device. Leave it empty to match on the display's own name.")
    }
  }

  // MARK: - Tuning

  private var tuningSection: some View {
    Section("Tuning") {
      CommandTuningGrid(state: state, writer: writer)
    }
  }

  // MARK: - Diagnostics

  /// One line and one property, per DT28. No `PaneID` case, no
  /// `SettingsRegistry` row, no `SettingsDestination` change — per-display
  /// destinations are not registry panes (R2, R3), and adding a case here
  /// would be a change with no reader.
  private var diagnosticsSection: some View {
    DisplayDiagnosticsSection(state: state)
  }

  // MARK: - Reset

  private var resetSection: some View {
    Section {
      Button("Reset Display Settings…", role: .destructive) { confirmingReset = true }
        .alert("Reset the settings for this display?", isPresented: $confirmingReset) {
          Button("Reset", role: .destructive) { resetDisplay() }
          Button("Cancel", role: .cancel) {}
        } message: {
        // Name what is lost, and name what is NOT: the saved levels are the
        // only source of truth on a write-only panel (trap 20), so a reset
        // that took them would leave the display at an unknown brightness.
        Text("This clears the name, visibility, keyboard, audio and DDC tuning settings for \(state.display.name), turns HDR off if it is on, and unmutes it. Your saved brightness, volume and contrast levels are kept.")
        }
    }
  }

  // MARK: - Per-display reset

  /// Per-display reset (fork "Reset settings", chapter 2 §6) with the fork's
  /// three defects fixed — no `setDirectBrightness(1)`/`setSwBrightness(1)`
  /// slam (D4: the seam re-applies the same value on the new path), the curve
  /// is cleared to unset rather than written as an explicit 5, and it is
  /// available for every display rather than hidden on virtual ones — plus the
  /// ordering defect the five-lens review found in the plan itself.
  ///
  /// ORDER IS THE WHOLE POINT (D29 rule 2, lens-3 C5). The previous version
  /// attempted `toggleMute()` FIRST, then cleared `forceSoftware` and the
  /// per-command `unavailableDDC`, then set `enableMuteUnmute = false`. On a
  /// display that arrived at the reset already in the D29 state — muted with
  /// hardware control off — the unmute hit `toggleMute`'s `isAvailable` guard
  /// and returned silently, and the reset then retired the only mute strategy
  /// that could ever send 0x8D=2 again. The user's reasonable response to a bad
  /// state, using the button whose alert promises to fix it, made the monitor
  /// permanently silent while the app believed it was unmuted.
  ///
  /// So: availability prefs FIRST, unmute SECOND (while the display's current
  /// mute strategy is still in force), retire the strategy LAST.
  private func resetDisplay() {
    Task { @MainActor in
      // 1. D22: HDR goes through the controller's state machine — settle
      //    window, poller gating, rollback — never through `prefs.hdrMode`.
      //    Done first so the DDC register is unlocked for everything below.
      if state.controller.hdrMode != .off {
        await state.controller.setHDRMode(.off)
      }

      // 2. Every pref except the mute strategy, in ONE batch whose fan-out is
      //    the UNION of its rows. Never collapse it onto a single
      //    `prefDidChange(.forceSw)`: `hideDisplay` carries `.updateStatusItem`
      //    and `forceSw` does not, so with `menuIcon == .sliderOnly` a reset
      //    that un-hid the display would leave the status item missing.
      //    Clearing `forceSoftware` and every command's `unavailableDDC` here
      //    is also what makes step 3 able to work at all (D29 rule 2).
      writer.writeAll([
        .friendlyName, .hideDisplay, .isDisabled, .hideOsd, .forceSw, .avoidGamma,
        .audioDeviceNameOverride, .audioSinkOverride, .hideVolumeSlider,
        .combinedSwitchingPoint,
        .unavailableDDC, .minDDCOverride, .maxDDCOverride, .curveDDC, .invertDDC, .remapDDC,
      ]) { prefs in
        prefs.friendlyName = ""
        prefs.hideDisplay = false
        prefs.isDisabled = false
        prefs.hideOsd = false
        prefs.forceSoftware = false
        prefs.avoidGamma = false
        prefs.audioDeviceNameOverride = ""
        prefs.audioSinkOverride = .auto
        prefs.hideVolumeSlider = false
        prefs.combinedSwitchingPoint = 0
        // D26-cut prefs are reset too: they are invisible, so this button is
        // the only way out of a bad `defaults write`. None of these three is a
        // `PrefName` case (nothing reads them at pref-write time), so they are
        // written here and correctly absent from the fan-out list above.
        // `longerDelay` is reserved and inert — cleared for tidiness only.
        prefs.longerDelay = false
        prefs.pollingMode = .normal
        prefs.pollingCount = 0
        // ONE shared definition of "untouched", from CandelaKit, pinned by
        // `theFactoryTuningIsWhatAnUntouchedDisplayReports`.
        for command in DDCCommand.allCases {
          prefs.setTuning(.unset, for: command)
        }
      }

      // 3. `isAvailable` is true again, and `enableMuteUnmute` still holds the
      //    value the display was muted under — so this sends the RIGHT wire
      //    value (0x8D=2 in the dedicated-command strategy, a volume write
      //    otherwise). `toggleMute` also clears the persisted `muted` flag,
      //    which is why it is not written by hand.
      if state.volume.isMuted {
        _ = state.volume.toggleMute()
      }

      // 4. Only now retire the strategy. Its row is UI-only, so this second
      //    fan-out costs a re-render and nothing else.
      writer.write(.enableMuteUnmute) { $0.enableMuteUnmute = false }

      nameDraft = ""
      audioNameDraft = ""
    }
  }

  // MARK: - Mute recovery (D29 rule 2 + rule 3)

  /// Hardware-muted with the volume command turned off: `toggleMute` refuses
  /// while `isAvailable` is false, so nothing but `recoverFromHardwareMute`
  /// leaves this state.
  private var isStrandedMuted: Bool {
    state.volume.isMuted && !state.volume.isAvailable
  }

  /// Clears the availability prefs FIRST, then unmutes. Doing it in the other
  /// order is a silent no-op: `toggleMute` returns `isMuted` unchanged while
  /// `isAvailable` is false, and the user is left believing they unmuted.
  /// `enableMuteUnmute` is deliberately NOT touched — the display was muted
  /// under whatever strategy is in force, and that strategy has to still be in
  /// force for the unmute to send the right wire value.
  private func recoverFromHardwareMute() {
    // Two prefs, two rows, one union — `writeAll`, never a single
    // representative name.
    writer.writeAll([.forceSw, .unavailableDDC]) { prefs in
      prefs.forceSoftware = false
      var tuning = prefs.tuning(for: .volume)
      tuning.unavailableDDC = false
      prefs.setTuning(tuning, for: .volume)
    }
    _ = state.volume.toggleMute()
  }

  // MARK: - Draft commits

  private func commitName() {
    // One shared rule, in CandelaKit under test — blank under ANY whitespace
    // means "use the name the display reports".
    let trimmed = DisplayCardPolicy.normalizedFriendlyName(nameDraft)
    nameDraft = trimmed
    guard trimmed != prefs.friendlyName else { return }
    writer.write(.friendlyName) { $0.friendlyName = trimmed }
  }

  private func commitAudioName() {
    let trimmed = DisplayCardPolicy.normalizedFriendlyName(audioNameDraft)
    audioNameDraft = trimmed
    guard trimmed != prefs.audioDeviceNameOverride else { return }
    // Fans out to a tap re-arm: `audioDeviceNameOverride` feeds
    // `AppModel.tapConfig` through `audioMatchingDisplays` (D20/D2 bug 3).
    writer.write(.audioDeviceNameOverride) { $0.audioDeviceNameOverride = trimmed }
  }
}
