import CandelaKit
import CoreGraphics
import SwiftUI

/// The external display hub (spec §4): everything you change or consult about
/// one display, on one page, with Advanced / Diagnostics / the full mode list
/// pushed as sub-pages (SO1/SO2). Owns the whole page — hero included —
/// because the sections must sit directly in the `Form`'s builder (see the
/// measured note in `body`); `DisplayDetailView` stays as the navigation
/// shell's thin destination host.
///
/// Section order is the spec's: identity, Display, Sound, navigation, reset.
///
/// Banners — the countdown surface, start failures, reapply notices, the
/// stranded-mute recovery, the first-sight line — are NOT this page's:
/// `BannerRegion` renders them above this view and above every pushed
/// sub-page (SO7), from `SettingsRootView`'s two placements alone.
///
/// `@MainActor` for the reason every settings view records: a `View`'s stored
/// and computed properties other than `body` are nonisolated under complete
/// concurrency, and these read main-actor types.
@MainActor
struct DisplayHubView: View {
  let state: AppModel.DisplayState
  @Binding var selection: SettingsDestination?
  @Binding var path: [DisplaySubPage]

  /// A11y contract 1, pop half: when the path shrinks, focus returns to the
  /// chevron row that pushed. Owned HERE, beside the rows that tag themselves
  /// with it, and driven by the `onChange` on the `Form` below.
  @FocusState private var focusedRow: DisplaySubPage?

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  /// SO6's "key settings window" test, read at the click that starts a
  /// preview: `.key` exactly when this view's window is the key window.
  @Environment(\.controlActiveState) private var controlActiveState
  /// Written by the OLED Care link so the pane opens on THIS display's section.
  @Environment(\.oledCareScrollTarget) private var oledCareScrollTarget

