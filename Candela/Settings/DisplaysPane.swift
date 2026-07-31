import CandelaKit
import SwiftUI

/// Per-display settings. Structure follows the fork's rebuilt pane (chapter 2
/// §1.1): ONE card per display in a vertical stack. There is no table, no row
/// selection, no selected-display detail region and no sort control — display
/// ORDER is the panel's business (ascending, ungated, Task 5), not a setting.
/// A card here is a `Form` `Section`, which gives the same grouped-card look as
/// the other four panes with none of the fork's hand-pinned 660×560 chrome.
///
/// Lists EXTERNAL displays only (`model.displays`). The built-in panel is
/// deliberately absent: its `DisplayState` carries `NoopDDCWriter`-backed
/// volume/contrast controllers that still report `isAvailable == true`
/// (AppModel trap), so every DDC control on a built-in card would be a
/// live-looking no-op — and its one real setting, whether the panel shows it,
/// is the app-level toggle in the App Menu pane.
///
/// `@MainActor` as declared by the Task 3 stub — keep it: `DisplayCard`, which
/// this builds, is `@MainActor` for `DisplayPrefWriter`'s sake.
@MainActor
struct DisplaysPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    // Re-render after seam writes and external writes (M5 live-observation
    // contract): a control in this pane can change what another card shows.
    // `.refreshUI` on every known PrefName is what guarantees the bump.
    let _ = model.prefsRevision
    Form {
      if model.displays.isEmpty {
        Section {
          SettingsCaption(
            "No external displays are connected. A card appears here for each display \(AppInfo.productName) can control."
          )
        }
      }
      ForEach(model.displays) { state in
        DisplayCard(state: state)
      }
      if model.builtIn != nil {
        Section {
          SettingsCaption(
            "The built-in display has no per-display settings — macOS controls its brightness directly. Whether its slider appears is set under App Menu."
          )
        }
      }
    }
    .formStyle(.grouped)
  }
}

/// Every Displays-pane write goes through here: mutate the pref, then fan out
/// through the D20 seam. A control that writes a pref and does not propagate is
/// a broken control (the engine reads prefs at construction and at key time,
/// not reactively), so the two steps are deliberately not separable at the
/// call site.
@MainActor
struct DisplayPrefWriter {
  let persistenceKey: String
  let actions: SettingsActions
  let prefs: DisplayPrefs

  init(persistenceKey: String, actions: SettingsActions) {
    self.persistenceKey = persistenceKey
    self.actions = actions
    self.prefs = DisplayPrefs(persistenceKey: persistenceKey)
  }

  /// `name` is a `PrefName` case, i.e. the UNSUFFIXED pref name the propagation
  /// table keys on (`.forceSw`, never `"forceSw.<pk>"`). D27 closed this name
  /// space precisely because the old `String` form made `write("forceSW")` a
  /// silent no-op that wrote the pref and fanned out to nothing. The
  /// persistence key scopes the dimming re-apply to this display alone.
  func write(_ name: PrefName, _ mutate: (DisplayPrefs) -> Void) {
    mutate(prefs)
    actions.prefDidChange(name, persistenceKey: persistenceKey)
  }

  /// A batch: several prefs written together, fanning out to the UNION of
  /// their rows. Never collapse a batch onto one representative name — the
  /// rows are not nested (`hideDisplay` carries `.updateStatusItem`,
  /// `forceSw` does not), so picking a "superset" row silently drops effects.
  func writeAll(_ names: [PrefName], _ mutate: (DisplayPrefs) -> Void) {
    mutate(prefs)
    actions.prefsDidChange(names, persistenceKey: persistenceKey)
  }
}

/// One display's card.
///
/// `@MainActor` is load-bearing, not decoration: `DisplayPrefWriter` is
/// `@MainActor` (it holds `SettingsActions`), and a plain `struct … : View` has
/// nonisolated stored and computed properties under Swift 6 complete
/// concurrency, so `private var writer: DisplayPrefWriter { … }` would not
/// compile without it.
///
/// Task 14 adds the per-command tuning grid and the per-display reset button to
/// `advancedSection`.
@MainActor
struct DisplayCard: View {
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
  /// View state that SURVIVES a re-render, unlike the fork's disclosure, which
  /// collapsed on every pane rebuild (chapter 2 QUIRK 16).
  @State private var showsAdvanced = false
  @State private var confirmingReset = false

