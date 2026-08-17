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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            withAnimation(Motion.scroll(reduceMotion: reduceMotion)) {
              proxy.scrollTo(key, anchor: .top)
            }
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
  /// Which lens the hero surface shows. Session state, not a pref.
  @State private var heroMode: HeroSurfaceMode = .history
  @State private var showsWindowGhosts = false
  /// Pointer location over the hero surface, for the crosshair inspection.
  @State private var hoverPoint: CGPoint?

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
  private enum HeroSurfaceMode { case history, now }

  @ViewBuilder private var hero: some View {
    let summary = model.oledCare.healthSummary(for: persistenceKey)
    let tracker = model.oledCare.hoursTracker(for: persistenceKey)
    let live = model.oledCare.latestSample(for: persistenceKey)
    let historyBlank = summary.confidence != .measured
    // Display aspect and rotation: the hero shows the monitor as it hangs,
    // portrait mounts included. Storage stays panel-native underneath.
    let aspect =
      OledPanelGeometry.displayAspect(for: state.display.id)
      ?? CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows)
    // The displayed cells are the one truth every sub-layer (surface, ghosts,
    // crosshair readout) shares, so the inspection can never describe a frame
    // the surface is not drawing.
    let displayed: [Double]? =
      heroMode == .history ? (historyBlank ? nil : summary.cells) : live?.cells

    HStack(alignment: .top, spacing: 20) {
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 8) {
          heroSurface(displayed: displayed, summary: summary, aspect: aspect)
          if displayed == nil {
            Text(verbatim: mapPlaceholder(summary, mode: heroMode))
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            PanelExposureLegend()
          }
          if heroMode == .now, let live {
            Text(verbatim: "Reading from \(live.at.formatted(date: .omitted, time: .standard)); brightness of what the display was showing.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        // A portrait display at the landscape width would tower over the stat
        // column, so only the map and its captions take the narrow cap. The
        // controls row stays OUTSIDE it: inside, a portrait column left the
        // Windows toggle ~20 pt after the picker and its label truncated to an
        // empty capsule.
        .frame(maxWidth: aspect < 1 ? 200 : 300)
        heroControls(hasHistory: !historyBlank, hasLive: live != nil)
      }

      VStack(alignment: .leading, spacing: 10) {
        heroStat("Status") { Text(statusText) }
        heroStat("Hours of use") {
          Text(verbatim: hoursLine(tracker))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(Motion.value(reduceMotion: reduceMotion), value: hoursLine(tracker))
        }
        if !historyBlank, let relative = summary.hottestRelative,
          let multiple = PanelHealthCopy.multiple(relative)
        {
          heroStat("Hottest area") {
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: "\(multiple) this display's average")
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.value(reduceMotion: reduceMotion), value: multiple)
              if let sentence = hottestSentence(summary) {
                Text(verbatim: sentence)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
        heroStat("Measurement") {
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
              OledMeasuringDot(live: isMeasuringLive(summary))
              Text(verbatim: measurementStateLine(summary))
            }
            if summary.confidence == .insufficient, prefs.oledTelemetry {
              ProgressView(
                value: Double(min(
                  summary.sampleCount, ExposureAccumulator.minimumSamplesForAnalysis)),
                total: Double(ExposureAccumulator.minimumSamplesForAnalysis))
                .controlSize(.small)
                .frame(maxWidth: 140)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
  }

  /// The surface stack: heat surface, window ghosts, crosshair inspection.
  @ViewBuilder private func heroSurface(
    displayed: [Double]?, summary: PanelHealthSummary, aspect: CGFloat
  ) -> some View {
    if let displayed {
      PanelExposureSurface(
        cells: displayed,
        highlighted: heroMode == .history
          ? OledPanelGeometry.hottestIndex(summary.cells) : nil,
        aspect: aspect,
        rotation: OledPanelGeometry.rotation(for: state.display.id),
        glowStrength: 0.6,
        reticle: true)
      .overlay {
        if showsWindowGhosts {
          ghostCanvas
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
      }
      .overlay {
        GeometryReader { geometry in
          heroInspection(displayed: displayed, summary: summary, size: geometry.size)
        }
      }
    } else {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(.quaternary)
        .overlay {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(.separator, lineWidth: 1)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .accessibilityHidden(true)
    }
  }

  /// The mode picker and the ghost toggle, shown once there is anything to
  /// switch between. Session state, not prefs: which lens is up is not a
  /// setting.
  @ViewBuilder private func heroControls(hasHistory: Bool, hasLive: Bool) -> some View {
    if hasHistory || hasLive {
      HStack(spacing: 10) {
        Picker("Map", selection: $heroMode) {
          Text("History").tag(HeroSurfaceMode.history)
          Text("Right now").tag(HeroSurfaceMode.now)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 170)
        .accessibilityLabel("Map shows")
        Toggle("Windows", isOn: $showsWindowGhosts)
          .toggleStyle(.button)
          .controlSize(.small)
          .help("Outline the windows on this display, from the same permission-free snapshot app attribution uses.")
        Spacer(minLength: 0)
      }
    }
  }

  /// Current window rectangles over the surface, the geometry model made
  /// visible. Same layer policy as the exposure model, so what is outlined is
  /// what the estimate counts; below-zero backdrop layers stay out.
  private var ghostCanvas: some View {
    let windows = model.oledCare.latestWindowSnapshots(for: persistenceKey)
    let display = OledCareCoordinator.transform(for: state.display.id)?.displaySize
    // Direct display-local mapping: the surface is drawn in display
    // orientation now, so a window rect lands exactly where the eye expects,
    // with no panel transform in between.
    return Canvas { context, size in
      guard let display, display.width > 0, display.height > 0 else { return }
      for window in windows where ExposureModel.includedLayers.contains(window.layer) {
        let bounds = window.bounds
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
          bounds.width.isFinite, bounds.height.isFinite
        else { continue }
        let clamped = bounds.intersection(CGRect(origin: .zero, size: display))
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { continue }
        let rect = CGRect(
          x: clamped.minX / display.width * size.width,
          y: clamped.minY / display.height * size.height,
          width: clamped.width / display.width * size.width,
          height: clamped.height / display.height * size.height
        ).insetBy(dx: 0.5, dy: 0.5)
        context.stroke(
          Path(roundedRect: rect, cornerRadius: 2),
          with: .color(.white.opacity(0.55)), lineWidth: 1)
      }
    }
    .allowsHitTesting(false)
  }

  /// Crosshair and readout under the pointer: the map as an instrument you
  /// can interrogate. History mode reads the accumulated cell against the
  /// map's own mean; Right now reads the live luminance. Both say only what
  /// the displayed array holds.
  @ViewBuilder private func heroInspection(
    displayed: [Double], summary: PanelHealthSummary, size: CGSize
  ) -> some View {
    Color.clear
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active(let location): hoverPoint = location
        case .ended: hoverPoint = nil
        }
      }
      .overlay {
        if let point = hoverPoint, size.width > 0, size.height > 0 {
          // Pointer to PANEL cell through the shared transform, so a rotated
          // display's readout describes the cell under the pointer, not the
          // cell at those coordinates in the manufactured frame.
          let rotation = OledPanelGeometry.rotation(for: state.display.id)
          let mapper = PanelSpaceTransform(
            displaySize: CGSize(width: 1, height: 1), rotation: rotation)
          let panelPoint = mapper.panelPointForDisplay(
            u: point.x / size.width, v: point.y / size.height)
          let col = min(PanelGrid.cols - 1, max(0, Int(panelPoint.p * Double(PanelGrid.cols))))
          let row = min(PanelGrid.rows - 1, max(0, Int(panelPoint.q * Double(PanelGrid.rows))))
          let cell = row * PanelGrid.cols + col
          Canvas { context, canvasSize in
            var lines = Path()
            lines.move(to: CGPoint(x: point.x, y: 0))
            lines.addLine(to: CGPoint(x: point.x, y: canvasSize.height))
            lines.move(to: CGPoint(x: 0, y: point.y))
            lines.addLine(to: CGPoint(x: canvasSize.width, y: point.y))
            context.stroke(lines, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
          }
          .allowsHitTesting(false)
          inspectionReadout(cell: cell, displayed: displayed, summary: summary)
            .position(
              x: min(max(point.x + 70, 70), size.width - 70),
              y: max(point.y - 26, 18))
            .allowsHitTesting(false)
        }
      }
  }

  @ViewBuilder private func inspectionReadout(
    cell: Int, displayed: [Double], summary: PanelHealthSummary
  ) -> some View {
    let lines = inspectionLines(cell: cell, displayed: displayed, summary: summary)
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: 1) {
        ForEach(lines, id: \.self) { line in
          Text(verbatim: line)
        }
      }
      .font(.caption2.monospaced())
      .foregroundStyle(.white)
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
    }
  }

  private func inspectionLines(
    cell: Int, displayed: [Double], summary: PanelHealthSummary
  ) -> [String] {
    guard displayed.indices.contains(cell) else { return [] }
    var lines: [String] = []
    switch heroMode {
    case .history:
      let mean = displayed.reduce(0, +) / Double(displayed.count)
      if mean > 0, let multiple = PanelHealthCopy.multiple(displayed[cell] / mean) {
        lines.append("\(multiple) average")
      }
    case .now:
      lines.append("\(Int((displayed[cell] * 100).rounded()))% luminance")
    }
    if let owner = summary.dominantOwnerByCell?[cell] {
      lines.append(owner)
    }
    return lines
  }

  /// The pulse's honesty: live means the pipeline produced a reading inside
  /// the last two sampling intervals, so a dead grant stills the dot within
  /// two minutes whatever the prefs claim.
  private func isMeasuringLive(_ summary: PanelHealthSummary) -> Bool {
    guard !model.isSafeMode, prefs.oledTelemetry, CGPreflightScreenCaptureAccess(),
      let last = summary.lastSample
    else { return false }
    return Date().timeIntervalSince(last) < 180
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
  private func mapPlaceholder(_ summary: PanelHealthSummary, mode: HeroSurfaceMode) -> String {
    if mode == .now {
      return "No reading this session yet. One lands within a minute while this display is awake, in use, and Screen Recording is granted."
    }
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
    case .insufficient:
      return "\(summary.sampleCount) of \(ExposureAccumulator.minimumSamplesForAnalysis) readings"
    case .estimated: return "Off"
    }
  }

  /// The outline is the pointer; prose coordinates ("toward the top, on the
  /// right") were cut as noise. Past tense for the owner, the health view's
  /// reason: the snapshot behind it is up to a minute old.
  private func hottestSentence(_ summary: PanelHealthSummary) -> String? {
    guard let owner = summary.hottestOwner else { return "Outlined on the map." }
    return "Outlined on the map. \(owner) was there at the last reading."
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
