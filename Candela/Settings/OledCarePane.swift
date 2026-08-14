import CandelaKit
import CoreGraphics
import SwiftUI

/// The display a jump into this pane came from, carried as a persistence key
/// and consumed ONCE: the hub's "All OLED Care Settings…" link sets it, this
/// pane scrolls to that display's section on appear and clears it there, so an
/// ordinary sidebar visit still opens at the top.
///
/// A `Binding` rather than a value so the consumer can do the clearing. The
/// value lives as `@State` on `SettingsRootView`, which is where the selection
/// it travels with lives; the default is `.constant(nil)`, whose setter is a
/// no-op, so any view rendered outside that injection simply never scrolls.
private struct OledCareScrollTargetKey: EnvironmentKey {
  static let defaultValue: Binding<String?> = .constant(nil)
}

extension EnvironmentValues {
  var oledCareScrollTarget: Binding<String?> {
    get { self[OledCareScrollTargetKey.self] }
    set { self[OledCareScrollTargetKey.self] = newValue }
  }
}

/// OLED care: the two global screen-chrome switches, then one section per
/// connected external display (spec §5).
///
/// Copy rule for every sentence in this file (OC11): software has exactly two
/// levers against burn-in — *reduce luminance* and *reduce time at luminance*.
/// Nothing here may claim more than that, and the chrome trade-off is stated
/// rather than sold.
///
/// `@MainActor` is load-bearing for the same reason as `DisplayDetailView`: a
/// `View`'s stored and computed properties are nonisolated under complete
/// concurrency checking, and this one reads `AppModel` and the coordinator from
/// outside `body`.
@MainActor
struct OledCarePane: View {
  @Environment(AppModel.self) private var model

  /// `pmset -g` costs a 79 ms process spawn [MEASURED 2026-08-06]. Read ONCE
  /// per pane appearance into state, never from `body` (which re-evaluates on
  /// every pref write and on every dim-state change) and never from the poll
  /// below — its own 60 s cache is a backstop against a re-render loop, not a
  /// licence to call it on a timer.
  @State private var displaySleepMinutes: Int?

  /// The last chrome value we asked for and did not get, per control. Held
  /// because `ChromeAutoHideController` records what the SYSTEM reports rather
  /// than what was requested, so a write that does not land is honest — the
  /// switch snaps back — but silent, and a switch that flicks back with no
  /// explanation reads as a bug in the app rather than as a refusal by the
  /// system. Cleared as soon as the value the user asked for is observed.
  @State private var menuBarRefused: Bool?
  @State private var dockRefused: Bool?

  /// Set by the hub's link, cleared by this pane the first time it appears.
  @Environment(\.oledCareScrollTarget) private var scrollTarget

  var body: some View {
    ScrollViewReader { proxy in
      pane(proxy: proxy)
    }
  }

  /// The pane's own content. Split out of `body` only because the whole thing
  /// now hangs off a `ScrollViewReader`'s proxy; the sections still sit
  /// directly in this `Form`'s builder, which a grouped `Form` needs.
  private func pane(proxy: ScrollViewProxy) -> some View {
    // Prefs are plain `UserDefaults` and not observable, so this is the only
    // thing that re-reads them after a write from anywhere — including the
    // per-display sections below, which write through `DisplayPrefWriter`.
    let _ = model.prefsRevision
    return Form {
      // The pane's opening image, the display hero's precedent at pane scale:
      // each ENROLLED display's shape and history before any control. Clicking
      // a tile jumps to that display's section through the same anchor the hub
      // link uses. Enrolled only, so the strip is what this pane manages
      // rather than a row of placeholders.
      let enrolledDisplays = model.displays.filter {
        DisplayPrefs(persistenceKey: $0.display.persistenceKey).oledCareEnrolled
      }
      if !enrolledDisplays.isEmpty {
        Section {
          OledCareGlanceStrip(displays: enrolledDisplays) { key in
            withAnimation { proxy.scrollTo(key, anchor: .top) }
          }
        }
      }

      Section {
        // One row, not two: a `SettingsCaption` placed as its own `Form` row
        // gets a divider above it, so two paragraphs of the same introduction
        // read as two settings.
        VStack(alignment: .leading, spacing: 6) {
          // Two sentences, not three (SO15/SO16): "enrolling applies the
          // recommended settings" already lives on every enrollment toggle's
          // own caption, where the control is.
          SettingsCaption("Software can do two things about OLED wear: show fewer bright pixels, and show them for less time. \(AppInfo.productName) dims an enrolled display that has been idle, and can turn on macOS's own auto-hiding for the menu bar and the Dock.")
          SettingsCaption("OLED care applies to external displays.")
        }
        if model.isSafeMode {
          safeModeNote
        }
      }

      chromeSection

      // Identified by `persistenceKey`, NOT by `DisplayState.id` (which is the
      // `CGDirectDisplayID`). IDs reassign across a replug with both displays
      // still attached — measured, the MAG went 3→2 and the Dell 2→3 across one
      // dock cycle — and `ForEach` keyed on a reused id hands the OLD view
      // instance, with its `@State`, to the OTHER panel: an in-progress slider
      // drag would then write its draft level to the wrong display's prefs.
      // The `id:` here is also the scroll anchor `scrollToTarget` aims at.
      // A `ForEach`'s element identity is what `ScrollViewProxy.scrollTo`
      // resolves against, inside a grouped `Form` as well [MEASURED
      // 2026-08-07: an explicit `.id()` on a row of the section was tried
      // first and is not needed], so the anchor and the identity cannot drift
      // apart.
      ForEach(model.displays, id: \.display.persistenceKey) { state in
        OledCareDisplaySection(state: state, displaySleepMinutes: displaySleepMinutes)
      }
      if model.displays.isEmpty {
        Section {
          SettingsCaption("Connect an external display to enroll it in OLED care.")
        } header: {
          Text("Displays").settingsHeading()
        }
      }
    }
    .formStyle(.grouped)
    // One `.task` covers both appearance jobs and the poll, and it is cancelled
    // when this pane goes away — which is the whole requirement for the poll:
    // the Dock has no change notification, so the only way to reflect an
    // external `com.apple.dock autohide` change is to re-read, and a re-read
    // running while the pane is hidden would be a permanent timer for a window
    // nobody is looking at. (The same poll covers the menu bar, so it needs no
    // screen-parameters observer of its own.)
    .task {
      await scrollToTarget(proxy)
      displaySleepMinutes = OledCareSignalSources.displaySleepMinutes()
      while !Task.isCancelled {
        // Resolved inside the loop, never captured before it: the coordinator
        // builds `chrome` during launch wiring, and a `guard else { return }`
        // here would give up permanently if this pane happened to appear
        // first — leaving the switches frozen at whatever they read once.
        if let chrome = model.oledCare.chrome {
          chrome.refresh()
          reconcileChromeRefusals(chrome)
        }
        try? await Task.sleep(for: .seconds(2))
        // `Task.sleep` returns immediately once cancelled, so the loop must
        // re-check rather than trusting the `while` to catch it in time.
        if Task.isCancelled { break }
      }
    }
  }