  private var persistenceKey: String { state.display.persistenceKey }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }

  var body: some View {
    Section {
      TextField("Name", text: $nameDraft, prompt: Text(verbatim: state.display.name))
        .focused($nameFocused)
        .onSubmit { commitName() }
        .onChange(of: nameFocused) { _, focused in
          if !focused { commitName() }
        }
      SettingsCaption("Shown in the menu bar panel. Leave it empty to use the name the display reports.")

      Toggle("Show this display in the menu bar panel", isOn: Binding(
        get: { !prefs.hideDisplay },
        set: { shown in writer.write(.hideDisplay) { $0.hideDisplay = !shown } }
      ))

      Toggle("Control this display with the keyboard", isOn: Binding(
        get: { !prefs.isDisabled },
        set: { enabled in writer.write(.isDisabled) { $0.isDisabled = !enabled } }
      ))
      SettingsCaption("When off, the brightness and volume keys skip this display.")

      Toggle("Show the volume slider in the panel", isOn: Binding(
        get: { !prefs.hideVolumeSlider },
        set: { shown in writer.write(.hideVolumeSlider) { $0.hideVolumeSlider = !shown } }
      ))
      // The hide-vs-disable split (panel §5.4) is only obvious once you have
      // seen both controls. This toggle removes the row; Advanced → "Volume
      // slider (when shown):" decides whether a row that IS shown takes input.
      // Without this sentence the two read as one setting worded twice — the
      // near-duplicate Task 13 handed to Task 18 for a copy pass.
      SettingsCaption("Removes the row entirely. Whether a slider that is shown accepts input is set under Advanced.")

      DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
        advancedSection
      }
    } header: {
      header
    }
    .onAppear {
      seedDrafts()
      // D29 rule 3 covers "never disabled"; a recovery row sitting inside a
      // disclosure that defaults CLOSED is reachable only by hunting, which is
      // the same defect one step weaker. Open Advanced by itself when this card
      // is stranded. Never closes it — checklist item 11's persistence holds.
      if isStrandedMuted { showsAdvanced = true }
    }
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

  // MARK: - Header

  /// The header carries the HARDWARE name, always — it is the display's
  /// identity, and keeping it fixed means renaming does not relabel the card
  /// you are editing. The rename field below shows the override.
  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: state.display.name)
      Text(controlMethodLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .textCase(nil)
    .help(controlMethodExplanation)
  }

  /// Candela's equivalent of the fork's `controlMethod` subtitle. The BRANCH
  /// lives in CandelaKit under test (`DisplayCardPolicy`); this is the
  /// presentation of its three cases, in the user's terms — never the pref
  /// name (D25).
  private var controlMethod: DisplayControlMethod {
    DisplayCardPolicy.controlMethod(
      forceSoftware: prefs.forceSoftware, avoidGamma: prefs.avoidGamma
    )
  }

  private var controlMethodLabel: LocalizedStringKey {
    switch controlMethod {
    case .hardwareDDC: "Hardware (DDC) control"
    case .softwareGamma: "Software dimming, color profile"
    case .softwareOverlay: "Software dimming, screen overlay"
    }
  }

  private var controlMethodExplanation: LocalizedStringKey {
    switch controlMethod {
    case .hardwareDDC:
      "This display accepts hardware brightness, volume and contrast commands over its data cable."
    case .softwareGamma:
      "Brightness is dimmed by adjusting the display's color profile. Volume and contrast are unavailable on this path."
    case .softwareOverlay:
      "Brightness is dimmed by drawing a dark overlay over the screen. The pointer is unaffected and full-screen transitions can flicker."
    }
  }

  // MARK: - Advanced

  @ViewBuilder private var advancedSection: some View {
    // `defaultOutputDevice()` does a blocking HAL round-trip when the CoreAudio
    // listener has not primed its cache — read it once, not once per consumer.
    let currentOutput = model.audioDevices.defaultOutputDevice()

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
    SettingsCaption("Turn this off if hardware control misbehaves on this display — brightness then dims in software, and volume and contrast become unavailable. Your current brightness is preserved either way.")

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
    SettingsCaption("Software dimming normally adjusts the display's color profile. Switch to an overlay if another app keeps taking the profile back, or on virtual and AirPlay displays.")

    Toggle("Show the on-screen volume indicator for this display", isOn: Binding(
      get: { !prefs.hideOsd },
      set: { shown in writer.write(.hideOsd) { $0.hideOsd = !shown } }
    ))
    SettingsCaption("Turn this off if macOS already shows its own volume indicator for this display. Brightness and contrast indicators are unaffected.")

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
      // strategy is still in force. Never `.disabled`.
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
    Picker("Volume slider (when shown):", selection: Binding(
      get: { prefs.audioSinkOverride },
      set: { override in writer.write(.audioSinkOverride) { $0.audioSinkOverride = override } }
    )) {
      Text("Enable automatically").tag(AudioSinkOverride.auto)
      Text("Always enabled").tag(AudioSinkOverride.forcePresent)
      Text("Always disabled").tag(AudioSinkOverride.forceNone)
    }
    SettingsCaption("\(AppInfo.productName) asks the display itself whether it accepts volume commands, and greys the slider only when the display says no. Override that when the answer is wrong for your setup — some displays report a volume control they ignore, and others accept volume they never advertise.")

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

    Divider()

    CommandTuningGrid(state: state, writer: writer)

    Divider()

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
