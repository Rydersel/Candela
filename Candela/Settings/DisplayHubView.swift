import CandelaKit
import CoreGraphics
import os
import SwiftUI

/// The reset path's own category: a reset that stands a hardware step down has
/// to say so somewhere a person can find later.
private let resetLog = Logger(subsystem: "com.rydersel.Candela", category: "reset")

/// The external display hub: everything you change or consult about one display,
/// on one page, with Advanced / Diagnostics / the full mode list pushed as
/// sub-pages (SO1/SO2). Owns the whole page, hero included; `DisplayDetailView`
/// is only the navigation shell's destination host.
///
/// Banners are NOT this page's: `BannerRegion` renders them above this view and
/// above every pushed sub-page (SO7).
///
/// `@MainActor` because a `View`'s properties other than `body` are nonisolated
/// under complete concurrency, and these read main-actor types.
@MainActor
struct DisplayHubView: View {
  let state: AppModel.DisplayState
  @Binding var selection: SettingsDestination?
  @Binding var path: [DisplaySubPage]

  /// A11y contract 1, pop half: when the path shrinks, focus returns to the
  /// chevron row that pushed.
  @FocusState private var focusedRow: DisplaySubPage?

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  /// SO6's "key settings window" test, read at the click that starts a
  /// preview: `.key` exactly when this view's window is the key window.
  @Environment(\.controlActiveState) private var controlActiveState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Written by the OLED Care link so the pane opens on THIS display's page.
  @Environment(\.oledCarePath) private var oledCarePath