  /// D11's rule, applied here: say exactly what Safe Mode suppresses, where it
  /// changes what a control means. `OledCareCoordinator.start` returns at its
  /// safe-mode guard BEFORE the driver loop is built, so the dimming loop, the
  /// hours counter, the brightness sampler and the window observer are all
  /// inert; the two chrome switches are explicit writes to system settings and
  /// still work, so this must not claim the pane is inert either. D11 is a rule
  /// against overstating scope, and understating it misleads the same way: a
  /// note that named only dimming and hours left the two measurement toggles
  /// looking live in a session that measures nothing.
  private var safeModeNote: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        // Symbol AND text — never state by colour alone.
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
        Text("Safe Mode is on for this session, so no display is being dimmed, no hours of use are being counted, and no measurements are being taken.")
      }
      SettingsCaption("Shift was held at launch. The two Screen Chrome settings below still work, and the settings you make here are saved for the next normal launch.")
    }
  }

  // MARK: - Screen chrome (global)

  /// Global, and first: these two are system-wide settings rather than
  /// per-display ones, and they are the strongest lever in the pane — hiding
  /// the menu bar and the Dock stops driving those pixels rather than merely
  /// dimming them.
  @ViewBuilder private var chromeSection: some View {
    Section {
      if let chrome = model.oledCare.chrome {
        // The refusal note lives INSIDE the switch's own row, like the
        // displaysleep warning below: a note in a `Form` row of its own gets a
        // divider and full padding, which reads as a separate setting rather
        // than as this switch failing.
        // One sentence (SO15): consequence plus its trade-off, and the
        // mechanism ("most static bright areas") stays because it IS the
        // consequence — hiding stops those pixels being driven (OC11).
        SettingRow(caption: SettingsCaption("The menu bar and the Dock are the most static bright areas on a Mac screen, and hiding them stops those pixels being driven (at the cost of the clock, status items and menus taking a trip to the screen's edge).")) {
          VStack(alignment: .leading, spacing: 6) {
            Toggle("Automatically hide the menu bar", isOn: Binding(
              get: { chrome.menuBarAutoHide },
              set: { on in
                chrome.setMenuBarAutoHide(on)
                menuBarRefused = chrome.menuBarAutoHide == on ? nil : on
              }
            ))
            if menuBarRefused != nil {
              OledInlineNote(Text("macOS did not take that change. Menu bar auto-hiding can also be set in System Settings > Control Center."))
            }
          }
        }

        SettingRow(caption: SettingsCaption("Changing this restarts the Dock, which takes a moment and is visible.")) {
          VStack(alignment: .leading, spacing: 6) {
            Toggle("Automatically hide the Dock", isOn: Binding(
              get: { chrome.dockAutoHide },
              set: { on in
                chrome.setDockAutoHide(on)
                dockRefused = chrome.dockAutoHide == on ? nil : on
              }
            ))
            if dockRefused != nil {
              OledInlineNote(Text("macOS did not take that change. Dock auto-hiding can also be set in System Settings > Desktop & Dock."))
            }
          }
        }
      } else {
        SettingsCaption("These settings are not available yet. Reopen this window in a moment.")
      }
    } header: {
      Text("Screen Chrome").settingsHeading()
    } footer: {
      // The section's footer, NOT a `Form` row of its own, which is what this
      // was: a row gets a divider above it and full padding, so a sentence
      // about BOTH switches read as a third setting. It cannot ride either
      // switch's `SettingRow` either, because a `SettingRow` caption is
      // republished as that ONE control's accessibility hint, and this sentence
      // is about the pair.
      //
      // Suppressed while the controls are missing: a note about what "both
      // settings" are is noise under a section that is currently showing
      // neither.
      if model.oledCare.chrome != nil {
        SettingsCaption("Both settings belong to macOS rather than to \(AppInfo.productName): they apply to every display, and enrolling a display never changes them on its own.")
      }
    }
  }

  /// Consumes the jump's scroll target: land on the section for the display
  /// the user came from, once, then forget it so the next sidebar visit opens
  /// at the top.
  private func scrollToTarget(_ proxy: ScrollViewProxy) async {
    guard let key = scrollTarget.wrappedValue else { return }
    // A display named by a jump but absent from this pane (unplugged between
    // the click and the appear) consumes the target and leaves the page at the
    // top: no error, and nothing left over for the next visit to inherit.
    guard model.displays.contains(where: { $0.display.persistenceKey == key }) else {
      scrollTarget.wrappedValue = nil
      return
    }
    // The delay is load-bearing, not defensive [MEASURED 2026-08-07]: a
    // `scrollTo` issued on the first tick of this `.task` is accepted and does
    // nothing, and the pane stays at the top. The grouped `Form` has not
    // finished sizing its rows by then.
    try? await Task.sleep(for: .milliseconds(100))
    guard !Task.isCancelled else { return }
    // No animation: this is where the page opens, not a move the user made.
    proxy.scrollTo(key, anchor: .top)
    // Cleared only once a scroll has actually gone out, never before the
    // sleep. This task is cancelled and restarted during launch (measured), so
    // clearing up front spent the target on the run that never reached the
    // scroll and the surviving run found nothing to do.
    scrollTarget.wrappedValue = nil
  }

  /// Clears a recorded refusal once the system reports the value that was
  /// asked for — a change made in System Settings, or a Dock restart that
  /// finished after the setter read back. Without this the note would outlive
  /// the condition it describes for as long as the pane stays open.
  private func reconcileChromeRefusals(_ chrome: ChromeAutoHideController) {
    if let requested = menuBarRefused, chrome.menuBarAutoHide == requested {
      menuBarRefused = nil
    }
    if let requested = dockRefused, chrome.dockAutoHide == requested {
      dockRefused = nil
    }
  }
}

