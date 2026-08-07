import CandelaKit
import CoreGraphics
import SwiftUI

/// The external display hub (spec §4): everything you change or consult about
/// one display, on one page, with Advanced / Diagnostics / the full mode list
/// pushed as sub-pages (SO1/SO2). `DisplayDetailView` hosts it under the hero.
///
/// Section order is the spec's: identity, Display, Sound, navigation, reset.
///
/// **Interim placements, owned by later tasks:** the preview/start-failure/
/// reapply banners and the stranded-mute recovery block render inline here
/// until Task 17's `BannerRegion` takes them (SO7/SO4). They are kept rather
/// than dropped because the recovery block is D29 rule 3 — a recovery control
/// must exist in the state it recovers from, and the Advanced sub-page that
/// will hold the DDC toggle is still a placeholder.
///
/// `@MainActor` for the reason every settings view records: a `View`'s stored
/// and computed properties other than `body` are nonisolated under complete
/// concurrency, and these read main-actor types.
@MainActor
struct DisplayHubView: View {
  let state: AppModel.DisplayState
  @Binding var selection: SettingsDestination?
  @Binding var path: [DisplaySubPage]
  /// Owned by `DisplayDetailView`, which watches the path shrink and hands
  /// focus back to the row that pushed (a11y contract 1, pop half).
  @FocusState.Binding var focusedRow: DisplaySubPage?

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  /// Drafts, not direct pref bindings: a `TextField` bound straight to a pref
  /// would write (and fan out, and bump `prefsRevision`) on every keystroke,
  /// re-rendering the pane mid-edit. Committed on Return and on focus loss;
  /// teardown discards them (SO10) — `@State` dies with the destination and
  /// nothing commits on the way out.
  ///
  /// Seeded at identity creation (the stack's `.id(key)` gives each display its
  /// own hub identity) and re-seeded on `prefsRevision` from `onChange`
  /// modifiers ON THE FIELDS themselves — a lifecycle hook on a `Section` or
  /// `Group` inside a grouped `Form` is not reliably applied (measured; see
  /// `DisplayDetailView`), and a re-seed that silently never fired would revive
  /// a wiped name on the next focus loss.
  @State private var nameDraft: String
  @State private var audioNameDraft: String
  @FocusState private var nameFocused: Bool
  @FocusState private var audioNameFocused: Bool
  @State private var confirmingReset = false