  /// Drafts, not direct pref bindings: a `TextField` bound straight to a pref
  /// would write, fan out and bump `prefsRevision` on every keystroke,
  /// re-rendering the pane mid-edit. Committed on Return and on focus loss; on
  /// teardown the `@State` dies with the destination and nothing is scheduled
  /// (SO10).
  ///
  /// Seeded at identity creation and re-seeded on `prefsRevision` from `onChange`
  /// modifiers ON THE FIELDS themselves, so a re-seed cannot silently stop firing
  /// and revive a wiped name on the next focus loss.
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
  private var synthesis: SynthesisCoordinator { model.synthesis }
  private var catalog: DisplayModeCoordinator.Catalog? { coordinator.catalogs[displayID] }
  /// The shared apply path, with SO6's answering surface sampled from this
  /// window's key state when the row is built. This one is the recommendation
  /// callout's; it applies the same row through the same countdown (PD9).
  private var resolutionSelection: ResolutionSelection {
    ResolutionSelection(
      coordinator: coordinator,
      displayID: displayID,
      surface: controlActiveState == .key ? .settingsBanner : .floatingPanel
    )
  }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults, not observable: this re-evaluates
    // the hub after a write anywhere else, and re-reads the previews (SO3).
    let _ = model.prefsRevision
    // Every card sits directly in the scaffold's builder: the page is one
    // reading order, not seven fragments composed from child views.
    SettingsPageScaffold {
      DisplayHeroView(state: state)
      identityCard
      menuBarCard
      keyboardCard
      displayCard
      soundCard
      oledCareCard
      navigationCard
      resetCard
    }
    // Mode enumeration is several CoreGraphics round-trips, so it runs here
    // rather than per body evaluation. Any later change re-enumerates through
    // the coordinator's screen-parameters observer, which runs whether or not
    // this page is on screen.
    .task(id: state.id) { model.displayModes.refreshCatalog(for: state.id) }
    // Pop restoration: the row that pushed the page just popped takes focus
    // back. Only a SHRINK is acted on; a push moves focus forward through
    // `SubPageHeader`, and fighting that from here would yank the cursor back.
    .onChange(of: path) { old, new in
      if new.count < old.count, let popped = old.last {
        focusedRow = popped
      }
    }
  }

  // MARK: - Identity

  /// The name and what it is shared with. Headerless: the hero above is the
  /// display, and a kicker naming it again would be the third time on one screen.
  private var identityCard: some View {
    SettingsCardSection {
      SettingRow("Shown in the menu bar.") {
        HStack(spacing: 2) {
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
            .prefIdentifier(.friendlyName, persistenceKey: persistenceKey)
          // Only while there is a name to clear; otherwise the escape route is
          // select-all-and-delete, which nothing on the page suggests. A sibling
          // of the field rather than a branch around it, so the `buildOptional`
          // slot is the button's own and the field is never rebuilt under a live
          // edit.
          if hasCustomName {
            Button(action: clearName) {
              Image(systemName: "xmark.circle.fill")
                // The glyph alone is a ~13 pt target at the row's trailing
                // edge. `contentShape` is what makes the padding clickable
                // rather than merely empty.
                .padding(4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            // Says the outcome, not the gesture: the hardware name comes back
            // as the placeholder, and a VoiceOver user cannot see it arrive.
            .accessibilityLabel("Use the Display's Own Name")
            .help("Clear this name and use the one the display reports.")
          }
        }
        // The field gives up about 20 pt when the button arrives and takes it
        // back when it goes, both while the caret may be in it. Declarative
        // rather than `withAnimation` at the call site because the flip has four
        // routes in plus any external write, and only a predicate on the value
        // covers them all. Keyed to `hasCustomName`, so typing animates nothing.
        .animation(Motion.disclosure(reduceMotion: reduceMotion), value: hasCustomName)
      }
      if model.isSharedIdentity(persistenceKey) {
        // SO21: same persistence key, same prefs, so every control on this page
        // drives both units, and the user deserves to know before renaming one.
        SettingsRowNote(verbatim: "Two identical displays are attached. They share these settings.")
      }
    }
  }

  /// The two menu-bar questions, under their own kicker (SV14).
  private var menuBarCard: some View {
    SettingsCardSection(title: "In the Menu Bar") {
      SettingRow {
        Toggle("Show in the menu bar", isOn: Binding(
          get: { !prefs.hideDisplay },
          set: { shown in writer.write(.hideDisplay) { $0.hideDisplay = !shown } }
        ))
        .themedSwitch()
        .prefIdentifier(.hideDisplay, persistenceKey: persistenceKey)
      }

      SettingsCardDivider()

      // Kept adjacent to the row above: same question. Whether a slider that IS
      // shown accepts input is the Sound section's picker.
      SettingRow {
        Toggle("Show the volume slider in the menu bar", isOn: Binding(
          get: { !prefs.hideVolumeSlider },
          set: { shown in writer.write(.hideVolumeSlider) { $0.hideVolumeSlider = !shown } }
        ))
        .themedSwitch()
        .prefIdentifier(.hideVolumeSlider, persistenceKey: persistenceKey)
      }
    }
  }

  /// Its own card rather than the menu-bar one, because it is not a menu-bar
  /// setting.
  private var keyboardCard: some View {
    SettingsCardSection(title: "Keyboard") {
      SettingRow {
        Toggle("Use brightness and volume keys for this display", isOn: Binding(
          get: { !prefs.isDisabled },
          set: { enabled in writer.write(.isDisabled) { $0.isDisabled = !enabled } }
        ))
        .themedSwitch()
        .prefIdentifier(.isDisabled, persistenceKey: persistenceKey)
      }
    }
  }

  /// Keyed to the STORED name, never the draft: a half-typed name is not one
  /// this display wears anywhere else, and a predicate on the draft would add
  /// and remove a control on the first and last keystroke of every edit.
  /// `normalizedFriendlyName` is the rule the title fallback uses, so a
  /// whitespace name shows the hardware name AND offers nothing to clear.
  private var hasCustomName: Bool {
    !DisplayCardPolicy.normalizedFriendlyName(prefs.friendlyName).isEmpty
  }

  // MARK: - Display

  /// Dividers are decided HERE rather than inside the shared child views: only
  /// this composition knows which neighbour renders, and a divider a child drew
  /// for itself would open the card whenever the block above it was absent.
  private var displayCard: some View {
    SettingsCardSection(title: "Display") {
      // A nil catalog is "not enumerated yet", NOT "no modes": rendering the
      // empty state for it flashes false copy on every pane switch.
      if let catalog {
        // Shared with the built-in display's page, which offers the same choice
        // over the same engine. What stays here is external-only: the density
        // model's callout and SS14's synthesis opt-in.
        DisplaySizeRows(catalog: catalog)

        recommendationCallout(catalog)
        moreSizesRows(catalog)

        if !catalog.all.isEmpty {
          SettingsCardDivider()
          RememberResolutionRow(displayID: displayID, persistenceKey: persistenceKey)
        }
        // The mirroring status row always follows, so this closes the
        // catalog block rather than opening the next one.
        SettingsCardDivider()
      }

      RotationRows(state: state, coordinator: model.rotation)
      // The same predicate `RotationRows` guards itself on, read off the same
      // coordinator: the rows above exist exactly when this is true.
      if model.rotation.canRotate { SettingsCardDivider() }
      MirroringSection(state: state, coordinator: model.mirroring)

      if let catalog, !catalog.all.isEmpty {
        SettingsCardDivider()
        NavigationRow(
          title: "All Sizes & Refresh Rates",
          value: "\(catalog.all.count)",
          spokenValue: "\(catalog.all.count) modes"
        ) { path.append(.allModes) }
          .focused($focusedRow, equals: .allModes)
      }
    }
  }

  /// The density model's suggestion as an ACTION, where the badge on the size
  /// picker is only a mark (PD8). Each condition removes the row for a different
  /// reason: no recommendation, the user closed it, the user already applied a
  /// size this session, no curated row to apply (the wire-timing guard can
  /// withhold one), or the display already runs that size. That last is why
  /// applying writes no dismissal: one written here would also hide a LATER
  /// recommendation on this display.
  ///
  /// Matched through `isRecommendedSize`, the same predicate the picker's mark
  /// uses, so the applied row and the marked row cannot drift. The copy asks the
  /// mode's NATIVE flag rather than the row's `isScaled`, which is framebuffer
  /// equality: an exact-2x HiDPI mode renders into the native framebuffer at half
  /// the logical size, so `isScaled` calls it unscaled and the native sentence
  /// would be false there. Anything the flag leaves out gets the scaled sentence,
  /// the milder claim.
  @ViewBuilder private func recommendationCallout(
    _ catalog: DisplayModeCoordinator.Catalog
  ) -> some View {
    if let recommendation = catalog.density?.recommendation,
       !prefs.sizeRecommendationDismissed,
       !coordinator.sizeAppliedByUser.contains(displayID),
       let row = catalog.rows.first(where: { catalog.isRecommendedSize($0.mode) }),
       !catalog.isCurrentSize(row.mode) {
      // Never the card's first row: the size rows above always render when
      // there is a catalog.
      SettingsCardDivider()
      SettingRow(caption: SettingsCaption(verbatim: DisplayModeCopy.recommendationCallout(
        width: recommendation.logicalWidth, height: recommendation.logicalHeight,
        isNative: row.mode.isNative
      ))) {
        HStack(spacing: 10) {
          // The SAME apply the picker uses, countdown and all (PD9): a
          // recommended mode is no safer than any other, and the keep/revert
          // window is the only wire-timing detector that exists.
          Button(DisplayModeCopy.recommendationApply) {
            resolutionSelection.select(size: row, in: catalog)
          }
            .buttonStyle(SettingsPrimaryButtonStyle())
            .accessibilityLabel(DisplayModeCopy.recommendationApply)
          Button(DisplayModeCopy.recommendationDismiss) {
            writer.write(.sizeRecommendationDismissed) { $0.sizeRecommendationDismissed = true }
          }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel(DisplayModeCopy.recommendationDismiss)
          .prefIdentifier(.sizeRecommendationDismissed, persistenceKey: persistenceKey)
          Spacer(minLength: 0)
        }
      }
    }
  }

  /// SS4's per-display opt-in. What a refusal says is NOT here: `BannerRegion`
  /// renders it above this page and every pushed page (SO7), because a
  /// synthesized size can be picked from All Sizes too, where a row in this
  /// section is unreachable.
  ///
  /// With the size controls rather than under Advanced, because it changes what
  /// the Size pop-up directly above offers. SS14 keeps the built-in out
  /// entirely; this page is the external hub, so the guard is a belt over a
  /// structural fact.
  @ViewBuilder private func moreSizesRows(
    _ catalog: DisplayModeCoordinator.Catalog
  ) -> some View {
    if !catalog.display.isBuiltIn {
      // Same reasoning as the callout above: the size rows are always drawn
      // before it, so this divider can never open the card.
      SettingsCardDivider()
      SettingRow(caption: SettingsCaption(verbatim: SynthesisCopy.optInCaption)) {
        Toggle(SynthesisCopy.optInTitle, isOn: Binding(
          get: { prefs.offerSyntheticSizes },
          set: { on in setMoreSizes(on, on: catalog.display) }
        ))
        .themedSwitch()
        // An engage or teardown is a multi-second hardware sequence, and a
        // second flip queued behind one answers a question nobody is asking any
        // more. Courtesy, not the guard: the engine is non-reentrant and the
        // coordinator answers `.busy` regardless.
        .disabled(synthesis.isWorking)
        .prefIdentifier(.offerSyntheticSizes, persistenceKey: persistenceKey)
      }
    }
  }

  /// SS11's ordering, which is why this is a method and not two lines in a
  /// binding: turning the opt-in OFF disengages and verifies BEFORE the pref is
  /// written, so a failed teardown leaves the display opted in with the
  /// synthesized rows still in the picker. Those rows are the only surface that
  /// can take an engaged size down, so writing the pref first would hide the
  /// recovery behind the state it recovers from. The coordinator owns the write
  /// and its D27 announcement; a second write path here would be a second
  /// ordering to get wrong.
  private func setMoreSizes(_ enabled: Bool, on display: ConfiguredDisplay) {
    Task { await synthesis.setOptIn(enabled, on: display) }
  }

  // MARK: - Sound

  @ViewBuilder private var soundCard: some View {
    // `defaultOutputDevice()` does a blocking HAL round-trip when the CoreAudio
    // listener has not primed its cache: read it once, not once per consumer.
    let currentOutput = model.audioDevices.defaultOutputDevice()

    SettingsCardSection(title: "Sound") {
      LabeledContent("Volume keys") {
        HStack(spacing: 8) {
          Text(verbatim: volumeKeysStatus)
            .foregroundStyle(SettingsTheme.bodyColor)
          // The commonest task has to be findable from the display's page: the
          // keys are configured app-wide under Keyboard.
          Button("Keyboard Settings…") { selection = .pane(.keyboard) }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .accessibilityLabel("Keyboard Settings…")
        }
      }

      SettingsCardDivider()

      // A safety row (a11y contract 3): what "On" costs is D29's mute strand,
      // so the sentence goes into the toggle's label rather than a hint a
      // VoiceOver user may have switched off. The pref is a request the display
      // or the "Always disabled" override can demote to the volume-register
      // mute, and the caption is nil wherever the engine does what the row says.
      SettingRow(
        safety: .hardwareMute(
          isAvailable: state.volume.isAvailable,
          dedicatedCommandInReach: model.dedicatedMuteCommandInReach(state)),
        label: "Mute with the display's own mute command",
        caption: model.degradedMuteReason(state).map { SettingsCaption(verbatim: $0) }
      ) { label in
        Toggle(label, isOn: Binding(
          get: { prefs.enableMuteUnmute },
          set: { enabled in
            // D22/D29 rule 1, with NO engine backstop: unmute BEFORE the pref
            // flips. Once `enableMuteUnmute` is false nothing ever sends 0x8D=2
            // again, so persisting first strands the display hardware-muted with
            // only a CLI to recover it.
            if !enabled, state.volume.isMuted {
              _ = state.volume.toggleMute()
            }
            writer.write(.enableMuteUnmute) { $0.enableMuteUnmute = enabled }
          }
        ))
        // Disable, don't hide: the control does not apply while the volume
        // command is off, and saying so beats a missing row. Disabling it does
        // NOT make the D22 hazard unreachable; the stranded-mute recovery in
        // `BannerRegion` works regardless of `isAvailable` (D29 rule 3) and
        // cannot be scrolled out of existence by the state it recovers from.
        .themedSwitch()
        .disabled(!state.volume.isAvailable)
        .prefIdentifier(.enableMuteUnmute, persistenceKey: persistenceKey)
      }

      SettingsCardDivider()

      SettingRow("\(AppInfo.productName) asks the display, and the volume and mute keys follow the same answer; the slider is greyed only when it says no.") {
        ThemedChoiceRow(label: "Volume slider", selection: Binding(
          get: { prefs.audioSinkOverride },
          set: { override in
            // D29 rule 1. "Always disabled" takes the MUTE key away as well as
            // the slider, because both consult this verdict, so persisting it
            // while the display is hardware-muted would leave the strand behind
            // a control that no longer answers. Unmute BEFORE the pref flips.
            if override == .forceNone, state.volume.isMuted {
              _ = state.volume.toggleMute()
            }
            writer.write(.audioSinkOverride) { $0.audioSinkOverride = override }
          }
        )) {
          Text("Enable automatically").tag(AudioSinkOverride.auto)
          Text("Always enabled").tag(AudioSinkOverride.forcePresent)
          Text("Always disabled").tag(AudioSinkOverride.forceNone)
        }
        .prefIdentifier(.audioSinkOverride, persistenceKey: persistenceKey)
      }

      SettingsCardDivider()

      SettingRow("Used when the volume keys pick a display by audio output. Empty matches the display's name.") {
        LabeledContent("Audio device name") {
          HStack(spacing: 8) {
            TextField("", text: $audioNameDraft, prompt: Text("Automatic"))
              .settingsEditableContent()
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
              .prefIdentifier(.audioDeviceNameOverride, persistenceKey: persistenceKey)
            Button("Use Current") {
              audioNameDraft = currentOutput?.name ?? ""
              commitAudioName()
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .accessibilityLabel("Use Current")
            .disabled(currentOutput == nil)
          }
        }
      }
    }
  }

  /// Mirrors what the key path consults, so this row cannot say "On" about keys
  /// that would move nothing. Two unavailability signals and either is enough:
  /// `volume.isAvailable` is the pref side, `volumeSliderEnabled` is D24's, the
  /// monitor's own denial. The Dell answers its capabilities with no VCP 0x62,
  /// and "On" there would contradict the greyed slider two sections up.
  private var volumeKeysStatus: String {
    if !state.volume.isAvailable || !model.volumeSliderEnabled(state) {
      return "Not available on this display"
    }
    if prefs.isDisabled { return "Off" }
    let mode = prefs.keyboardVolume
    let active = KeyModePolicy.watchesMediaKeys(mode) || KeyModePolicy.firesCustomShortcuts(mode)
    return active ? "On" : "Off"
  }


  // MARK: - OLED Care

  /// The SO2 split of the per-display care controls: the hub holds the decision
  /// you change (enrollment, OC2's explicit opt-in, reachable where the
  /// display's other everyday controls are) and the state you consult, as the
  /// row's value. Thresholds, levels, hours and the global chrome switches stay
  /// on the OLED Care pane, which OC3 keeps as their home.
  ///
  /// The route there is a sidebar-selection change, NOT a push from this
  /// destination's stack (SO1), so it wears the app's cross-pane LINK idiom
  /// rather than `NavigationRow`'s chevron: a chevron promises a push on the
  /// current destination. The link lands on this display's own OLED page.
  private var oledCareCard: some View {
    SettingsCardSection(title: "OLED Care") {
      SettingRow("Enrolling applies the recommended settings; nothing changes until this display has been idle for a while.") {
        Toggle("Enroll this display in OLED care", isOn: Binding(
          get: { prefs.oledCareEnrolled },
          set: { on in writer.write(.oledCareEnrolled) { $0.oledCareEnrolled = on } }
        ))
        .themedSwitch()
        .prefIdentifier(.oledCareEnrolled, persistenceKey: persistenceKey)
      }

      SettingsCardDivider()

      LabeledContent("Care status") {
        HStack(spacing: 8) {
          Text(verbatim: oledCarePreview)
            .foregroundStyle(SettingsTheme.bodyColor)
            .accessibilityLabel(Text(oledCareSpokenPreview))
          // Carries this display with the jump: a link from a display's own hub
          // landing on the OLED overview would make the reader click through to
          // where they already were. The path seed and the selection land in one
          // transaction; a plain sidebar visit still opens the overview.
          Button("All OLED Care Settings…") {
            oledCarePath.wrappedValue = [.display(persistenceKey)]
            selection = .pane(.oledCare)
          }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel("All OLED Care Settings…")
        }
      }
    }
  }

  /// SO3's value preview, from the coordinator's OWN published state, never a
  /// second opinion computed here. The exhaustive switch makes a new engine
  /// state a compile error rather than a stale preview.
  private var oledCarePreview: String {
    guard prefs.oledCareEnrolled else { return "Off" }
    if model.isSafeMode { return "Paused" }
    switch model.oledCare.dimStates[persistenceKey] {
    case .active: return "On"
    case .idleDim, .unfocusedDim: return "Dimmed"
    // OC7 sub-ruling 4: a refused lock dim is recorded and must not be reported
    // as dimmed. `lockDimSkips` is observed, so this re-reads when the refusal
    // appears or clears.
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
    // The pause is not always mirroring the user set up. `suspensionReason`
    // reads the same tick's verdict as `dimStates`, so the two cannot disagree;
    // the sighted preview says "Paused" and leaves the reason to the pane.
    case .suspended:
      return OledCareCopy.suspendedSpokenPreview(
        reason: model.oledCare.suspensionReason(for: persistenceKey))
    case nil: return "Starting"
    }
  }

  // MARK: - Navigation

  private var navigationCard: some View {
    SettingsCardSection {
      // The only hedge on the page, and it sits before the navigation rather
      // than on the sub-page, where it would arrive too late to save the trip.
      SettingRow("Settings most displays don't need.") {
        NavigationRow(title: "Advanced", value: advancedPreview) { path.append(.advanced) }
          .focused($focusedRow, equals: .advanced)
      }
      SettingsCardDivider()
      NavigationRow(title: "Diagnostics", value: readbackVerdict) { path.append(.diagnostics) }
        .focused($focusedRow, equals: .diagnostics)
    }
  }

  /// SO3: composed from live `DisplayPrefs` reads on every body evaluation, so
  /// the preview cannot outlive the values it describes. `hideOsd` is passed as
  /// its own fact and deliberately NOT counted into `overrideCount`: the policy
  /// folds it in itself, and counting it here would double it.
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

  /// The diagnostics page's worst-of-three readback verdict, in the same
  /// `DiagnosticsCopy` vocabulary the report uses, so the three surfaces cannot
  /// drift. One `allZeros` is never cancelled by a later `notAttempted`: a
  /// write-only display is a permanent property and the preview must not soften
  /// it.
  private var readbackVerdict: String {
    DiagnosticsCopy.readbackVerdict(DDCReadEvidence.worst([
      state.controller.readEvidence,
      state.volume.readEvidence,
      state.contrast.readEvidence,
    ]))
  }

  // MARK: - Reset

  private var resetCard: some View {
    SettingsCardSection {
      HStack {
        // The window's destructive style at rest, matching the app-wide reset in
        // General. What survives of SO20 is the part that was never about looks:
        // the destructive ROLE stays on the alert's confirm button rather than on
        // the button that opens the alert. Disabled only WHILE a reset runs,
        // never as a state the page can get stuck in; a `defer` on the reset's
        // own task releases the latch.
        Button("Reset Display Settings…") { confirmingReset = true }
          .buttonStyle(SettingsDangerButtonStyle())
          .accessibilityLabel("Reset Display Settings…")
          .accessibilityIdentifier("action.resetDisplay.\(persistenceKey)")
          .disabled(model.isResetting)
          .alert("Reset the settings for this display?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { resetDisplay() }
            Button("Cancel", role: .cancel) {}
          } message: {
            // Names the Advanced-page work explicitly (SO20), and names what is
            // NOT lost: the saved levels are the only source of truth on a
            // write-only panel, so a reset that took them would leave the display
            // at an unknown brightness. The pinned resolution and rotation are
            // macOS-visible state this button leaves alone, and counted hours are
            // wear data.
            Text("This unmutes \(state.display.name), turns HDR off while it runs, and clears its \(AppInfo.productName) settings: name, menu bar visibility, keyboard, sound, OLED care, \(SynthesisCopy.optInTitle), and everything under Advanced, including control-code remaps and response curves. A size \(AppInfo.productName) was rendering for this display is taken down first, so the display goes back to one of its own; if that does not finish, the page says so and the rest of the reset still runs. HDR that was turned on in System Settings goes back on at the end. If the display cannot be reached at the time, nothing is sent to it that cannot be confirmed, so some of these may be left for you to change yourself. Saved brightness, volume and contrast levels are kept, and so are its counted hours of use. The remembered resolution and rotation are not changed.")
          }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 4)
    }
  }

  /// Per-display reset. ORDER IS THE WHOLE POINT (D29 rule 2). An earlier
  /// version attempted `toggleMute()` FIRST, then cleared `forceSoftware` and
  /// the per-command `unavailableDDC`, then set `enableMuteUnmute = false`. On a
  /// display that arrived already in the D29 state (muted with hardware control
  /// off) the unmute hit `toggleMute`'s `isAvailable` guard and returned
  /// silently, and the reset then retired the only mute strategy that could ever
  /// send 0x8D=2 again: the button whose alert promises to fix a bad state left
  /// the monitor permanently silent while the app believed it was unmuted.
  ///
  /// So: availability prefs FIRST, unmute SECOND (while the display's current
  /// mute strategy is still in force), retire the strategy LAST.
  private func resetDisplay() {
    // One reset at a time, app-wide. Two overlapping would drive this display
    // from two tasks, and a per-display reset finishing inside Reset All's
    // rebuild would hand HDR back through a controller that has already been
    // replaced, over a register the live controller believes is free.
    guard model.beginReset() else { return }
    let key = state.display.persistenceKey
    // OLED care's lock dim drives this display's brightness on its own timer,
    // and the reset accounts for every write it makes before letting HDR back
    // on. Held off for the duration, this display only.
    model.oledCare.beginDisplayReset(key)
    Task { @MainActor in
      defer {
        model.oledCare.displayResetDidComplete(key)
        model.endReset()
      }
      // 0. SS11 for the reset path: the synthesized size comes DOWN, verified,
      //    and only then are its two prefs cleared. The coordinator owns both
      //    halves and their order, so nothing here writes either key.
      //
      //    First, before HDR and the pref batch: a teardown re-lays-out the whole
      //    arrangement, so everything after it runs against a display showing its
      //    own desktop, which is what step 1 and the dimming fan-out are about.
      //
      //    A failure REPORTS and does not stop the reset: the rest of this
      //    button's promise is not worth withholding over a virtual display that
      //    would not come down.
      if let configured = coordinator.configurator.displays().first(where: { $0.id == displayID }) {
        await synthesis.reset(configured)
      }

      // 1. D22: HDR goes through the controller's state machine (settle window,
      //    poller gating, rollback), never `prefs.hdrMode`. First, so the DDC
      //    register is unlocked for everything below.
      //
      //    The RESET door, not `setHDRMode(.off)`: that one decides from the
      //    stored mode and the cached mirror, and the mirror lags a System
      //    Settings toggle until the reconfigure lands. In that window it reports
      //    no HDR, the request evaporates, and everything below, the D29 unmute
      //    included, runs against a register the monitor still has locked. This
      //    door measures the panel instead, clears the stored mode either way,
      //    and reports whether HDR was engaged elsewhere so step 5 can put it
      //    back.
      //
      //    The answer is evidence, not a request: `.disengaged` comes off a
      //    measured read taken after the drop settled, which is what licenses the
      //    hardware writes below. `.unknown` withholds that licence.
      //
      //    It also drops the duplicate memos on this display's wire, which the
      //    unmute depends on: a write ACKed while the display was in HDR was
      //    swallowed by the panel, so a memo built through that window would let
      //    the unmute be skipped as a duplicate of a value the register never
      //    took, and reported as applied.
      let hdrState = await state.controller.disengageHDRForReset()

      // 2. Hardware too, and it runs before the evidence is acted on below:
      //    several of these keys fan out to `reapplyAfterPrefChange`, which
      //    re-runs the dimming legs synchronously. The engine keeps that honest
      //    under `.unknown`: a superseded exit leaves the mirror saying HDR is
      //    LIVE, so the path resolves native and this step writes neither DDC nor
      //    a gamma table onto a display that may be in HDR. If that rule ever
      //    changes, this step has to move below the switch.
      //
      //    Every pref except the mute strategy, in ONE batch whose fan-out is the
      //    UNION of its rows. Never collapse it onto a single
      //    `prefDidChange(.forceSw)`: `hideDisplay` carries `.updateStatusItem`
      //    and `forceSw` does not, so with `menuIcon == .sliderOnly` a reset that
      //    un-hid the display would leave the status item missing. Clearing
      //    `forceSoftware` and every command's `unavailableDDC` here is what
      //    makes step 3 able to work at all (D29 rule 2). Deliberately outside:
      //    the mute strategy (step 4, ordering), the remembered display mode, and
      //    the size-recommendation dismissal, which only Reset All brings back.
      writer.writeAll([
        .friendlyName, .hideDisplay, .isDisabled, .hideOsd, .forceSw, .avoidGamma,
        .audioDeviceNameOverride, .audioSinkOverride, .hideVolumeSlider,
        .combinedSwitchingPoint, .pollingMode, .pollingCount,
        .unavailableDDC, .minDDCOverride, .maxDDCOverride, .curveDDC, .invertDDC, .remapDDC,
        // OLED care's keys, all carrying `.reapplyOledCare`: un-enrolling takes
        // this display's care overlay down, and the fan-out makes that happen now
        // rather than on the next topology event. Safe by construction, since a
        // reset can only remove an overlay.
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
        // `longerDelay` is reserved and inert, and NOT a `PrefName` case:
        // cleared for tidiness only, and correctly absent from the fan-out above.
        prefs.longerDelay = false
        // ONE shared definition of "untouched", from CandelaKit, pinned by
        // `theFactoryTuningIsWhatAnUntouchedDisplayReports`.
        for command in DDCCommand.allCases {
          prefs.setTuning(.unset, for: command)
        }
        // REMOVES the OLED keys rather than writing today's numbers back: the
        // accessors' defaults ARE the Recommended preset, so a reset that wrote
        // them would pin this display to the preset as it stands today. Panel
        // hours are not prefs and are deliberately kept, like the saved levels.
        prefs.resetOledCare()
      }

      // 3 and 4 are hardware, so they are gated on step 1's evidence. Under
      // `.unknown` the display may still be in HDR, where DDC goes nowhere and a
      // write-only panel cannot report it: the unmute would clear the stored mute
      // flag over a register that stayed muted, and retiring the strategy would
      // remove the only command that could ever undo it. That is the strand D29
      // rule 1 forbids, so BOTH steps stand down together and the display keeps
      // its working strategy and its honest muted flag.
      switch hdrState {
      case .disengaged:
        // 3. `isAvailable` is true again, and `enableMuteUnmute` still holds the
        //    value the display was muted under, so this sends the RIGHT wire
        //    value (0x8D=2 in the dedicated-command strategy, a volume write
        //    otherwise). `toggleMute` also clears the persisted `muted` flag,
        //    which is why it is not written by hand.
        var unmuteLanded = true
        if state.volume.isMuted {
          _ = state.volume.toggleMute()
          // The same patience the restore uses: an immediate retry is
          // definitionally inside the same reconfiguration window that skipped
          // the first attempt, and the disengage above IS a reconfiguration.
          unmuteLanded = await WireQuiescence.settle(
            [state.volume], isWireOpen: { state.volume.isWireOpen }
          )
        }
        // 4. Only now retire the strategy, and only if the unmute is known to
        //    have reached the panel. Retiring it after an unmute nobody can
        //    confirm removes the one command that undoes 0x8D = 2, which is D29
        //    rule 1 read backwards. Its row is UI-only, so this second fan-out
        //    costs a re-render and nothing else.
        if unmuteLanded {
          writer.write(.enableMuteUnmute) { $0.enableMuteUnmute = false }
        } else {
          resetLog.error(
            "reset on display \(state.display.persistenceKey, privacy: .public): the unmute could not be confirmed as applied, so its mute state and strategy were both left in place"
          )
          // `toggleMute` cleared the stored flag on the way out and the panel
          // may still be muted, so put it back, both halves together. A live
          // controller believing an unmuted display makes the next press of the
          // ordinary mute control MUTE one that never stopped being muted, and
          // hides that from every surface until something rebuilds it.
          state.volume.reassertUnconfirmedMute()
        }
      case .unknown:
        resetLog.error(
          "reset on display \(state.display.persistenceKey, privacy: .public): HDR state unknown after the disengage, so the unmute and the mute-strategy change were both skipped; the display keeps its current mute state and strategy"
        )
      }

      // 5. LAST, and only for HDR this reset borrowed rather than owned. The
      //    restore is the door that settles the wire: every write above is QUEUED
      //    rather than sent, and re-engaging locks the register the moment one
      //    lands. It settles all three queues, brightness included, because step
      //    2's fan-out re-applies brightness on the same wire, and it refuses to
      //    re-engage if it cannot confirm they landed.
      if case .disengaged(restoreAfterward: true) = hdrState {
        await state.controller.restoreExternalHDR()
      }

      nameDraft = ""
      audioNameDraft = ""
    }
  }

  // MARK: - Draft commits

  private func commitName() {
    // One shared rule, in CandelaKit under test: blank under ANY whitespace
    // means "use the name the display reports".
    let trimmed = DisplayCardPolicy.normalizedFriendlyName(nameDraft)
    nameDraft = trimmed
    guard trimmed != prefs.friendlyName else { return }
    writer.write(.friendlyName) { $0.friendlyName = trimmed }
  }

  /// Exactly what select-all-and-delete then Return does, through the same
  /// commit. Clearing the DRAFT first is the load-bearing half: the re-seed hook
  /// is gated on focus and this button does not take focus off the field, so a
  /// draft still holding the old name would be written straight back on the next
  /// focus move.
  private func clearName() {
    nameDraft = ""
    commitName()
    // Activating this button destroys it, taking any focus standing on it under
    // Full Keyboard Access or VoiceOver. Focus goes to the field it serves, and
    // the announcement carries the result: the field now reads empty, and a
    // placeholder is not something VoiceOver reports (a11y contract 8).
    nameFocused = true
    AccessibilityNotification.Announcement(
      "Name cleared. Using the name the display reports."
    ).post()
  }

  private func commitAudioName() {
    let trimmed = DisplayCardPolicy.normalizedFriendlyName(audioNameDraft)
    audioNameDraft = trimmed
    guard trimmed != prefs.audioDeviceNameOverride else { return }
    // Fans out to a tap re-arm: `audioDeviceNameOverride` feeds
    // `AppModel.tapConfig` through `audioMatchingDisplays` (D20/D2).
    writer.write(.audioDeviceNameOverride) { $0.audioDeviceNameOverride = trimmed }
  }
}