// MARK: - Inline note

/// A note about the control directly ABOVE it, drawn inside that control's own
/// `Form` row. Never its own row: a `Form` puts a divider and full padding
/// around every row, so a note about a control reads as a separate setting —
/// the defect `SettingRow` exists to prevent.
///
/// Symbol AND text, like the General pane's Safe Mode note — never state by
/// colour alone. Stronger than a caption on purpose: every use says the
/// control above it did not do, or is not doing, what it says.
private struct OledInlineNote: View {
  private let text: Text

  init(_ text: Text) { self.text = text }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.secondary)
      text
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - One display

/// One connected display's OLED care: the enrollment switch, and — only once
/// enrolled — the full controls outright. No "Advanced" disclosure (OC3): a
/// full window has room to simply show them, which is the settings-redesign
/// ruling and D29 rule 3's shape as well.
///
/// A separate `View` rather than a builder on the pane so each display owns its
/// own slider-drag state. A `@State` keyed by display inside one big view is the
/// shape that shows one display's in-progress drag on another display's row.
@MainActor
private struct OledCareDisplaySection: View {
  let state: AppModel.DisplayState
  /// Read once by the pane (79 ms), passed down; nil = `pmset` had no answer.
  let displaySleepMinutes: Int?

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  /// Slider drafts, live only while a drag is in progress. A `Slider` bound
  /// straight to a pref writes — and fans out, and bumps `prefsRevision` — on
  /// every pixel of the drag, re-rendering the pane under the user's pointer.
  /// Nil means "read the pref", so an external write shows up immediately.
  @State private var idleLevelDraft: Double?
  @State private var unfocusedLevelDraft: Double?
  /// `PanelHoursTracker` is a plain class with no observation, so nothing
  /// re-renders this section when the hours line changes. Bumped by the one
  /// action that changes it from here (Dismiss); the numbers otherwise refresh
  /// whenever anything else re-renders the pane.
  @State private var hoursRevision = 0
  /// The panel health view is presented FROM this section, never embedded in it
  /// (OC19): it is a page of its own, and a 24×10 heat map inside a `Form` row
  /// would read as one more setting.
  @State private var showingHealth = false