  init(
    state: AppModel.DisplayState,
    selection: Binding<SettingsDestination?>,
    path: Binding<[DisplaySubPage]>,
    focusedRow: FocusState<DisplaySubPage?>.Binding
  ) {
    self.state = state
    _selection = selection
    _path = path
    _focusedRow = focusedRow
    let prefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)
    _nameDraft = State(initialValue: prefs.friendlyName)
    _audioNameDraft = State(initialValue: prefs.audioDeviceNameOverride)
  }

  private var persistenceKey: String { state.display.persistenceKey }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }
  private var displayID: CGDirectDisplayID { state.display.id }
  private var coordinator: DisplayModeCoordinator { model.displayModes }
  private var catalog: DisplayModeCoordinator.Catalog? { coordinator.catalogs[displayID] }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults and not observable, so this is what
    // re-evaluates the hub after a write anywhere else — and what makes the
    // chevron previews re-read (SO3).
    let _ = model.prefsRevision
    identitySection
    displaySection
    soundSection
    navigationSection
    resetSection
  }

  // MARK: - Identity

  private var identitySection: some View {
    Section {
      SettingRow("Shown in the menu bar.") {
        TextField("Name", text: $nameDraft, prompt: Text(verbatim: state.display.name))
          .focused($nameFocused)
          .onSubmit { commitName() }
          .onChange(of: nameFocused) { _, focused in
            if !focused { commitName() }
          }
          .onChange(of: model.prefsRevision) { _, _ in
            guard !nameFocused else { return } // never fight a live edit
            nameDraft = prefs.friendlyName
          }
      }
      if model.isSharedIdentity(persistenceKey) {
        // SO21: same persistence key, same prefs — every control on this page
        // drives both units, and the user deserves to know before renaming one.
        SettingsCaption(verbatim: "Two identical displays are attached. They share these settings.")
      }

      Toggle("Show in the menu bar", isOn: Binding(
        get: { !prefs.hideDisplay },
        set: { shown in writer.write(.hideDisplay) { $0.hideDisplay = !shown } }
      ))

      // Kept adjacent to the row above — same question (spec §4). Whether a
      // slider that IS shown accepts input is the Sound section's picker.
      Toggle("Show the volume slider in the menu bar", isOn: Binding(
        get: { !prefs.hideVolumeSlider },
        set: { shown in writer.write(.hideVolumeSlider) { $0.hideVolumeSlider = !shown } }
      ))

      Toggle("Use brightness and volume keys for this display", isOn: Binding(
        get: { !prefs.isDisabled },
        set: { enabled in writer.write(.isDisabled) { $0.isDisabled = !enabled } }
      ))
    }
  }

  // MARK: - Display

  @ViewBuilder private var displaySection: some View {
    Section {
      previewBanner
      startFailureBanner
      reapplyBanner

      // A nil catalog is "not enumerated yet", NOT "no modes" — rendering the
      // empty state for it flashes false copy on every pane switch.
      if let catalog {
        if !catalog.rows.isEmpty {
          SettingRow("Changes how big text and windows look.") {
            sizePicker(catalog)
          }
          refreshPicker(catalog)
        } else if !catalog.all.isEmpty {
          // Every size this panel reports is under the usability floor. The
          // curated list is empty, the full one is not — so the sub-page below
          // is the whole feature here, and saying "no resolutions" while
          // holding dozens would be false.
          SettingsCaption("Every size this display reports is too small to use as a desktop. All Sizes & Refresh Rates lists them anyway.")
        } else {
          SettingsCaption("\(AppInfo.productName) found no resolutions it can switch between on this display.")
        }

        if !catalog.all.isEmpty {
          rememberRow
        }
      }

      RotationRows(state: state, coordinator: model.rotation)
      MirroringSection(state: state, coordinator: model.mirroring)

      if let catalog, !catalog.all.isEmpty {
        NavigationRow(
          title: "All Sizes & Refresh Rates",
          value: "\(catalog.all.count)",
          spokenValue: "\(catalog.all.count) modes"
        ) { path.append(.allModes) }
          .focused($focusedRow, equals: .allModes)
      }
    } header: {
      Text("Display").settingsHeading()
    }
  }

  /// The curated sizes as a dropdown.
  ///
  /// **The binding is one-way in practice, and deliberately so.** The getter
  /// reads the catalog's CURRENT mode — never a `@State` mirror, which would
  /// drift the moment a preview reverted, System Settings changed the mode, or
  /// the display was replugged. The setter is the only writer, and it does not
  /// assign anything: it calls `select(size:in:)`, so a choice still enters the
  /// preview-with-countdown-revert flow instead of stranding someone on a mode
  /// they cannot see. The popup therefore snaps back to the running mode until
  /// the change lands, which is the truth: nothing is applied until the preview
  /// is kept.
  @ViewBuilder private func sizePicker(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    Picker("Size", selection: Binding(
      get: { curatedSelection(in: catalog) },
      set: { id in
        guard let id, let row = catalog.rows.first(where: { $0.id == id }) else { return }
        select(size: row, in: catalog)
      }
    )) {
      // The size on screen is not always one we curated — a display left below
      // the usability floor by System Settings is still running something, and a
      // popup that named none of it would read as broken. Offered as an item so
      // the closed control tells the truth; choosing it is the no-op that
      // choosing the current size has always been.
      if curatedSelection(in: catalog) == nil {
        Text(verbatim: catalog.current.map(DisplayModeCopy.size) ?? "Unknown")
          .tag(DisplayModeRow.ID?.none)
      }
      ForEach(catalog.rows) { row in
        Text(verbatim: sizeItemLabel(row, in: catalog))
          .tag(DisplayModeRow.ID?.some(row.id))
      }
    }
  }

  /// The row's OUTCOME, not its catalog entry (SO18): a size whose applied mode
  /// cannot hold the rate now in use says so on the item.
  ///
  /// The Native/HiDPI/Scaled badges deliberately do NOT ride along: SO14
  /// retires "HiDPI" from copy, and the distinction words move to the full
  /// list, which tags low-resolution duplicates instead (Task 14).
  ///
  /// `currentHz` is `outcome`'s contract, not a hint: when the display has no
  /// current mode the caps warning is SUPPRESSED entirely — a placeholder 0
  /// would both disable the warning and name the wrong rate.
  private func sizeItemLabel(_ row: DisplayModeRow, in catalog: DisplayModeCoordinator.Catalog) -> String {
    let base = DisplayModeCopy.size(row.mode)
    guard let current = catalog.current,
          let outcome = DisplayModeCatalog.outcome(
            selectingWidth: row.mode.logicalWidth,
            selectingHeight: row.mode.logicalHeight,
            currentHz: current.refreshHz,
            in: catalog.all
          ),
          outcome.lowersCurrentRate
    else { return base }
    return "\(base) — caps at \(DisplayModeCopy.refresh(outcome.appliedHz))"
  }

  /// The curated row the display is running, by SIZE — `ioModeID` would come up
  /// empty whenever the user is at a size's slower refresh rate, since the row's
  /// representative mode is that size's fastest. nil means the running size is
  /// not one of ours.
  private func curatedSelection(in catalog: DisplayModeCoordinator.Catalog) -> DisplayModeRow.ID? {
    catalog.rows.first { catalog.isCurrentSize($0.mode) }?.id
  }

  /// Prospective (SO18): the rates offered are the SELECTED size's, read from
  /// the size picker's own selection — which, because that binding snaps to the
  /// running mode, is the current size until a choice lands. Quantized before
  /// deduplication: `refreshRates(in:)` dedupes raw doubles and would list 60
  /// twice the day float noise reached it, while NTSC's genuine 59.9 survives
  /// quantization as its own entry.
  @ViewBuilder private func refreshPicker(_ catalog: DisplayModeCoordinator.Catalog) -> some View {
    if let current = catalog.current {
      let selected = catalog.rows.first { $0.id == curatedSelection(in: catalog) }?.mode ?? current
      let raw = DisplayModeCatalog.refreshRates(
        in: catalog.all,
        logicalWidth: selected.logicalWidth,
        logicalHeight: selected.logicalHeight
      )
      let rates = dedupedQuantized(raw)
      if rates.count > 1 {
        Picker("Refresh rate", selection: Binding(
          get: { DisplayMode.quantizedRefresh(current.refreshHz) },
          set: { hz in select(refreshHz: hz, in: catalog) }
        )) {
          ForEach(rates, id: \.self) { hz in
            Text(verbatim: DisplayModeCopy.refresh(hz)).tag(hz)
          }
        }
      }
    }
  }

  private func dedupedQuantized(_ rates: [Double]) -> [Double] {
    var seen = Set<Double>()
    return rates.map(DisplayMode.quantizedRefresh).filter { seen.insert($0).inserted }
  }

  /// SO19: the stored mode is an explicit pin — visible while the toggle is on,
  /// written only by `Set to Current` and the toggle-on seeding, never by a kept
  /// preview.
  private var rememberRow: some View {
    SettingRow("Restored when this display reconnects, not while you are using it.") {
      VStack(alignment: .leading, spacing: 6) {
        Toggle("Remember this resolution", isOn: Binding(
          get: { coordinator.isRemembering(displayID) },
          set: { remembering in
            // Only the flag is announced here. Turning it on ALSO pins the
            // current mode (Task 11 seeding, inside `setRemembering`), and that
            // write announces itself from inside the coordinator
            // (`didStoreMode`) — naming `.storedDisplayMode` here as well would
            // put the rule in two places, which is how it was lost the first
            // time.
            coordinator.setRemembering(remembering, for: displayID)
            actions.prefDidChange(.rememberDisplayMode, persistenceKey: persistenceKey)
          }
        ))
        if coordinator.isRemembering(displayID),
           let stored = coordinator.storedDescriptor(for: displayID) {
          HStack {
            Text(verbatim: "\(DisplayModeCopy.size(stored)) · \(DisplayModeCopy.refresh(stored.refreshHz))")
              .foregroundStyle(.secondary)
            Spacer()
            // Disabled while a preview is outstanding: pinning a mode that is
            // still under countdown would record one the user may yet revert.
            // The coordinator's own queue re-checks (session-authoritative), so
            // this disable is courtesy, not the guard.
            Button("Set to Current") { coordinator.pinCurrentMode(on: displayID) }
              .disabled(pinnedMatchesCurrent(stored) || coordinator.preview?.displayID == displayID)
          }
        }
      }
    }
  }

  /// Reads the SAME source the pin writes — live configurator first, catalog
  /// cache as fallback (T11 review): after a countdown expiry the cache still
  /// names the reverted-away mode for a moment, and a comparison against it
  /// would enable the button for a pin that would be refused, or worse,
  /// disable it against a stale answer.
  private func pinnedMatchesCurrent(_ stored: DisplayModeDescriptor) -> Bool {
    guard let live = coordinator.configurator.currentMode(for: displayID) ?? catalog?.current
    else { return false }
    return live.descriptor == stored
  }

  // MARK: - Preview banners (interim — Task 17 moves these to BannerRegion)

  /// The SECOND surface, kept deliberately.
  ///
  /// `ModeConfirmationWindow` is the primary one — it takes every preview
  /// whatever started it, on the display that changed. This banner is the
  /// recovery path for every case where that window is on screen but not
  /// usable: a failed revert on a mode that left the display barely readable, a
  /// window that landed on a display the user cannot see, a preview whose
  /// display departed. Gated on the DISPLAY and never on origin, and answering
  /// with the same intent-carrying values, so whichever surface is reachable
  /// can end the same session.
  @ViewBuilder private var previewBanner: some View {
    if let preview = coordinator.preview, preview.displayID == displayID {
      VStack(alignment: .leading, spacing: 6) {
        Text("Keep this resolution?")
          .font(.callout.weight(.semibold))
        Text(verbatim: "\(DisplayModeCopy.size(preview.mode)), \(DisplayModeCopy.refresh(preview.mode.refreshHz))")
          .foregroundStyle(.secondary)

        if let failure = preview.failure {
          // Nothing auto-retries a failed resolution. Staying silent here would
          // leave the display on a mode the user never approved, held only
          // until the app exits.
          SettingsCaption(DisplayModeCopy.resolveFailure)
            .help("CoreGraphics error \(failure.cgErrorCode)")
        }
        if preview.isCountingDown {
          Text(verbatim: DisplayModeCopy.countdown(preview.secondsRemaining))
            .foregroundStyle(.secondary)
        } else if preview.failure != nil {
          SettingsCaption(DisplayModeCopy.expiryAlreadyRan)
        }

        HStack(spacing: 8) {
          // Both answers carry the preview THIS banner is rendering, so a
          // selection landing between the click and the queued operation is
          // refused as stale rather than resolved by an answer given about
          // something else. Keeping writes NO stored mode (SO19).
          Button("Keep") { Task { await coordinator.confirm(preview) } }
            .buttonStyle(.borderedProminent)
          Button("Revert Now") { Task { await coordinator.revert(preview) } }
        }
        // Belt to the intent check's braces: while a selection is still landing
        // the banner is about to change, so offering an answer to the old one
        // is pointless even though it is now harmless.
        .disabled(coordinator.isApplying)
      }
      .padding(.vertical, 2)
    }
  }

  @ViewBuilder private var startFailureBanner: some View {
    if let failure = coordinator.startFailure, failure.displayID == displayID {
      VStack(alignment: .leading, spacing: 6) {
        SettingsCaption(DisplayModeCopy.startFailure(failure.reason))
          .help(DisplayModeCopy.startFailureDiagnostic(failure.reason))
        Button("OK") { coordinator.dismissStartFailure() }
      }
    }
  }

  /// What reapply could not do, said where the stored-mode toggle that asked
  /// for it lives: the control that made the promise is the one that has to
  /// admit it could not keep it. An unplug does not take it away (SO8).
  @ViewBuilder private var reapplyBanner: some View {
    if let report = coordinator.report(for: displayID) {
      VStack(alignment: .leading, spacing: 6) {
        SettingsCaption(DisplayModeCopy.reapply(
          requested: report.requested, notice: report.notice
        ))
        .modifier(ReapplyDiagnostic(notice: report.notice))
        // Keyed by the report on screen, so OK can only clear the notice the
        // user is reading — and the same call the panel's OK makes.
        Button("OK") { coordinator.dismissReport(forKey: report.key) }
      }
      .padding(.vertical, 2)
    }
  }

  // MARK: - Mode selection

  /// Applies the chosen SIZE while keeping the refresh rate the display is
  /// already running, when that size offers it. The rule itself lives on
  /// `Catalog` — the panel applies the same one.
  private func select(size row: DisplayModeRow, in catalog: DisplayModeCoordinator.Catalog) {
    apply(catalog.modeKeepingCurrentRefreshRate(for: row), in: catalog)
  }

  private func select(refreshHz: Double, in catalog: DisplayModeCoordinator.Catalog) {
    guard let current = catalog.current else { return }
    let wanted = DisplayModeDescriptor(
      logicalWidth: current.logicalWidth,
      logicalHeight: current.logicalHeight,
      pixelWidth: current.pixelWidth,
      pixelHeight: current.pixelHeight,
      refreshHz: refreshHz
    )
    guard let mode = catalog.mode(matching: wanted, atSizeOf: current) else { return }
    apply(mode, in: catalog)
  }

  private func apply(_ mode: DisplayMode, in catalog: DisplayModeCoordinator.Catalog) {
    // Clicking the mode already on screen used to apply a no-op and then demand
    // "Keep this resolution?" with a full countdown for a change nobody made.
    guard mode.ioModeID != catalog.current?.ioModeID else { return }
    // Never speculative: this runs only from an explicit click naming this
    // display's mode. No `Task` here — `select` is fire-and-forget into the
    // coordinator's queue, which is what serialises two fast clicks; spawning
    // one per click is precisely how the banner ends up naming a different mode
    // than the one "Keep" would commit.
    //
    // `.settings` no longer picks the answering surface — the confirmation
    // window takes every preview now — but it still routes a failed `begin()`,
    // which this page reports in `startFailureBanner` and the panel cannot.
    coordinator.select(mode, on: displayID, from: .settings)
  }

  // MARK: - Sound

  @ViewBuilder private var soundSection: some View {
    // `defaultOutputDevice()` does a blocking HAL round-trip when the CoreAudio
    // listener has not primed its cache — read it once, not once per consumer.
    let currentOutput = model.audioDevices.defaultOutputDevice()

    Section {
      LabeledContent("Volume keys") {
        HStack(spacing: 8) {
          Text(verbatim: volumeKeysStatus)
            .foregroundStyle(.secondary)
          // The #1 ordinary-user task must be findable from the display's page
          // (spec §4): the keys are configured app-wide under Keyboard.
          Button("Keyboard Settings…") { selection = .pane(.keyboard) }
            .buttonStyle(.link)
        }
      }

      SettingRow(caption: SettingsCaption(muteCaption)) {
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
        // Disable, don't hide: the control does not apply while the volume
        // command is off, and saying so beats a missing row. Disabling it does
        // NOT make the D22 hazard unreachable, and the recovery below works
        // regardless of `isAvailable` (D29 rule 3).
        .disabled(!state.volume.isAvailable)
      }

      strandedMuteRecovery

      SettingRow("\(AppInfo.productName) asks the display; the slider is greyed only when it says no.") {
        Picker("Volume slider", selection: Binding(
          get: { prefs.audioSinkOverride },
          set: { override in writer.write(.audioSinkOverride) { $0.audioSinkOverride = override } }
        )) {
          Text("Enable automatically").tag(AudioSinkOverride.auto)
          Text("Always enabled").tag(AudioSinkOverride.forcePresent)
          Text("Always disabled").tag(AudioSinkOverride.forceNone)
        }
      }

      SettingRow("Used when the volume keys pick a display by audio output. Empty matches the display's name.") {
        LabeledContent("Audio device name") {
          HStack(spacing: 8) {
            TextField("", text: $audioNameDraft, prompt: Text("Automatic"))
              .focused($audioNameFocused)
              .onSubmit { commitAudioName() }
              .onChange(of: audioNameFocused) { _, focused in
                if !focused { commitAudioName() }
              }
              .onChange(of: model.prefsRevision) { _, _ in
                guard !audioNameFocused else { return } // never fight a live edit
                audioNameDraft = prefs.audioDeviceNameOverride
              }
              .frame(width: 180)
            Button("Use Current") {
              audioNameDraft = currentOutput?.name ?? ""
              commitAudioName()
            }
            .disabled(currentOutput == nil)
          }
        }
      }
    } header: {
      Text("Sound").settingsHeading()
    }
  }

  /// Mirrors what the key path actually consults: the display's own volume
  /// availability, this display's keyboard opt-out, and the app-wide volume key
  /// mode — so this row cannot say "On" about keys that would skip the display.
  private var volumeKeysStatus: String {
    if !state.volume.isAvailable { return "Not available on this display" }
    if prefs.isDisabled { return "Off" }
    let mode = prefs.keyboardVolume
    let active = KeyModePolicy.watchesMediaKeys(mode) || KeyModePolicy.firesCustomShortcuts(mode)
    return active ? "On" : "Off"
  }

  /// SO5: a recoverable state never borrows an unrecoverable state's copy — the
  /// two sentences are distinct because the states are.
  private var muteCaption: LocalizedStringKey {
    state.volume.isAvailable
      ? "Off: muting sets volume to zero. On: sends the display's own mute command."
      : "Volume control is off for this display, so mute is unavailable."
  }

  /// D29 rule 3 — the explicit unmute affordance, never `.disabled`. This is
  /// the ONLY control that can leave the state, because `toggleMute` refuses
  /// while `isAvailable` is false; it clears the two prefs that make it false
  /// FIRST (D29 rule 2), then unmutes while the display's current mute strategy
  /// is still in force. Interim placement: Task 17 moves this block to the
  /// destination's banner region (SO4) — it must never be dropped in between,
  /// because the DDC toggle that re-enables the command lives on a sub-page
  /// that is still a placeholder.
  @ViewBuilder private var strandedMuteRecovery: some View {
    if isStrandedMuted {
      VStack(alignment: .leading, spacing: 4) {
        Text("This display is muted in hardware.")
        Button("Turn Hardware Control Back On and Unmute") { recoverFromHardwareMute() }
      }
      SettingsCaption("Muting used the display's own mute command, and that command can only be undone over hardware control. This turns hardware control back on for this display and unmutes it.")
    }
  }

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

  // MARK: - Navigation

  private var navigationSection: some View {
    Section {
      // The only hedge on the page, and it sits before the navigation rather
      // than on the sub-page, where it would arrive too late to save the trip.
      SettingRow("Settings most displays don't need.") {
        NavigationRow(title: "Advanced", value: advancedPreview) { path.append(.advanced) }
          .focused($focusedRow, equals: .advanced)
      }
      NavigationRow(title: "Diagnostics", value: readbackVerdict) { path.append(.diagnostics) }
        .focused($focusedRow, equals: .diagnostics)
    }
  }

  /// SO3: composed from live `DisplayPrefs` reads on every body evaluation —
  /// the body's `prefsRevision` read is what makes a write anywhere re-run
  /// this, so the preview cannot outlive the values it describes.
  ///
  /// `hideOsd` is passed as its own fact and deliberately NOT counted into
  /// `overrideCount` — the policy folds it in itself, and counting it here
  /// would double it (T5 review).
  private var advancedPreview: String {
    var overrides = 0
    for command in DDCCommand.allCases {
      let tuning = prefs.tuning(for: command)
      if tuning.unavailableDDC { overrides += 1 }
      if tuning.minDDCOverride != DDCOverrideValidation.unset { overrides += 1 }
      if tuning.maxDDCOverride != DDCOverrideValidation.unset { overrides += 1 }
      // 0 (unset) and 5 are both linear (`DimmingMath.curveMultiplier`), so
      // neither is an override.
      if tuning.curveIndex != 0, tuning.curveIndex != 5 { overrides += 1 }
      if tuning.invert { overrides += 1 }
      if !tuning.remapCodes.isEmpty { overrides += 1 }
    }
    if prefs.combinedSwitchingPoint != 0 { overrides += 1 }
    if prefs.pollingMode != .normal { overrides += 1 }
    if prefs.pollingCount != 0 { overrides += 1 }
    return AdvancedPreviewPolicy.label(for: AdvancedSnapshot(
      ddcOff: prefs.forceSoftware,
      overlayOn: prefs.avoidGamma,
      osdHidden: prefs.hideOsd,
      overrideCount: overrides
    ))
  }

  /// The diagnostics page's own worst-of-three readback verdict, previewed. One
  /// `allZeros` is never cancelled by a later `notAttempted` — the write-only
  /// panel is a permanent property, and the preview must not soften it.
  private var readbackVerdict: String {
    switch DDCReadEvidence.worst([
      state.controller.readEvidence,
      state.volume.readEvidence,
      state.contrast.readEvidence,
    ]) {
    case .notAttempted: "Not asked yet"
    case .answered: "Answers reads"
    case .allZeros: "Write-only"
    case .noReply: "Not answering"
    }
  }

  // MARK: - Reset

  private var resetSection: some View {
    Section {
      // Plain at rest (SO20): the destructive role lives on the alert's confirm
      // button, not on a red button waiting on every display's page.
      Button("Reset Display Settings…") { confirmingReset = true }
        .alert("Reset the settings for this display?", isPresented: $confirmingReset) {
          Button("Reset", role: .destructive) { resetDisplay() }
          Button("Cancel", role: .cancel) {}
        } message: {
          // Names the Advanced-page work explicitly (SO20), and names what is
          // NOT lost: the saved levels are the only source of truth on a
          // write-only panel, so a reset that took them would leave the display
          // at an unknown brightness — and the pinned resolution and rotation
          // are macOS-visible state this button deliberately leaves alone.
          Text("This unmutes \(state.display.name), turns HDR off, and clears its \(AppInfo.productName) settings — name, menu bar visibility, keyboard, sound, and everything under Advanced, including control-code remaps and response curves. Saved brightness, volume and contrast levels are kept. Resolution and rotation are not changed.")
        }
    }
  }

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
      //
      //    UNCONDITIONAL (#83). Gating this on `hdrMode != .off` skipped the
      //    disengage for HDR engaged in System Settings, and then everything
      //    below — including the D29 unmute — ran against a register the
      //    monitor still had locked. `setHDRMode` owns the "is there anything
      //    to do" question now, so the condition cannot drift from it here.
      await state.controller.setHDRMode(.off)

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
        .combinedSwitchingPoint, .pollingMode, .pollingCount,
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
        prefs.pollingMode = .normal
        prefs.pollingCount = 0
        // `longerDelay` is reserved and inert, and NOT a `PrefName` case
        // (nothing reads it at pref-write time) — cleared for tidiness only,
        // and correctly absent from the fan-out list above. `pollingMode` and
        // `pollingCount` used to sit in this comment's "not a case" list; the
        // settings overhaul gave them real UI and `PrefName` cases, so they
        // are named in the batch now.
        prefs.longerDelay = false
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
