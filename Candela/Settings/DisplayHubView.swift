import CandelaKit
import CoreGraphics
import os
import SwiftUI

/// The reset path's own category: a reset that stands hardware steps down says
/// so somewhere a person can find later, and it is not a keyboard or a path
/// event.
private let resetLog = Logger(subsystem: "com.rydersel.Candela", category: "reset")

/// The external display hub (spec §4): everything you change or consult about
/// one display, on one page, with Advanced / Diagnostics / the full mode list
/// pushed as sub-pages (SO1/SO2). Owns the whole page, hero included;
/// `DisplayDetailView` stays as the navigation shell's thin destination host.
///
/// Row order is the spec's: identity, Display, Sound, navigation, reset. The
/// identity block is drawn as three cards (the name, "In the Menu Bar",
/// "Keyboard") rather than one headerless section, which changes where the
/// hairlines fall and not what follows what.
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
  /// with it, and driven by the `onChange` on the page root below.
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
  /// would write (and fan out, and bump `prefsRevision`) on every keystroke,
  /// re-rendering the pane mid-edit. Committed on Return and on focus loss;
  /// on teardown the `@State` dies with the destination and no commit is
  /// scheduled (SO10 — the same shape the pre-hub page shipped with).
  ///
  /// Seeded at identity creation (the stack's `.id(key)` gives each display its
  /// own hub identity) and re-seeded on `prefsRevision` from `onChange`
  /// modifiers ON THE FIELDS themselves. That placement was forced by the
  /// grouped `Form` this page used to be (a lifecycle hook on a `Section` was
  /// not reliably applied) and is kept because it is also the right one: the
  /// hook lives on the thing it re-seeds, so a re-seed cannot silently stop
  /// firing and revive a wiped name on the next focus loss.
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
  /// The shared apply path, with SO6's answering surface sampled from THIS
  /// window's key state at the moment the row is built. The size pop-up builds
  /// its own; this one is the recommendation callout's, which applies the very
  /// same row through the very same countdown (PD9).
  private var resolutionSelection: ResolutionSelection {
    ResolutionSelection(
      coordinator: coordinator,
      displayID: displayID,
      surface: controlActiveState == .key ? .settingsBanner : .floatingPanel
    )
  }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults and not observable, so this is what
    // re-evaluates the hub after a write anywhere else — and what makes the
    // chevron previews re-read (SO3).
    let _ = model.prefsRevision
    // The hub owns the whole page and every card sits directly in the
    // scaffold's builder. The grouped `Form` this replaced could not host its
    // sections from a child view at all (measured 2026-08-06: the scrollable
    // extent came up ~110 pt short and the reset section was unreachable);
    // the card stack has no such constraint, but the composition stays here
    // because the page is one reading order, not seven fragments.
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
    // rather than per body evaluation, and it hangs off the page root rather
    // than off a card. Any LATER resolution change (ours, System Settings', or
    // a replug) re-enumerates through the coordinator's own screen-parameters
    // observer, which must run whether or not this page is on screen.
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

  /// The name and what it is shared with. Headerless: the hero above it is the
  /// display, and a kicker naming the display again would be the third time on
  /// one screen.
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
          // Only while there is a name to clear: the escape route from a custom
          // name is otherwise select-all-and-delete, which nothing on the page
          // suggests. A sibling of the field rather than a branch around it, so
          // the TextField keeps its position in the HStack's tuple: a bare `if`
          // is `buildOptional`, and the optional it produces is the button's
          // own slot, not a swap of the pair. The field is never rebuilt
          // underneath a live edit.
          if hasCustomName {
            Button(action: clearName) {
              Image(systemName: "xmark.circle.fill")
                // The glyph alone is a ~13 pt target hard against the row's
                // trailing edge. Padding widens the hit area without growing
                // the symbol; `contentShape` is what makes the padding
                // clickable rather than merely empty.
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
        // back when it goes, and both edges land while the caret may be in the
        // field. Declarative rather than a `withAnimation` at the call site
        // because the flip has four routes in (commit on Return, commit on
        // focus loss, this button, the per-display reset) plus any external
        // write, and only a predicate on the value itself covers them all.
        // Keyed to `hasCustomName`, so typing animates nothing.
        .animation(Motion.disclosure(reduceMotion: reduceMotion), value: hasCustomName)
      }
      if model.isSharedIdentity(persistenceKey) {
        // SO21: same persistence key, same prefs, so every control on this page
        // drives both units, and the user deserves to know before renaming one.
        SettingsRowNote(verbatim: "Two identical displays are attached. They share these settings.")
      }
    }
  }

  /// The two menu-bar questions, under the mock's own kicker for them (SV14).
  /// The rows keep the order they had as one identity section: nothing moved,
  /// the section boundaries did.
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

      // Kept adjacent to the row above: same question (spec §4). Whether a
      // slider that IS shown accepts input is the Sound section's picker.
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
  /// setting: the same split, and the same kicker, the built-in display's page
  /// already draws.
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

  /// Keyed to the STORED name, never to the draft. Two reasons: a name only
  /// half typed is not one this display is wearing anywhere else, and a
  /// predicate on the draft would add and remove a control on the first and
  /// last keystroke of every edit. The field still resizes ONCE at each commit
  /// boundary, caret possibly in it, which is what the animation above softens;
  /// what this avoids is a resize per keystroke, not every resize.
  /// `normalizedFriendlyName` is the same rule the title fallback uses, so a
  /// name that is whitespace shows the hardware name AND offers nothing to
  /// clear.
  private var hasCustomName: Bool {
    !DisplayCardPolicy.normalizedFriendlyName(prefs.friendlyName).isEmpty
  }

  // MARK: - Display

  /// One card, in the order the section always had. The dividers between the
  /// blocks are decided HERE rather than inside the shared child views: only
  /// this composition knows which neighbour renders, and a divider a child
  /// drew for itself would open the card whenever the block above it was
  /// absent.
  private var displayCard: some View {
    SettingsCardSection(title: "Display") {
      // A nil catalog is "not enumerated yet", NOT "no modes": rendering the
      // empty state for it flashes false copy on every pane switch.
      if let catalog {
        // The size pop-up, the refresh picker and the empty states are shared
        // with the built-in display's page, which offers the same choice over
        // the same engine. What stays here is what only an external gets: the
        // density model's callout, and SS14's synthesis opt-in.
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
  /// picker is only a mark (PD8).
  ///
  /// Five conditions, and each removes the row for a different reason: no
  /// recommendation (the model abstained, or no geometry ever reached it), the
  /// user closed it, the user has already applied a size on this display this
  /// session, the named size has no curated row to apply (the wire-timing
  /// guard can withhold one), or the display is already running that size. The
  /// last is why applying writes no dismissal: the size becomes current, so the
  /// row goes on its own, and a dismissal written here would also hide the row
  /// for a LATER recommendation on this display.
  ///
  /// A person who just chose a size has answered the question for this session;
  /// the durable opt-out is the dismissal.
  ///
  /// Matched through `isRecommendedSize`, the same predicate the picker's mark
  /// uses, so the row this applies and the row that wears the mark cannot drift.
  /// The copy variant comes off that same curated row, because a recommended
  /// size can be the panel's own native one (the MAG running 1920 × 1080 is
  /// offered 3440 × 1440), and the callout must not claim a scaling that is not
  /// happening. It asks the mode's NATIVE flag rather than the row's
  /// `isScaled`, which is framebuffer equality: an exact-2x HiDPI mode on a 5K
  /// or 6K panel renders into the native framebuffer at half the logical size,
  /// so `isScaled` calls it unscaled and the native sentence would be false
  /// there. Anything the flag leaves out gets the scaled sentence, the milder
  /// claim.
  @ViewBuilder private func recommendationCallout(
    _ catalog: DisplayModeCoordinator.Catalog
  ) -> some View {
    if let recommendation = catalog.density?.recommendation,
       !prefs.sizeRecommendationDismissed,
       !coordinator.sizeAppliedByUser.contains(displayID),
       let row = catalog.rows.first(where: { catalog.isRecommendedSize($0.mode) }),
       !catalog.isCurrentSize(row.mode) {
      // Never the card's first row: the size rows above it always render when
      // there is a catalog, and there is one here.
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

  /// SS4's per-display opt-in.
  ///
  /// What a refusal says is NOT here: `BannerRegion` renders it, above this
  /// page and above every pushed page (SO7), because a synthesized size can be
  /// picked from All Sizes as well as from this pop-up, and a row in this
  /// section is unreachable from there.
  ///
  /// It sits with the size controls rather than under Advanced because it
  /// changes what the Size pop-up directly above it offers, and a switch whose
  /// only visible effect is somewhere else is a switch nobody connects to its
  /// effect.
  ///
  /// SS14: the built-in is never a synthesis target. This page is the external
  /// hub, so the guard is a belt over a structural fact rather than the only
  /// thing keeping the row away from a laptop panel.
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
        // An engage or a teardown is a multi-second hardware sequence, and a
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
  /// recovery behind the state it recovers from.
  ///
  /// The coordinator owns the write and its D27 announcement
  /// (`didWriteSynthesisPref`), so nothing here touches `DisplayPrefs` or names
  /// a `PrefName`: a second write path would be a second ordering to get wrong.
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
          // The #1 ordinary-user task must be findable from the display's page
          // (spec §4): the keys are configured app-wide under Keyboard.
          Button("Keyboard Settings…") { selection = .pane(.keyboard) }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .accessibilityLabel("Keyboard Settings…")
        }
      }

      SettingsCardDivider()

      // A safety row (accessibility contract 3): what "On" costs is D29's mute
      // strand, so the sentence goes into the toggle's label rather than into a
      // hint a VoiceOver user may have switched off.
      // The row draws the pref, and the pref is a request the display or the
      // "Always disabled" override can demote to the volume-register mute.
      // Nil in every cell where the engine is doing what the row says, so an On
      // row with no status is a promise the engine keeps.
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
        // in `BannerRegion` works regardless of `isAvailable` (D29 rule 3),
        // rendered above this page and every sub-page, so it cannot be
        // scrolled out of existence by the state it recovers from.
        .themedSwitch()
        .disabled(!state.volume.isAvailable)
        .prefIdentifier(.enableMuteUnmute, persistenceKey: persistenceKey)
      }

      SettingsCardDivider()

      SettingRow("\(AppInfo.productName) asks the display, and the volume and mute keys follow the same answer; the slider is greyed only when it says no.") {
        ThemedChoiceRow(label: "Volume slider", selection: Binding(
          get: { prefs.audioSinkOverride },
          set: { override in
            // D29 rule 1. "Always disabled" now takes the MUTE key away as well
            // as the slider, because both consult this same verdict, so
            // persisting it while the display is hardware-muted would leave the
            // strand behind a control that no longer answers. Unmute BEFORE the
            // pref flips, the same shape the mute and hardware-control toggles
            // use. The banner below still catches the state; this keeps it from
            // being reachable through an ordinary picker choice.
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


  // MARK: - OLED Care

  /// The SO2 split of W3a's per-display care controls, sitting between Sound
  /// and the navigation section: the hub holds the decision you change
  /// (enrollment — OC2's explicit opt-in, so it must be reachable where the
  /// display's other everyday controls are) and the state you consult (what
  /// the care engine is doing right now, as the chevron's value). The
  /// thresholds, levels, hours and the global chrome switches are set-once and
  /// stay on the OLED Care pane, which OC3 keeps as their dedicated home.
  ///
  /// The route to the rest is a sidebar-selection change, NOT a push from
  /// THIS destination's stack: SO1 closes the display destination's pushed
  /// set at three sub-pages, and OLED Care is a top-level destination whose
  /// own pushed pages (OCR1) hang off the pane. It therefore wears the app's
  /// cross-pane LINK idiom (the Sound section's Keyboard Settings link),
  /// never `NavigationRow`'s chevron: a chevron promises a push on the
  /// current destination, and this jump changes destinations (combined pass
  /// D7). The link lands on this display's own OLED page, with Back leading
  /// to the OLED overview. SO3's live preview stays, as the row's value text
  /// beside the link.
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
          // Carries this display with the jump: a link from a display's own
          // hub that lands on the OLED overview would make the reader click
          // through to where they already were. Seeding the path and moving
          // the selection land in one transaction, so the pane comes up with
          // this display's page presented; a plain sidebar visit still opens
          // the overview because nothing else writes the path.
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
    // The pause is not always mirroring the user set up. `suspensionReason`
    // reads the same tick's verdict as `dimStates`, so the two cannot disagree
    // about the reason; the sighted preview says "Paused" and leaves the reason
    // to the pane, which is why only this one has to tell them apart.
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

  private var resetCard: some View {
    SettingsCardSection {
      HStack {
        // The window's destructive style is mandatory for a destructive action,
        // so this button wears red at rest: tinted fill, tinted stroke, medium
        // weight. SO20 said plain at rest, and that clause is presentation,
        // which this redesign supersedes; what survives of it is the part that
        // was never about looks, the destructive ROLE staying on the alert's
        // confirm button rather than on the button that only opens the alert.
        // The app-wide reset in General reads the same, so one act does not
        // wear two looks.
        // Disabled only WHILE a reset runs (a second or two), never as a state
        // the page can get stuck in: the latch is released by a `defer` on the
        // reset's own task.
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
            // write-only panel, so a reset that took them would leave the
            // display at an unknown brightness, and the pinned resolution and
            // rotation are macOS-visible state this button deliberately leaves
            // alone. Counted panel hours are wear data, kept for the same
            // reason the levels are.
            Text("This unmutes \(state.display.name), turns HDR off while it runs, and clears its \(AppInfo.productName) settings: name, menu bar visibility, keyboard, sound, OLED care, \(SynthesisCopy.optInTitle), and everything under Advanced, including control-code remaps and response curves. A size \(AppInfo.productName) was rendering for this display is taken down first, so the display goes back to one of its own; if that does not finish, the page says so and the rest of the reset still runs. HDR that was turned on in System Settings goes back on at the end. If the display cannot be reached at the time, nothing is sent to it that cannot be confirmed, so some of these may be left for you to change yourself. Saved brightness, volume and contrast levels are kept, and so are its counted hours of use. The remembered resolution and rotation are not changed.")
          }
        Spacer(minLength: 0)
      }
      .padding(.vertical, 4)
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
    // One reset at a time, app-wide. Two of them overlapping would drive this
    // display from two tasks, and a per-display reset finishing inside Reset
    // All's rebuild would hand HDR back through a controller that has already
    // been replaced: a write nobody is looking at, over a register the live
    // controller still believes is free.
    guard model.beginReset() else { return }
    let key = state.display.persistenceKey
    // OLED care's lock dim drives this display's brightness on its own timer,
    // and the reset accounts for every write it makes before letting HDR back
    // on. Held off for the duration, for this display only.
    model.oledCare.beginDisplayReset(key)
    Task { @MainActor in
      defer {
        model.oledCare.displayResetDidComplete(key)
        model.endReset()
      }
      // 0. SS11 for the reset path: the synthesized size comes DOWN, verified,
      //    and only then are its two prefs cleared. The coordinator owns both
      //    halves and their order; nothing here writes either key, and neither
      //    appears in the batch below.
      //
      //    First, before HDR and before the pref batch, for two reasons. A
      //    teardown re-lays-out the whole arrangement, so everything after it
      //    runs against a display showing its own desktop rather than a virtual
      //    master's; and the display's own mode is what step 1's HDR work and
      //    the dimming fan-out below are about.
      //
      //    A failure REPORTS and does not stop the reset: the refusal row above
      //    says what is still standing, and the rest of this button's promise
      //    (the mute strand, the prefs, HDR) is not worth withholding over a
      //    virtual display that would not come down.
      if let configured = coordinator.configurator.displays().first(where: { $0.id == displayID }) {
        await synthesis.reset(configured)
      }

      // 1. D22: HDR goes through the controller's state machine (settle window,
      //    poller gating, rollback), never through `prefs.hdrMode`. Done first
      //    so the DDC register is unlocked for everything below.
      //
      //    The RESET door, not `setHDRMode(.off)`. That one decides from the
      //    stored mode and the cached mirror, and the mirror lags a System
      //    Settings toggle until the reconfigure lands: in that window it
      //    reports no HDR, the request evaporates, and everything below,
      //    including the D29 unmute, runs against a register the monitor still
      //    has locked. This door measures the panel instead, clears the stored
      //    mode either way, and answers the second question with it: HDR that
      //    was live with no Candela mode recording it was engaged elsewhere,
      //    and step 5 puts it back. Live HDR under `.alwaysOn` is a Candela
      //    setting, and clearing it is what this button is for.
      //
      //    The answer is evidence and not a request: `.disengaged` comes off a
      //    measured read taken after the drop settled, so it is what licenses
      //    the hardware writes below. `.unknown` withholds that licence.
      //
      //    It also drops the duplicate memos of every queue on this display's
      //    wire, which the unmute below depends on: a write ACKed while the
      //    display was in HDR was swallowed by the panel, so a memo built
      //    through that window would let the unmute be skipped as a duplicate of
      //    a value the register never took, and reported as applied. The
      //    controller holds its own wire, so this reset cannot name the wrong
      //    queues or forget one.
      let hdrState = await state.controller.disengageHDRForReset()

      // 2. This step is hardware too, and it runs before the evidence is acted
      //    on below: several of these keys fan out to `reapplyAfterPrefChange`,
      //    which re-runs the dimming legs synchronously. What keeps that honest
      //    under `.unknown` is in the engine: a superseded exit leaves the
      //    mirror saying HDR is LIVE rather than leaving its optimistic "not in
      //    HDR" standing, so the path resolves native and this step writes
      //    neither DDC nor a gamma table onto a display that may be in HDR.
      //    What it can cost is a brightness write that goes nowhere on a
      //    DDC-only panel, and only a reconfiguration or an HDR transition puts
      //    that right: the next brightness change routes native again, for the
      //    same stale reason. If that rule ever changes, this step has to move
      //    below the switch.
      //
      //    Every pref except the mute strategy, in ONE batch whose fan-out is
      //    the UNION of its rows. Never collapse it onto a single
      //    `prefDidChange(.forceSw)`: `hideDisplay` carries `.updateStatusItem`
      //    and `forceSw` does not, so with `menuIcon == .sliderOnly` a reset
      //    that un-hid the display would leave the status item missing.
      //    Clearing `forceSoftware` and every command's `unavailableDDC` here
      //    is also what makes step 3 able to work at all (D29 rule 2).
      //    NOT everything keyed to this display: the mute strategy is step 4
      //    (ordering), and the remembered display mode is deliberately outside
      //    — a resolution the user is currently looking at is not a setting
      //    this button promises to change. The size-recommendation dismissal is
      //    deliberately outside too: only Reset All Settings brings that
      //    suggestion back, and this alert never promises to.
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

      // 3 and 4 are hardware, so they are gated on step 1's evidence. Under
      // `.unknown` the display may still be in HDR, where DDC goes nowhere and
      // a write-only panel cannot report it: the unmute would clear the stored
      // mute flag over a register that stayed muted, and retiring the strategy
      // would then remove the only command that could ever undo it. That is
      // precisely the strand D29 rule 1 forbids, so BOTH steps stand down
      // together and the display keeps its working mute strategy and its honest
      // muted flag, which is the state the recovery banner reads.
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
          // The same patience the restore uses, and for the same reason: one
          // immediate retry is definitionally inside the same reconfiguration
          // window that skipped the first attempt, and the disengage above IS a
          // reconfiguration. Settling waits for the gate rather than guessing.
          unmuteLanded = await WireQuiescence.settle(
            [state.volume], isWireOpen: { state.volume.isWireOpen }
          )
        }
        // 4. Only now retire the strategy, and only if the unmute is known to
        //    have reached the panel. Retiring it after an unmute nobody can
        //    confirm removes the one command that undoes 0x8D = 2, which is
        //    D29 rule 1 read backwards: the display keeps a working strategy
        //    and the ordinary mute control can re-drive it. Its row is UI-only,
        //    so this second fan-out costs a re-render and nothing else.
        if unmuteLanded {
          writer.write(.enableMuteUnmute) { $0.enableMuteUnmute = false }
        } else {
          resetLog.error(
            "reset on display \(state.display.persistenceKey, privacy: .public): the unmute could not be confirmed as applied, so its mute state and strategy were both left in place"
          )
          // `toggleMute` cleared the stored flag on the way out, and the panel
          // may still be muted, so put it back: the same two facts Reset All
          // keeps across its wipe, kept here for the same reason. Both halves
          // move together rather than the pref alone. A live controller left
          // believing an unmuted display makes the next press of the ordinary
          // mute control MUTE one that never stopped being muted, and it hides
          // the state from every surface that reads the controller until
          // something rebuilds it.
          state.volume.reassertUnconfirmedMute()
        }
      case .unknown:
        resetLog.error(
          "reset on display \(state.display.persistenceKey, privacy: .public): HDR state unknown after the disengage, so the unmute and the mute-strategy change were both skipped; the display keeps its current mute state and strategy"
        )
      }

      // 5. LAST, and only for HDR this reset borrowed rather than owned. The
      //    restore is the door that settles the wire: every write above is
      //    QUEUED rather than sent, and re-engaging locks the register the
      //    moment one lands. It settles all three queues, the brightness one
      //    included, because the pref fan-out in step 2 re-applies brightness on
      //    the same wire, and it refuses to re-engage at all if it cannot
      //    confirm they landed.
      if case .disengaged(restoreAfterward: true) = hdrState {
        await state.controller.restoreExternalHDR()
      }

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

  /// Exactly what select-all-and-delete followed by Return does, and through
  /// the same commit: one write route to this pref, one normalization, one
  /// dirty check. Clearing the DRAFT first is the load-bearing half. The
  /// re-seed hook is gated on focus, and a click on this button does not take
  /// focus off the field, so a draft left holding the old name would be written
  /// straight back the next time focus moved on.
  private func clearName() {
    nameDraft = ""
    commitName()
    // Activating this button destroys it: the condition that shows it is now
    // false, so the button is gone by the next render and takes any focus
    // standing on it with it, under Full Keyboard Access or VoiceOver. Focus
    // goes to the field the button serves rather than nowhere, which is also
    // where a person would want to be next, and the announcement carries the
    // result: the field now looks empty
    // to VoiceOver, and the hardware name arriving as a placeholder is not
    // something it reports (accessibility contract 8's pattern, announcement
    // plus deliberate focus placement).
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
    // `AppModel.tapConfig` through `audioMatchingDisplays` (D20/D2 bug 3).
    writer.write(.audioDeviceNameOverride) { $0.audioDeviceNameOverride = trimmed }
  }
}