  private var persistenceKey: String { state.display.persistenceKey }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }

  /// The same resolution the panel, the sidebar and the HUD use, so a rename
  /// moves all of them together.
  private var name: String {
    DisplayOrdering.title(friendlyName: prefs.friendlyName, hardwareName: state.display.name)
  }

  var body: some View {
    let _ = model.prefsRevision
    let _ = hoursRevision
    Section {
      // One sentence (SO15) — "off by default" is the toggle's own visible
      // state, and the same caption rides the hub's enrollment toggle so the
      // two surfaces cannot describe enrollment differently.
      SettingRow("Enrolling applies the recommended settings; nothing changes until this display has been idle for a while.") {
        // OC11: software cannot protect a display from burn-in — it can reduce
        // luminance and time at luminance, and that limit is the point of the
        // rule. "Enroll" is also the word the intro and the empty state
        // already use, so the pane's primary control now contains the verb its
        // own copy is written around.
        Toggle("Enroll this display in OLED care", isOn: Binding(
          get: { prefs.oledCareEnrolled },
          set: { on in writer.write(.oledCareEnrolled) { $0.oledCareEnrolled = on } }
        ))
      }

      if prefs.oledCareEnrolled {
        hero
        idleControls
        lockControls
        blackoutControls
        unfocusedControls
        hoursControls
        measurementControls
        comparisonControls
        healthRow
      }
    } header: {
      Text(verbatim: name).settingsHeading()
    }
    .sheet(isPresented: $showingHealth) {
      PanelHealthView(
        displayName: name,
        persistenceKey: persistenceKey,
        displayID: state.display.id)
    }
    // Screenshot validation has no other route into a sheet: Accessibility is
    // not granted, so nothing can click the row that opens it, and the app has
    // no URL scheme (that is W4). Same permanent, compiled-out-by-construction
    // shape as `DebugSettingsHook` and the coordinators' preview observers:
    // the `#if` wraps the MODIFIER, so Release keeps no residue.
    //
    //   CANDELA_DEBUG_PANEL_HEALTH=first            first external display
    //   CANDELA_DEBUG_PANEL_HEALTH=<persistenceKey> that display
    //
    // Only ever opens for an ENROLLED display, because the row it stands in for
    // only exists there.
    #if DEBUG
      .onAppear {
        guard prefs.oledCareEnrolled,
          let want = ProcessInfo.processInfo.environment["CANDELA_DEBUG_PANEL_HEALTH"]
        else { return }
        let first = model.displays.first?.display.persistenceKey
        if want == persistenceKey || (want == "first" && first == persistenceKey) {
          showingHealth = true
        }
      }
    #endif
  }

  // MARK: - Hero

  /// The section's opening image: the display's accumulated history as a
  /// picture, beside the facts the section used to open with as plain rows
  /// (status, hours) and the health view's headline finding. Every fact the
  /// map draws is stated in words in the stat column, the display hero's rule,
  /// so the map stays decorative to VoiceOver and the honesty precedence is
  /// the health view's exactly: Safe Mode, then the grant, then confidence.
  @ViewBuilder private var hero: some View {
    let summary = model.oledCare.healthSummary(for: persistenceKey)
    let tracker = model.oledCare.hoursTracker(for: persistenceKey)
    let blank = summary.confidence != .measured
    let aspect =
      OledPanelGeometry.panelNativeAspect(for: state.display.id)
      ?? CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows)
    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        // The smooth glance surface, not the health sheet's discrete grid:
        // at this size inset cells read as floating squares. Blank state is a
        // plain shape, not a faint pattern that reads as data.
        if blank {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(.quaternary)
            .overlay {
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
            }
            .aspectRatio(aspect, contentMode: .fit)
            .accessibilityHidden(true)
        } else {
          PanelExposureSurface(
            cells: summary.cells,
            highlighted: OledPanelGeometry.hottestIndex(summary.cells),
            aspect: aspect)
        }
        if blank {
          Text(verbatim: mapPlaceholder(summary))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          PanelExposureLegend()
        }
      }
      .frame(maxWidth: 300)

      VStack(alignment: .leading, spacing: 10) {
        heroStat("Status") { Text(statusText) }
        heroStat("Hours of use") { Text(verbatim: hoursLine(tracker)) }
        if !blank, let relative = summary.hottestRelative,
          let multiple = PanelHealthCopy.multiple(relative)
        {
          heroStat("Hottest area") {
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: "\(multiple) this display's average")
              if let sentence = hottestSentence(summary) {
                Text(verbatim: sentence)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
        heroStat("Measurement") { Text(verbatim: measurementStateLine(summary)) }
        if let stats = model.oledCare.modelComparison(for: persistenceKey).statistics() {
          heroStat("Estimate agreement") {
            Text(verbatim: String(format: "%.2f", stats.pearson))
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
  }

  private func heroStat(_ label: String, @ViewBuilder value: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(verbatim: label)
        .font(.caption)
        .foregroundStyle(.secondary)
      value()
    }
  }

  /// Caption under a blank hero map. `summary.cells` stays populated whatever
  /// the confidence, so blanking the drawing must not also claim there is no
  /// history behind it (the health view's own rule).
  private func mapPlaceholder(_ summary: PanelHealthSummary) -> String {
    if model.isSafeMode {
      return "Paused for this session (Safe Mode). History recorded before it is kept."
    }
    if summary.confidence != .estimated, !CGPreflightScreenCaptureAccess() {
      return "Waiting on Screen Recording; no readings are being taken."
    }
    return summary.confidence == .estimated
      ? "Not shown while measuring is off. The history recorded so far is kept."
      : "Nothing measured to draw yet. Readings are taken once a minute while this display is awake and in use."
  }

  private func measurementStateLine(_ summary: PanelHealthSummary) -> String {
    if model.isSafeMode { return "Paused for this session (Safe Mode)" }
    if summary.confidence != .estimated, !CGPreflightScreenCaptureAccess() {
      return "Waiting on Screen Recording"
    }
    switch summary.confidence {
    case .measured: return "Measuring, one reading a minute"
    case .insufficient: return "Measuring, not enough readings yet"
    case .estimated: return "Off"
    }
  }

  /// Words for what the outline draws. Past tense for the owner, the health
  /// view's reason: the snapshot behind it is up to a minute old.
  private func hottestSentence(_ summary: PanelHealthSummary) -> String? {
    guard let index = OledPanelGeometry.hottestIndex(summary.cells),
      let region = PanelHealthCopy.region(cell: index)
    else { return nil }
    guard let owner = summary.hottestOwner else { return "Outlined on the map, \(region)." }
    return "Outlined on the map, \(region). \(owner) was there at the last reading."
  }

  /// What the engine is doing right now. `dimStates` is the coordinator's own
  /// published state, never a second opinion computed here; a mirrored
  /// display's "paused" reading is the one spec §5 requires to be visible
  /// (OC13).
  private var statusText: LocalizedStringKey {
    if model.isSafeMode { return "Paused for this session (Safe Mode)" }
    // Exhaustive, so a new engine state is a compile error here rather than a
    // blank row.
    switch model.oledCare.dimStates[persistenceKey] {
    case .active: return "Not dimming"
    case .idleDim: return "Dimmed: the display has been idle"
    case .blackout: return "Screen off: the display has been idle"
    // OC7 sub-ruling 4: a lock dim the policy refused is RECORDED and must
    // never be reported as dimmed. `lockDimSkips` carries only live refusals
    // (the coordinator clears the entry the moment the dim engages), so
    // reading it here cannot outlive the state it describes.
    case .lockDim: return OledCareCopy.lockDimStatus(model.oledCare.lockDimSkips[persistenceKey])
    case .unfocusedDim: return "Dimmed: no window in focus on this display"
    case .suspended: return "Paused while this display is mirrored"
    // Between enrolling and the first tick, and for a display the coordinator
    // has not reconciled yet. Says what is true rather than guessing.
    case nil: return "Starting"
    }
  }

  // MARK: - Idle dim

  @ViewBuilder private var idleControls: some View {
    SettingRow(caption: SettingsCaption("Counted from the last keyboard or mouse activity anywhere on the Mac; video playback, calls and anything else holding the screen awake postpone it.")) {
      VStack(alignment: .leading, spacing: 6) {
        Stepper(value: idleMinutesBinding, in: Self.idleMinuteRange) {
          Text(verbatim: "Dim after \(Self.minutesPhrase(minutes(prefs.oledIdleDimSeconds))) of inactivity")
        }
        // In the SAME row as the control it is about: a divider between a
        // threshold and the sentence saying that threshold does nothing turns
        // the warning into what looks like an unrelated setting.
        displaySleepWarning(forThresholdSeconds: prefs.oledIdleDimSeconds)
      }
    }

    levelRow(
      label: "Dim to",
      caption: "How bright the display is while dimmed: \(AppInfo.productName) draws a dark overlay over it, the display's own brightness setting is untouched, and any key or click restores the picture immediately.",
      draft: $idleLevelDraft,
      value: prefs.oledIdleDimBrightness,
      accessibilityName: "Idle dim brightness"
    ) { brightness in
      writer.write(.oledIdleDimLevel) { $0.oledIdleDimBrightness = brightness }
    }
  }

  // MARK: - Lock dim

  private var lockControls: some View {
    SettingRow("Dims the display to the same brightness as the idle dim; any key or click lifts it while the screen stays locked, and it comes back after the idle time above.") {
      Toggle("Dim while the screen is locked", isOn: Binding(
        get: { prefs.oledLockDim },
        set: { on in writer.write(.oledLockDim) { $0.oledLockDim = on } }
      ))
    }
  }

  // MARK: - Blackout

  @ViewBuilder private var blackoutControls: some View {
    // TWO sentences by design: SO15's safety budget names the blank display,
    // and OC15's honesty rule needs the second sentence — a key wakes the
    // blackout but is NOT discarded, and copy must never promise it is.
    SettingRow("Goes fully black after a longer idle period; the click that wakes it is discarded, so nothing is clicked by accident. A key press wakes it too, but reaches whichever app you were using.") {
      Toggle("Turn the screen black after longer", isOn: Binding(
        get: { prefs.oledBlackoutEnabled },
        set: { on in writer.write(.oledBlackoutEnabled) { $0.oledBlackoutEnabled = on } }
      ))
    }
    if prefs.oledBlackoutEnabled {
      // The lower bound is the engine's own floor, not a number chosen here:
      // `OledDimConfig` clamps the blackout threshold to at least idle + the
      // gap, so a control that could express anything lower would be a control
      // that lies about what it did.
      VStack(alignment: .leading, spacing: 6) {
        // The label reads the BINDING, not the raw pref: the binding is the
        // clamped value, and a label showing a lower number than the stepper
        // holds would be the silent-rewrite this clamp exists to make visible.
        Stepper(value: blackoutMinutesBinding, in: blackoutMinuteRange) {
          Text(verbatim: "Go black after \(Self.minutesPhrase(blackoutMinutesBinding.wrappedValue)) of inactivity")
        }
        displaySleepWarning(forThresholdSeconds: prefs.oledBlackoutSeconds)
      }
    }
  }

  // MARK: - Unfocused dim

  @ViewBuilder private var unfocusedControls: some View {
    SettingRow("Dims while no window on this display is in focus, even while you are working on another display: only clicking into this display brings it back, not typing elsewhere.") {
      Toggle("Dim while this display has nothing in focus", isOn: Binding(
        get: { prefs.oledUnfocusedDimEnabled },
        set: { on in writer.write(.oledUnfocusedDimEnabled) { $0.oledUnfocusedDimEnabled = on } }
      ))
    }
    if prefs.oledUnfocusedDimEnabled {
      Stepper(value: unfocusedMinutesBinding, in: Self.unfocusedMinuteRange) {
        Text(verbatim: "Dim after \(Self.minutesPhrase(minutes(prefs.oledUnfocusedDimSeconds))) without focus")
      }
      levelRow(
        label: "Dim to",
        caption: "How bright an unfocused display is while dimmed. Usually higher than the idle dim, because the display is still in view.",
        draft: $unfocusedLevelDraft,
        value: prefs.oledUnfocusedDimBrightness,
        accessibilityName: "Unfocused dim brightness"
      ) { brightness in
        writer.write(.oledUnfocusedDimLevel) { $0.oledUnfocusedDimBrightness = brightness }
      }
    }
  }

  // MARK: - Panel hours

  @ViewBuilder private var hoursControls: some View {
    // ONE tracker per display, from the coordinator. Never construct one here:
    // a second live instance reads a stale count and clobbers the real one on
    // its next write-through.
    let tracker = model.oledCare.hoursTracker(for: persistenceKey)

    // "Hours of use", never "panel hours", in every visible string (SO14: the
    // hardware is a display; "panel" survives only in type names like
    // `PanelHoursTracker` and in comments).
    //
    // The second sentence is the honest limit of the number (#94): macOS reports
    // a DPMS-blanked panel as awake, at full resolution, with no reconfiguration,
    // so a panel held in soft standby is indistinguishable from a lit one.
    // "can still be counted" is deliberately hedged. Whether the monitor's own
    // power button reaches soft standby or instead deasserts hot-plug detect
    // (a real departure, handled correctly) is untested per monitor (#23).
    // Display sleep, system sleep and mirroring are all handled correctly, so
    // don't let the caption imply otherwise in either direction.
    SettingRow("Counted while the display is awake and not mirrored, and kept per display even when it is unplugged. A display switched off at the monitor itself can still be counted, because macOS reports a blanked display as awake.") {
      Toggle("Count hours of use", isOn: Binding(
        get: { prefs.oledHoursTracking },
        set: { on in writer.write(.oledHoursTracking) { $0.oledHoursTracking = on } }
      ))
    }

    // The figures themselves live in the hero above, always on screen, so a
    // dismissed standby note is never the only place the since-standby number
    // can be read.
    if tracker.shouldShowStandbyNote {
      SettingRow(caption: SettingsCaption("Most OLED displays run their own compensation cycle when they go into standby, and skip it while they are in use. Anything that puts the display to sleep counts: the monitor's own power button, or leaving the Mac idle.")) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("This display has not been in standby for a while.")
          Spacer(minLength: 0)
          Button("Dismiss") {
            tracker.dismissStandbyNote()
            hoursRevision &+= 1
          }
          .accessibilityLabel("Dismiss")
        }
      }
    }

  }

  // MARK: - Measurement

  /// The two data sources behind the panel health view, in the order they cost
  /// the user something: the one that needs a system permission first, then the
  /// one that needs none.
  @ViewBuilder private var measurementControls: some View {
    // Spec §4's prompt copy, used verbatim as the toggle's own explanation so
    // the reason is on screen BEFORE macOS's own dialog, which says "record
    // the contents of your screen" and can say nothing else. The only
    // substitution is the product name, which every other caption in this file
    // interpolates for the same reason (the working name is not final).
    SettingRow(caption: SettingsCaption("\(AppInfo.productName) measures how bright each part of the display is, at about the resolution of this grid, once a minute. Nothing is recorded or stored as an image, and nothing leaves this Mac.")) {
      VStack(alignment: .leading, spacing: 8) {
        Toggle("Measure how bright each part of this display is", isOn: Binding(
          get: { prefs.oledTelemetry },
          set: { on in
            // The ONE place in the app that raises the Screen Recording
            // prompt. The sampler itself is preflight-only on purpose: a
            // background loop that raises a TCC dialog on its own schedule is
            // a permission request with no explanation attached to it.
            //
            // The pref is written whether or not the grant arrives. macOS
            // returns false from the request that merely SHOWS the dialog, so
            // gating the switch on the return value would leave it stuck off
            // on the first click; instead the switch records the decision and
            // the note below says the grant has not landed.
            if on { _ = CGRequestScreenCaptureAccess() }
            writer.write(.oledTelemetry) { $0.oledTelemetry = on }
          }
        ))
        // What "the resolution of this grid" means, at the size it means it.
        PanelGridMark()
        // The ONE control in this pane that gets its own safe-mode note, and
        // only because it is the one that spends something: the setter above
        // raises the Screen Recording dialog unconditionally, so without this
        // a safe-mode session grants a system permission to a sampler that
        // cannot run until the next normal launch, with every visible signal
        // (switch on, no not-granted note) saying it worked. Every other
        // control here is covered by the status row and the pane-level note.
        //
        // Safe Mode WINS over the grant note rather than joining it: both are
        // true at once, but two notes giving two reasons for one silence read
        // as a bug, and the grant is the reason that cannot be acted on
        // usefully this session.
        if model.isSafeMode {
          OledInlineNote(Text("Safe Mode is on for this session, so nothing is being measured whatever this is set to, and Screen Recording is not needed until the next normal launch."))
        } else if prefs.oledTelemetry, !CGPreflightScreenCaptureAccess() {
          OledInlineNote(Text("macOS has not granted Screen Recording, so no readings are being taken. Grant it in System Settings > Privacy & Security > Screen Recording."))
        }
      }
    }

    // The battery clause is stated ONCE, on the last row of the measurement
    // group, because `OledCareCoordinator.samplingQualifies` gates BOTH toggles
    // on the same signal: below the threshold both counters freeze, and nothing
    // on any surface said so. The number mirrors
    // `OledCareSignalSources.lowBatteryPercent` (20, at or below, and only on
    // battery power); a vaguer "on low battery" would not tell anyone whether
    // what they are seeing is the gate or a broken counter.
    SettingRow("Needs no permission: reads each on-screen window's position and the name of the app that owns it, never window titles and never their contents. This is what puts an app's name next to an area of the display. Both measurements pause while the Mac is running on battery at 20% charge or less.") {
      Toggle("Note which apps are on this display", isOn: Binding(
        get: { prefs.oledWindowObservation },
        set: { on in writer.write(.oledWindowObservation) { $0.oledWindowObservation = on } }
      ))
    }

    // #20. Last in the group and off by default, and the copy leads with what
    // it does to the screen rather than with what it protects.
    //
    // Every other control in this pane acts while the user is away or the
    // screen is locked. This one changes what they are looking at, so a wrong
    // nomination is visible as a defect rather than felt as protection, and the
    // honest framing is the one that lets someone decline. It also depends on
    // BOTH measurements above, one for luminance and one for staticness, so the
    // caption says so instead of leaving the switch to do nothing silently.
    //
    // The caption promises exactly what the code delivers: "full-screen video
    // is never dimmed" is the `fullScreenOwner` gate, which is read from the
    // window list and is exact. It does NOT promise that a WINDOWED video is
    // safe, because it is not: bounds stability is not content staticness, so a
    // player holding a fixed rect passes both halves of the conjunction. An
    // earlier version of this comment claimed the conjunction excluded a
    // playing video, contradicting `WindowObserver`'s own doc, which is right.
    // NOT claimed here: "eases off where you are pointing". The spec's §4 wants
    // pointer-proximity falloff and it is NOT built: the pointer is not an
    // input to `StaticRegionDetector`, which is pure, and nothing in the
    // coordinator supplies it either. Writing it into the caption would be the
    // fifth instance this wave of copy outrunning its producer (A-16, A-17,
    // OC17's gate, the stale `hottestOwner`). It goes back in when it exists.
    SettingRow("Areas that stay bright and unchanged, like a toolbar or a sidebar, are dimmed a little while you work. Full-screen video is never dimmed. This needs both measurements above: without them nothing is dimmed.") {
      Toggle("Dim parts of the display that never change", isOn: Binding(
        get: { prefs.oledDetectionDimming },
        set: { on in writer.write(.oledDetectionDimming) { $0.oledDetectionDimming = on } }
      ))
    }
  }

  // MARK: - Model comparison

  /// EM9's gate instrument: scores the estimated exposure model against the
  /// measured readings, on the page and revertable, never inside the health
  /// view it might one day change. Shown once measurement is on or a stored
  /// comparison exists, so a user who turns measurement off keeps their score.
  @ViewBuilder private var comparisonControls: some View {
    let comparison = model.oledCare.modelComparison(for: persistenceKey)
    if prefs.oledTelemetry || comparison.pairCount > 0 {
      SettingRow(caption: SettingsCaption("Scores an estimate built only from window positions, the wallpaper, and light or dark appearance against the measured readings above. If the two keep agreeing, the estimate can stand in when Screen Recording is off. Estimated figures are never presented as measured.")) {
        VStack(alignment: .leading, spacing: 6) {
          LabeledContent("Paired readings") {
            Text(verbatim: pairedReadingsLine(comparison))
              .foregroundStyle(.secondary)
          }
          if let last = comparison.lastPair {
            LabeledContent("Last pair") {
              Text(verbatim: Self.relativePhrase(last))
                .foregroundStyle(.secondary)
            }
          }
          if let stats = comparison.statistics() {
            LabeledContent("Correlation") {
              Text(verbatim: String(format: "%.2f", stats.pearson))
                .foregroundStyle(.secondary)
            }
            LabeledContent("Rank agreement") {
              Text(verbatim: String(format: "%.2f", stats.spearmanRank))
                .foregroundStyle(.secondary)
            }
            LabeledContent("Hottest regions in common") {
              Text(verbatim: Self.overlapPhrase(stats.hottestDecileOverlap))
                .foregroundStyle(.secondary)
            }
            if let measured = PanelHealthCopy.multiple(stats.measuredHottestMultiple),
              let modelled = PanelHealthCopy.multiple(stats.modelledHottestMultiple)
            {
              LabeledContent("Hottest region") {
                Text(verbatim: "measured \(measured), estimated \(modelled)")
                  .foregroundStyle(.secondary)
              }
            }
          } else if comparison.pairCount > 0 {
            OledInlineNote(Text("Still accumulating. Scores appear after 30 paired readings."))
          }
          if isComparisonStalled(comparison) {
            OledInlineNote(Text("No paired reading in over 10 minutes while measurement is on. If this persists, macOS may have dropped the Screen Recording grant after an update to the app; check System Settings > Privacy & Security > Screen Recording."))
          }
        }
      }
    }
  }

  private func pairedReadingsLine(_ comparison: ModelComparison) -> String {
    guard comparison.pairCount > 0 else { return "None yet" }
    // A single pair has no span worth naming; "spanning 0 minutes" reads as a
    // broken counter.
    guard comparison.pairCount > 1, let first = comparison.firstPair,
      let last = comparison.lastPair
    else { return "\(comparison.pairCount)" }
    return "\(comparison.pairCount), spanning \(Self.spanPhrase(last.timeIntervalSince(first)))"
  }

  /// Stalled means the pipeline should be producing pairs and is not: the
  /// pref is on, the grant preflights true, the session is not Safe Mode, and
  /// the last pair is well past the sampling interval. A missing grant is NOT
  /// stalled here; the measurement rows above already carry that note.
  private func isComparisonStalled(_ comparison: ModelComparison) -> Bool {
    guard prefs.oledTelemetry, !model.isSafeMode, CGPreflightScreenCaptureAccess(),
      let last = comparison.lastPair
    else { return false }
    return Date().timeIntervalSince(last) > 600
  }

  private static func spanPhrase(_ interval: TimeInterval) -> String {
    let minutes = Int((interval / 60).rounded())
    if minutes < 120 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
    let hours = interval / 3600
    if hours < 48 {
      let whole = Int(hours.rounded())
      return whole == 1 ? "1 hour" : "\(whole) hours"
    }
    return String(format: "%.1f days", hours / 24)
  }

  private static func relativePhrase(_ date: Date) -> String {
    // A pair booked this minute rounds to "in 0 seconds" through the relative
    // formatter (the timestamps straddle the render by microseconds); the
    // honest phrase for anything inside one sampling interval is this one.
    let interval = Date().timeIntervalSince(date)
    guard interval >= 60 else { return "just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  private static func overlapPhrase(_ overlap: Double) -> String {
    "\(Int((overlap * 24).rounded())) of 24"
  }

  /// A row that OPENS the health view rather than containing it (OC19).
  ///
  /// SO14 in both strings: the hardware is a "display", never a "panel". The
  /// row label matches the health view's own header so the two surfaces name
  /// the same page; `PanelHealthView` and `PanelGrid` keep "panel" as type
  /// names, which SO14 leaves alone.
  private var healthRow: some View {
    SettingRow(caption: SettingsCaption("Which areas of this display have been lit the most, and which apps have been showing them.")) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Display health")
        Spacer(minLength: 0)
        Button("Show…") { showingHealth = true }
          .accessibilityLabel("Show…")
      }
    }
  }

  /// The hours line, with the counter's own state in it. `oledHoursTracking`
  /// off freezes both figures; saying so is the difference between a paused
  /// counter and a stuck one.
  private func hoursLine(_ tracker: PanelHoursTracker) -> String {
    let figures = "\(Self.hoursPhrase(tracker.totalHours)) in total · "
      + "\(Self.hoursPhrase(tracker.hoursSinceStandby)) since the last standby"
    return prefs.oledHoursTracking ? figures : figures + " · counting is paused"
  }

  // MARK: - Thresholds

  /// Minutes, derived from the engine's own floor rather than chosen here:
  /// `OledDimConfig` refuses anything below `minimumThresholdSeconds`, so this
  /// is the smallest whole minute the config will accept unchanged.
  private static let minimumMinutes = Int(
    (OledDimConfig.minimumThresholdSeconds / 60).rounded(.up)
  )

  /// `max` rather than a bare literal upper bound: a `ClosedRange` built the
  /// wrong way round traps, and the lower bounds here are derived from
  /// constants this file does not own.
  private static let idleMinuteRange = minimumMinutes...max(30, minimumMinutes)
  private static let unfocusedMinuteRange = minimumMinutes...max(120, minimumMinutes)

  /// Likewise the engine's blackout gap, not a local constant.
  ///
  /// The idle term rounds UP, unlike `minutes(_:)` which rounds to nearest for
  /// display. The engine clamps the blackout threshold to exactly
  /// `idleDimSeconds + blackoutGapSeconds`, so an idle threshold that is not a
  /// whole number of minutes — reachable with a `defaults write` (D26) — would
  /// otherwise put this floor up to 30 s UNDER the engine's, and the engine
  /// would silently clamp a value the stepper allowed. Rounding up can only
  /// overshoot, which the engine accepts unchanged.
  private var blackoutMinimumMinutes: Int {
    let idleMinutes = max(
      Self.minimumMinutes,
      Int((Double(prefs.oledIdleDimSeconds) / 60).rounded(.up))
    )
    return idleMinutes + Int((OledDimConfig.blackoutGapSeconds / 60).rounded(.up))
  }

  private var blackoutMinuteRange: ClosedRange<Int> {
    blackoutMinimumMinutes...max(120, blackoutMinimumMinutes)
  }

  private func minutes(_ seconds: Int) -> Int {
    max(Self.minimumMinutes, Int((Double(seconds) / 60).rounded()))
  }

  private var idleMinutesBinding: Binding<Int> {
    Binding(
      get: { minutes(prefs.oledIdleDimSeconds) },
      set: { newMinutes in
        let seconds = newMinutes * 60
        let blackoutFloor = seconds + Int(OledDimConfig.blackoutGapSeconds)
        // Raising the idle threshold past the blackout one would leave the
        // engine to clamp the blackout silently, so the pane would keep showing
        // a value nothing uses. Move it here instead, where the user can see it
        // move — one batch write, fanning out to the union of both rows.
        if prefs.oledBlackoutSeconds < blackoutFloor {
          writer.writeAll([.oledIdleDimSeconds, .oledBlackoutSeconds]) {
            $0.oledIdleDimSeconds = seconds
            $0.oledBlackoutSeconds = blackoutFloor
          }
        } else {
          writer.write(.oledIdleDimSeconds) { $0.oledIdleDimSeconds = seconds }
        }
      }
    )
  }

  private var blackoutMinutesBinding: Binding<Int> {
    Binding(
      get: { max(blackoutMinimumMinutes, minutes(prefs.oledBlackoutSeconds)) },
      set: { newMinutes in
        writer.write(.oledBlackoutSeconds) { $0.oledBlackoutSeconds = newMinutes * 60 }
      }
    )
  }

  private var unfocusedMinutesBinding: Binding<Int> {
    Binding(
      get: { minutes(prefs.oledUnfocusedDimSeconds) },
      set: { newMinutes in
        writer.write(.oledUnfocusedDimSeconds) { $0.oledUnfocusedDimSeconds = newMinutes * 60 }
      }
    )
  }

  /// The system `displaysleep` setting makes a longer threshold dead
  /// configuration: the panel blanks before the dim would ever engage. Stated
  /// with both numbers, because the fix is to change one of them.
  @ViewBuilder
  private func displaySleepWarning(forThresholdSeconds seconds: Int) -> some View {
    if let displaySleepMinutes, displaySleepMinutes > 0, seconds >= displaySleepMinutes * 60 {
      OledInlineNote(Text(verbatim: """
      macOS turns this display off after \(Self.minutesPhrase(displaySleepMinutes)) of \
      inactivity, so the display sleeps before the dim ever engages. Lower it, or raise the \
      display sleep time in System Settings > Lock Screen.
      """))
    }
  }

  // MARK: - Levels

  /// The dim-brightness row, shared by the idle and unfocused settings so the
  /// two cannot drift into different shapes. The number is HOW BRIGHT the
  /// display is left, so lower is darker; the range comes from
  /// `OledDimConfig.brightnessRange`: the config sanitises to exactly that,
  /// and a slider that could express more would be a slider that lies.
  private func levelRow(
    label: LocalizedStringKey,
    caption: LocalizedStringKey,
    draft: Binding<Double?>,
    value: Double,
    accessibilityName: String,
    commit: @MainActor @escaping (Double) -> Void
  ) -> some View {
    let live = draft.wrappedValue ?? value
    return SettingRow(caption) {
      VStack(alignment: .leading, spacing: 4) {
        HStack {
          Text(label)
          Spacer(minLength: 12)
          Text(verbatim: Self.percent(live))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Slider(
          value: Binding(get: { live }, set: { draft.wrappedValue = $0 }),
          in: OledDimConfig.brightnessRange,
          // 10% steps: SwiftUI draws a tick per step on macOS, and a finer
          // step turned the row into a comb of seventeen marks. Ten percent is
          // also the smallest change anyone can see in a dim.
          step: 0.1,
          onEditingChanged: { editing in
            guard !editing else { return }
            // Written once, when the drag ends. Dropping the draft afterwards
            // is what lets the row start reading the pref again.
            if let dragged = draft.wrappedValue {
              draft.wrappedValue = nil
              if dragged != value { commit(dragged) }
            }
          }
        )
        .accessibilityLabel(Text(verbatim: accessibilityName))
        .accessibilityValue(Text(verbatim: Self.percent(live)))
        // The keyboard path. `onEditingChanged` is a DRAG boundary: adjusting a
        // focused slider with the arrow keys moves the draft and never ends an
        // edit, so without this the value would show as changed and never be
        // written — and would snap back on the next re-render. Restarted by
        // every change, so it commits half a second after the user stops.
        .task(id: live) {
          guard draft.wrappedValue != nil else { return }
          try? await Task.sleep(for: .milliseconds(500))
          guard !Task.isCancelled, let pending = draft.wrappedValue else { return }
          draft.wrappedValue = nil
          if pending != value { commit(pending) }
        }
      }
    }
  }

  // MARK: - Formatting

  private static func percent(_ brightness: Double) -> String {
    "\(Int((brightness * 100).rounded()))%"
  }

  /// English only (D25), and singular matters: the idle threshold's floor is
  /// one minute, so "1 minutes" would be on screen by default on any display
  /// tuned that low.
  private static func minutesPhrase(_ value: Int) -> String {
    value == 1 ? "1 minute" : "\(value) minutes"
  }

  /// Converged with `PanelHealthView.panelTimePhrase` via `PanelHealthCopy`.
  ///
  /// The two had grown apart: the same unit rendered "0.4 hours" here and "24
  /// minutes" one click away, "0 hours" here and "none yet" there, and each
  /// site carried a comment explaining why its own choice avoided a
  /// stuck-counter reading. The minutes form won, because a freshly enrolled
  /// display reading zero for its whole first hour is the defect BOTH were
  /// written around and only one of them actually fixed.
  ///
  /// The zero phrase stays this surface's own: here the number is the subject
  /// of the sentence, so it reads "0 hours"; a leaderboard row with no time
  /// should not have appeared at all, so there it reads "none yet".
  private static func hoursPhrase(_ hours: Double) -> String {
    PanelHealthCopy.hours(hours)
  }
}