  /// Drafts, not direct pref bindings: a `TextField` bound straight to a pref
  /// would write (and fan out, and bump `prefsRevision`) on every keystroke,
  /// re-rendering the pane mid-edit. Committed on Return and on focus loss;
  /// on teardown the `@State` dies with the destination and no commit is
  /// scheduled (SO10 — the same shape the pre-hub page shipped with).
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
    path: Binding<[DisplaySubPage]>
  ) {
    self.state = state
    _selection = selection
    _path = path
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
    // The hub owns the `Form` and every section sits DIRECTLY in its builder.
    // Measured 2026-08-06: hosting the same five sections in a child view
    // placed inside a parent's `Form` mis-sized the List's scrollable extent —
    // the page pinned ~110 pt short of its end and the reset section was
    // unreachable by scrolling. Same defect family as the Section-lifecycle
    // no-op recorded on `DisplayDetailView`: a grouped `Form` only reliably
    // handles structure declared in its own builder.
    Form {
      DisplayHeroView(state: state)
      identitySection
      displaySection
      soundSection
      oledCareSection
      navigationSection
      resetSection
    }
    .formStyle(.grouped)
    // Mode enumeration is several CoreGraphics round-trips, so it runs here
    // rather than per body evaluation. It hangs off the Form, not off a
    // section: a modifier applied to a `Section` inside a grouped `Form` is
    // not reliably applied to the section itself, and a lifecycle hook that
    // silently never fires would leave the resolution list empty. Any LATER
    // resolution change — ours, System Settings', or a replug — re-enumerates
    // through the coordinator's own screen-parameters observer, which must run
    // whether or not this page is on screen.
    .task(id: state.id) { model.displayModes.refreshCatalog(for: state.id) }
    // Pop restoration: the row that pushed the page just popped takes focus
    // back. Only ever a SHRINK is acted on — a push moves focus forward via
    // `SubPageHeader`'s own on-appear focus, and fighting it from here would
    // yank the cursor back to the hub mid-push.
    .onChange(of: path) { old, new in
      if new.count < old.count, let popped = old.last {
        focusedRow = popped
      }
    }
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
    return "\(base) (caps at \(DisplayModeCopy.refresh(outcome.appliedHz)))"
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
    // Never speculative: this runs only from an explicit click naming this
    // display's mode. No `Task` here — `selectFromList` is fire-and-forget into
    // the coordinator's queue, which is what serialises two fast clicks;
    // spawning one per click is precisely how the banner ends up naming a
    // different mode than the one "Keep" would commit. It also carries the
    // already-on-screen guard, shared with the full mode list.
    //
    // `.settings` routes a failed `begin()` to the banner region, which the
    // panel cannot show. The SURFACE is the SO6 decision, sampled from this
    // window's key state synchronously at the click: key settings window →
    // the banner region answers and the floating window stays away; anything
    // else keeps the floating default.
    coordinator.selectFromList(
      mode, on: displayID, from: .settings,
      surface: controlActiveState == .key ? .settingsBanner : .floatingPanel,
      currentModeID: catalog.current?.ioModeID
    )
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
        // NOT make the D22 hazard unreachable, and the stranded-mute recovery
        // in `BannerRegion` works regardless of `isAvailable` (D29 rule 3) —
        // rendered above this page and every sub-page, so it cannot be
        // scrolled out of existence by the state it recovers from.
        .disabled(!state.volume.isAvailable)
      }

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

  /// Mirrors what the key path actually consults, so this row cannot say "On"
  /// about keys that would move nothing. TWO unavailability signals, and EITHER
  /// one is enough: `volume.isAvailable` is the pref side (the command or
  /// hardware control turned off for this display), `volumeSliderEnabled` is D24's:
  /// the monitor's own denial, the same verdict that greys the hero's slider.
  /// The Dell answers its capabilities with no VCP 0x62, and this row saying
  /// "On" there would contradict the greyed slider two sections up.
  private var volumeKeysStatus: String {
    if !state.volume.isAvailable || !model.volumeSliderEnabled(state) {
      return "Not available on this display"
    }
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

  // MARK: - OLED Care

  /// The SO2 split of W3a's per-display care controls, sitting between Sound
  /// and the navigation section: the hub holds the decision you change
  /// (enrollment — OC2's explicit opt-in, so it must be reachable where the
  /// display's other everyday controls are) and the state you consult (what
  /// the care engine is doing right now, as the chevron's value). The
  /// thresholds, levels, hours and the global chrome switches are set-once and
  /// stay on the OLED Care pane, which OC3 keeps as their dedicated home.
  ///
  /// The route to the rest is a sidebar-selection change, NOT a push: SO1
  /// closes the pushed set at three sub-pages, and OLED Care is already a
  /// top-level destination. It therefore wears the app's cross-pane LINK idiom
  /// (the Sound section's Keyboard Settings link), never `NavigationRow`'s
  /// chevron: a chevron promises a pushed page with a Back button, and this
  /// jump keeps neither (combined pass D7). SO3's live preview stays, as the
  /// row's value text beside the link.
  private var oledCareSection: some View {
    Section {
      SettingRow("Enrolling applies the recommended settings; nothing changes until this display has been idle for a while.") {
        Toggle("Enroll this display in OLED care", isOn: Binding(
          get: { prefs.oledCareEnrolled },
          set: { on in writer.write(.oledCareEnrolled) { $0.oledCareEnrolled = on } }
        ))
      }
      LabeledContent("Care status") {
        HStack(spacing: 8) {
          Text(verbatim: oledCarePreview)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(oledCareSpokenPreview))
          // Carries this display with the jump: the OLED Care pane holds one
          // section per connected display, and a link from a display's own hub
          // that lands at the top of a multi-display page makes the reader
          // find their way back to where they already were. The pane consumes
          // the target once, so a plain sidebar visit still opens at the top.
          Button("All OLED Care Settings…") {
            oledCareScrollTarget.wrappedValue = persistenceKey
            selection = .pane(.oledCare)
          }
          .buttonStyle(.link)
        }
      }
    } header: {
      Text("OLED Care").settingsHeading()
    }
  }

  /// SO3's value preview, from the coordinator's OWN published state — never a
  /// second opinion computed here. Short forms of the OLED Care pane's status
  /// row; the exhaustive switch makes a new engine state a compile error
  /// rather than a stale preview.
  private var oledCarePreview: String {
    guard prefs.oledCareEnrolled else { return "Off" }
    if model.isSafeMode { return "Paused" }
    switch model.oledCare.dimStates[persistenceKey] {
    case .active: return "On"
    case .idleDim, .unfocusedDim: return "Dimmed"
    // OC7 sub-ruling 4: a refused lock dim is recorded and must not be
    // reported as dimmed. `lockDimSkips` is observed, so this preview re-reads
    // when the refusal appears or clears.
    case .lockDim: return OledCareCopy.lockDimPreview(model.oledCare.lockDimSkips[persistenceKey])
    case .blackout: return "Screen off"
    case .suspended: return "Paused"
    case nil: return "Starting"
    }
  }

  /// "Paused" alone would leave VoiceOver users guessing at the reason the
  /// sighted preview defers to the pane for.
  private var oledCareSpokenPreview: String {
    guard prefs.oledCareEnrolled else { return "Off" }
    if model.isSafeMode { return "Paused for this session, Safe Mode" }
    switch model.oledCare.dimStates[persistenceKey] {
    case .active: return "On, not dimming"
    case .idleDim: return "Dimmed, the display has been idle"
    case .lockDim:
      return OledCareCopy.lockDimSpokenPreview(model.oledCare.lockDimSkips[persistenceKey])
    case .unfocusedDim: return "Dimmed, no window in focus on this display"
    case .blackout: return "Screen off, the display has been idle"
    case .suspended: return "Paused while this display is mirrored"
    case nil: return "Starting"
    }
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

  /// The diagnostics page's own worst-of-three readback verdict, previewed —
  /// through the page's own vocabulary (`DiagnosticsCopy`), which the report
  /// also uses, so the three surfaces cannot drift apart. One `allZeros` is
  /// never cancelled by a later `notAttempted`: a write-only display is a
  /// permanent property, and the preview must not soften it.
  private var readbackVerdict: String {
    DiagnosticsCopy.readbackVerdict(DDCReadEvidence.worst([
      state.controller.readEvidence,
      state.volume.readEvidence,
      state.contrast.readEvidence,
    ]))
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
          // Counted panel hours are wear data, kept for the same reason the
          // levels are.
          Text("This unmutes \(state.display.name), turns HDR off, and clears its \(AppInfo.productName) settings: name, menu bar visibility, keyboard, sound, OLED care, and everything under Advanced, including control-code remaps and response curves. Saved brightness, volume and contrast levels are kept, and so are its counted hours of use. The remembered resolution and rotation are not changed.")
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
      //    NOT everything keyed to this display: the mute strategy is step 4
      //    (ordering), and the remembered display mode is deliberately outside
      //    — a resolution the user is currently looking at is not a setting
      //    this button promises to change.
      writer.writeAll([
        .friendlyName, .hideDisplay, .isDisabled, .hideOsd, .forceSw, .avoidGamma,
        .audioDeviceNameOverride, .audioSinkOverride, .hideVolumeSlider,
        .combinedSwitchingPoint, .pollingMode, .pollingCount,
        .unavailableDDC, .minDDCOverride, .maxDDCOverride, .curveDDC, .invertDDC, .remapDDC,
        // OLED care's ten, all carrying `.reapplyOledCare`: un-enrolling is
        // what takes this display's care overlay down, and the fan-out is what
        // makes it happen now rather than on the next topology event. The
        // direction is safe by construction — a reset can only remove an
        // overlay, never leave one up.
        .oledCareEnrolled, .oledIdleDimSeconds, .oledIdleDimLevel, .oledLockDim,
        .oledBlackoutEnabled, .oledBlackoutSeconds,
        .oledUnfocusedDimEnabled, .oledUnfocusedDimSeconds, .oledUnfocusedDimLevel,
        .oledHoursTracking,
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
        // REMOVES the ten OLED keys rather than writing today's numbers back:
        // the accessors' defaults ARE the Recommended preset, so a reset that
        // wrote them would pin this display to the preset as it stands today.
        // Panel hours are not prefs and are deliberately kept (wear data, like
        // the saved levels above).
        prefs.resetOledCare()
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
