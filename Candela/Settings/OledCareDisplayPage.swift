import CandelaKit
import CoreGraphics
import SwiftUI

/// One display's OLED Care page, pushed from the pane's overview:
/// enrollment, the hero, the exposure findings, everything that dims
/// (never behind a second click), and the rows that lead on. An un-enrolled
/// display's page is the enrollment pitch, with no dead controls.
///
/// The hero is glanceable only; the map is a doorway into the Heat Map
/// window, which owns the lens picker, window outlines and crosshair. This page
/// pushes nothing and takes no navigation path of its own.
///
/// Copy rule for every sentence in this file: software has exactly two
/// levers against burn-in, reduce luminance and reduce time at luminance.
/// Nothing here may claim more than that.
@MainActor
struct OledCareDisplayPage: View {
  let state: AppModel.DisplayState
  let displays: [(key: String, name: String)]
  let onSwitch: (String) -> Void

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.settingsAccent) private var lighting

  /// `pmset -g` costs a 79 ms process spawn [MEASURED 2026-08-06]. Read ONCE
  /// per page appearance into state, never from `body` (which re-evaluates on
  /// every pref write and on every dim-state change) and never under the
  /// dim-state task id.
  @State private var displaySleepMinutes: Int?

  /// Not read in `body` (it re-evaluates on every pref write). Re-sampled on the
  /// engine's dim state, the one live signal an assertion actually moves.
  @State private var displaySleepAssertionHeld = false

  /// Slider drafts, live only while a drag is in progress. A `Slider` bound
  /// straight to a pref writes, fans out and bumps `prefsRevision` on every
  /// pixel of the drag, re-rendering the page under the user's pointer. Nil
  /// means "read the pref", so an external write shows up immediately.
  @State private var idleLevelDraft: Double?
  @State private var unfocusedLevelDraft: Double?
  /// `PanelHoursTracker` is a plain class with no observation, so nothing
  /// re-renders this page when the hours line changes. Bumped by the one action
  /// that changes it from here (Dismiss).
  @State private var hoursRevision = 0
  /// The hero map is a button into the Heat Map window, and a still image does
  /// not read as one. Lift rather than tint, because an inactive window draws
  /// every accent grey (the measured glance-tile lesson).
  @State private var heroHovering = false

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
    SettingsPageScaffold {
      SubPageHeader(
        title: name,
        currentKey: persistenceKey,
        displays: displays,
        onSwitch: onSwitch)

      SettingsCardSection {
        // The same caption rides the hub's enrollment toggle, so the two
        // surfaces cannot describe enrollment differently.
        SettingRow("Enrolling applies the recommended settings; nothing changes until this display has been idle for a while.") {
          Toggle("Enroll this display in OLED care", isOn: Binding(
            get: { prefs.oledCareEnrolled },
            set: { on in writer.write(.oledCareEnrolled) { $0.oledCareEnrolled = on } }
          ))
          .themedSwitch()
          .accessibilityLabel("Enroll this display in OLED care")
          // Deliberately the hub toggle's identifier: same setting, same
          // display, never both in the rendered tree, so a walk finds one.
          .prefIdentifier(.oledCareEnrolled, persistenceKey: persistenceKey)
        }

        SettingsCardDivider()

        if prefs.oledCareEnrolled {
          hero
          standbyNote
        } else {
          unenrolledHero
        }
      }

      // The enrollment pitch: what enrolling would do, stated where the decision is.
      // The numbers are the Recommended preset's; change them together or the
      // pitch lies.
      if !prefs.oledCareEnrolled {
        SettingsCaption("Enrolling applies the recommended settings: dim to 50% after 5 idle minutes, dim while locked, and count hours of use. Everything can be changed afterward, and nothing outside this display is touched.")
      }

      if prefs.oledCareEnrolled {
        // The findings sit above the settings they argue for (settled
        // 2026-08-20). The Heat Map window keeps the map and the instruments
        // that interrogate it.
        let findings = model.oledCare.healthSummary(for: persistenceKey)
        PanelHottestAreaCard(summary: findings)
        PanelDisplayTimeCard(summary: findings)

        SettingsCardSection(title: "Dimming") {
          idleControls
          SettingsCardDivider()
          lockControls
          SettingsCardDivider()
          blackoutControls
          SettingsCardDivider()
          unfocusedControls
          SettingsCardDivider()
          detectionControls
        }

        SettingsCardSection(title: "More") {
          // A sideways move, not a push: the controls live on the Health
          // pane, so this row changes the sidebar selection through the reveal
          // seam rather than owning navigation state. Chevron and preview stay,
          // because it still leads somewhere.
          NavigationRow(
            title: "Health",
            value: measurementRowPreview,
            action: {
              // The note below promises "this display", so the link carries
              // which one. A pane reveal names no display, and the Health pane's
              // switcher would otherwise open on whichever external sorts first.
              actions.pendingHealthScope = persistenceKey
              actions.reveal(.pane(.health))
            })
          SettingsRowNote("Measuring is set for this display on the Health pane, where switching it off stops new readings and keeps everything recorded so far.")
          SettingsCardDivider()
          NavigationRow(
            title: "Heat Map",
            value: healthRowPreview,
            // A window, not a push: the settings window cannot resize
            // to a portrait display's map, and a content-sized window can.
            action: { actions.openDisplayHealth(persistenceKey) })
        }
      }
    }
    // Two tasks: keyed together, every dim transition would re-spawn pmset.
    .task { displaySleepMinutes = OledCareSignalSources.displaySleepMinutes() }
    .task(id: model.oledCare.dimStates[persistenceKey]) {
      displaySleepAssertionHeld = OledCareSignalSources.displaySleepAssertionHeld()
    }
  }

  // MARK: - Row previews

  /// Short forms only; the pages themselves carry the detail.
  private var measurementRowPreview: String {
    var parts: [String] = [prefs.oledTelemetry ? "Measuring" : "Not measuring"]
    if prefs.oledHoursTracking { parts.append("counting hours") }
    return parts.joined(separator: " · ")
  }

  private var healthRowPreview: String? {
    let summary = model.oledCare.healthSummary(for: persistenceKey)
    guard summary.confidence == .measured, let relative = summary.hottestRelative,
      let multiple = PanelHealthCopy.multiple(relative)
    else { return nil }
    return "Hottest area \(multiple) average"
  }

  // MARK: - Hero

  /// The page's opening image: accumulated history as a picture beside
  /// the same facts as rows, so the map stays decorative to VoiceOver. Honesty
  /// precedence is the health page's: Safe Mode, then the grant, then
  /// confidence. The whole map column is a button into the Heat Map window.
  @ViewBuilder private var hero: some View {
    let summary = model.oledCare.healthSummary(for: persistenceKey)
    let tracker = model.oledCare.hoursTracker(for: persistenceKey)
    let historyBlank = summary.confidence != .measured
    // The hero shows the monitor as it hangs, portrait mounts included.
    // Storage stays panel-native underneath.
    let aspect =
      OledPanelGeometry.displayAspect(for: state.display.id)
      ?? CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows)

    HStack(alignment: .top, spacing: 20) {
      Button {
        // Same doorway as the More row: the Heat Map's own window.
        actions.openDisplayHealth(persistenceKey)
      } label: {
        VStack(alignment: .leading, spacing: 8) {
          if historyBlank {
            blankMapFrame(aspect: aspect)
            Text(verbatim: mapPlaceholder(summary))
              .font(.caption)
              .foregroundStyle(SettingsTheme.faintColor)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            PanelExposureSurface(
              cells: summary.cells,
              highlighted: OledPanelGeometry.hottestIndex(summary.cells),
              aspect: aspect,
              rotation: OledPanelGeometry.rotation(for: state.display.id),
              glowStrength: 0.6,
              reticle: true)
            .overlay {
              // The marked cell explains itself on the map; the full
              // multiple is one push away, so the tag is one word.
              OledHotspotTag(
                cells: summary.cells,
                rotation: OledPanelGeometry.rotation(for: state.display.id),
                text: "Hottest")
            }
            PanelExposureLegend()
          }
          // The visible affordance for the button this column is. Brightness
          // rather than accent: an inactive window draws every accent grey.
          Text("Heat Map ›")
            .font(.caption)
            .foregroundStyle(heroHovering ? SettingsTheme.titleColor : SettingsTheme.bodyColor)
        }
        // A portrait display at the landscape width towers over the stat column
        // and pushes Dimming below the fold (measured on the rotated Dell at
        // 200 pt: the map ran ~355 pt tall in a 520 pt window). The hero is
        // glanceable; the reading surface is the Heat Map window.
        .frame(maxWidth: aspect < 1 ? 130 : 300)
        .contentShape(Rectangle())
      }
      .buttonStyle(OledTileButtonStyle())
      .scaleEffect(heroHovering && !reduceMotion ? 1.02 : 1)
      .shadow(
        color: .black.opacity(heroHovering ? 0.35 : 0),
        radius: heroHovering ? 10 : 0, y: 3)
      .animation(reduceMotion ? nil : .spring(duration: 0.25), value: heroHovering)
      .onHover { heroHovering = $0 }
      .accessibilityLabel("Heat Map")

      VStack(alignment: .leading, spacing: 10) {
        heroStat("Status") { Text(statusText) }
        heroStat("Hours of use") {
          Text(verbatim: hoursLine(tracker))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(Motion.value(reduceMotion: reduceMotion), value: hoursLine(tracker))
        }
        // No "Hottest area" stat here: `PanelHottestAreaCard` states the same
        // measurement under the same gate further down this page, and two
        // readings of one number is how the two come to disagree.
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
                // The destination's hue, never the system accent: the rest of
                // this window does not follow that preference.
                .tint(lighting.accent)
                .frame(maxWidth: 140)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
  }

  /// The enrollment pitch's hero-shaped blank: the display's real shape with nothing claimed
  /// about it, beside the one honest stat.
  @ViewBuilder private var unenrolledHero: some View {
    let aspect =
      OledPanelGeometry.displayAspect(for: state.display.id)
      ?? CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows)
    HStack(alignment: .top, spacing: 20) {
      blankMapFrame(aspect: aspect)
        .frame(maxWidth: aspect < 1 ? 130 : 300)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 10) {
        heroStat("Status") { Text("Not enrolled") }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
  }

  /// A notice about the display, not a setting, so it stays beside the hours it
  /// explains.
  @ViewBuilder private var standbyNote: some View {
    // ONE tracker per display, from the coordinator. Never construct one here:
    // a second live instance reads a stale count and clobbers the real one on
    // its next write-through.
    let tracker = model.oledCare.hoursTracker(for: persistenceKey)
    if tracker.shouldShowStandbyNote {
      SettingsCardDivider()
      SettingRow(caption: SettingsCaption("Most OLED displays run their own compensation cycle when they go into standby, and skip it while they are in use. Anything that puts the display to sleep counts: the monitor's own power button, or leaving the Mac idle.")) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("This display has not been in standby for a while.")
          Spacer(minLength: 12)
          Button("Dismiss") {
            tracker.dismissStandbyNote()
            hoursRevision &+= 1
          }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .accessibilityLabel("Dismiss")
        }
      }
    }
  }

  private func heroStat(_ label: String, @ViewBuilder value: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(verbatim: label)
        .font(.caption)
        .foregroundStyle(SettingsTheme.faintColor)
      value()
        .foregroundStyle(SettingsTheme.bodyColor)
    }
  }

  /// The map's footprint with nothing in it: a recessed well rather than a
  /// filled tile, so an empty hero reads as pending rather than broken.
  private func blankMapFrame(aspect: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
      .fill(Color.black.opacity(0.22))
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .strokeBorder(SettingsTheme.cardStroke, lineWidth: 1)
      }
      .aspectRatio(aspect, contentMode: .fit)
  }

  /// Caption under a blank hero map. `summary.cells` stays populated whatever
  /// the confidence, so blanking the drawing must not also claim there is no
  /// history behind it.
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
    case .insufficient:
      return "\(summary.sampleCount) of \(ExposureAccumulator.minimumSamplesForAnalysis) readings"
    case .estimated: return "Off"
    }
  }

  /// Live means a reading landed inside `OledCareCadence.livenessWindowSeconds`,
  /// so a dead grant stills the dot within minutes whatever the prefs claim.
  private func isMeasuringLive(_ summary: PanelHealthSummary) -> Bool {
    guard !model.isSafeMode, prefs.oledTelemetry, CGPreflightScreenCaptureAccess(),
      let last = summary.lastSample
    else { return false }
    return Date().timeIntervalSince(last) < OledCareCadence.livenessWindowSeconds
  }

  /// What the engine is doing right now. `dimStates` is the coordinator's own
  /// published state, never a second opinion computed here; a mirrored display's
  /// "paused" reading is the one state that must stay visible.
  private var statusText: LocalizedStringKey {
    if model.isSafeMode { return "Paused for this session (Safe Mode)" }
    // Exhaustive, so a new engine state is a compile error here rather than a
    // blank row.
    switch model.oledCare.dimStates[persistenceKey] {
    case .active: return "Not dimming"
    case .idleDim: return "Dimmed: the display has been idle"
    case .blackout: return "Screen off: the display has been idle"
    // A lock dim the policy refused is RECORDED and must
    // never be reported as dimmed. `lockDimSkips` carries only live refusals
    // (cleared the moment the dim engages), so reading it here cannot outlive
    // the state it describes.
    case .lockDim: return OledCareCopy.lockDimStatus(model.oledCare.lockDimSkips[persistenceKey])
    case .unfocusedDim: return "Dimmed: no window in focus on this display"
    // One pause state, several reasons. `suspensionReason` reads the same
    // tick's verdict as `dimStates`, so the two cannot disagree about which.
    case .suspended:
      return OledCareCopy.suspendedStatus(
        reason: model.oledCare.suspensionReason(for: persistenceKey))
    // Between enrolling and the first tick, and for a display the coordinator
    // has not reconciled yet.
    case nil: return "Starting"
    }
  }

  // MARK: - Idle dim

  @ViewBuilder private var idleControls: some View {
    SettingRow(caption: SettingsCaption("Counted from the last keyboard or mouse activity anywhere on the Mac; video playback, calls and anything else holding the screen awake postpone it.")) {
      VStack(alignment: .leading, spacing: 6) {
        minutesStepper(
          phrase: "Dim after \(Self.minutesPhrase(minutes(prefs.oledIdleDimSeconds))) of inactivity",
          prefIdentifier: .oledIdleDimSeconds,
          value: idleMinutesBinding,
          in: Self.idleMinuteRange)
        // In the SAME row as the control it is about: a divider between a
        // threshold and the sentence saying it does nothing turns the warning
        // into what looks like an unrelated setting.
        displaySleepWarning(forThresholdSeconds: prefs.oledIdleDimSeconds)
      }
    }

    SettingsCardDivider()

    levelRow(
      label: "Dim to",
      caption: "How bright the display is while dimmed: \(AppInfo.productName) draws a dark overlay over it, the display's own brightness setting is untouched, and any key or click restores the picture immediately.",
      prefIdentifier: .oledIdleDimLevel,
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
      .themedSwitch()
      .accessibilityLabel("Dim while the screen is locked")
      .prefIdentifier(.oledLockDim, persistenceKey: persistenceKey)
    }
  }

  // MARK: - Blackout

  @ViewBuilder private var blackoutControls: some View {
    // TWO sentences by design: a key wakes the blackout but is NOT
    // discarded, and the copy must never promise it is.
    SettingRow("Goes fully black after a longer idle period; the click that wakes it is discarded, so nothing is clicked by accident. A key press wakes it too, but reaches whichever app you were using.") {
      Toggle("Turn the screen black after longer", isOn: Binding(
        get: { prefs.oledBlackoutEnabled },
        set: { on in writer.write(.oledBlackoutEnabled) { $0.oledBlackoutEnabled = on } }
      ))
      .themedSwitch()
      .accessibilityLabel("Turn the screen black after longer")
      .prefIdentifier(.oledBlackoutEnabled, persistenceKey: persistenceKey)
    }
    if prefs.oledBlackoutEnabled {
      SettingsCardDivider()
      // The lower bound is the engine's own floor: `OledDimConfig` clamps the
      // blackout threshold to at least idle + the gap, so a control that could
      // express less would lie about what it did.
      VStack(alignment: .leading, spacing: 6) {
        // The label reads the BINDING, not the raw pref: the binding is the
        // clamped value, and a label under the stepper's own number would be the
        // silent rewrite this clamp exists to make visible.
        minutesStepper(
          phrase: "Go black after \(Self.minutesPhrase(blackoutMinutesBinding.wrappedValue)) of inactivity",
          prefIdentifier: .oledBlackoutSeconds,
          value: blackoutMinutesBinding,
          in: blackoutMinuteRange)
        displaySleepWarning(forThresholdSeconds: prefs.oledBlackoutSeconds)
      }
      .padding(.vertical, 6)
    }
  }

  // MARK: - Unfocused dim

  @ViewBuilder private var unfocusedControls: some View {
    SettingRow("Dims while no window on this display is in focus, even while you are working on another display: only clicking into this display brings it back, not typing elsewhere.") {
      Toggle("Dim while this display has nothing in focus", isOn: Binding(
        get: { prefs.oledUnfocusedDimEnabled },
        set: { on in writer.write(.oledUnfocusedDimEnabled) { $0.oledUnfocusedDimEnabled = on } }
      ))
      .themedSwitch()
      .accessibilityLabel("Dim while this display has nothing in focus")
      .prefIdentifier(.oledUnfocusedDimEnabled, persistenceKey: persistenceKey)
    }
    if prefs.oledUnfocusedDimEnabled {
      SettingsCardDivider()
      minutesStepper(
        phrase: "Dim after \(Self.minutesPhrase(minutes(prefs.oledUnfocusedDimSeconds))) without focus",
        prefIdentifier: .oledUnfocusedDimSeconds,
        value: unfocusedMinutesBinding,
        in: Self.unfocusedMinuteRange)
        .padding(.vertical, 6)
      SettingsCardDivider()
      levelRow(
        label: "Dim to",
        caption: "How bright an unfocused display is while dimmed. Usually higher than the idle dim, because the display is still in view.",
        prefIdentifier: .oledUnfocusedDimLevel,
        draft: $unfocusedLevelDraft,
        value: prefs.oledUnfocusedDimBrightness,
        accessibilityName: "Unfocused dim brightness"
      ) { brightness in
        writer.write(.oledUnfocusedDimLevel) { $0.oledUnfocusedDimBrightness = brightness }
      }
    }
  }

  // MARK: - Static-region dim

  /// Off by default, and the copy leads with what it does to the screen rather
  /// than with what it protects: every other control in OLED care acts while the
  /// user is away, and this one changes what they are looking at.
  ///
  /// It depends on BOTH measurement settings, one for luminance and one for
  /// staticness, and they live on the Health pane, so the caption names that
  /// pane instead of leaving the switch to do nothing silently.
  ///
  /// The assertion gate is system-wide, so our own Keep Display Awake silences
  /// this control as surely as a video does. The caption lists it; the note
  /// says when it is the live reason.
  ///
  /// The caption promises exactly what the code delivers. "Full-screen video is
  /// never dimmed" is the `fullScreenOwner` gate, read from the window list. It
  /// does NOT promise a WINDOWED video is safe, because bounds stability is not
  /// content staticness and a player holding a fixed rect passes both halves of
  /// the conjunction. NOT claimed either: "eases off where you are pointing".
  /// The pointer is not an input to `StaticRegionDetector` and the coordinator
  /// supplies none, so that sentence goes in when the falloff exists.
  private var detectionControls: some View {
    SettingRow("Areas that stay bright and unchanged, like a toolbar or a sidebar, are dimmed a little while you work. Full-screen video is never dimmed, and nothing is dimmed while anything is holding the screen awake, including Keep Display Awake. This needs both measurement settings on the Health pane: without them nothing is dimmed.") {
      VStack(alignment: .leading, spacing: 6) {
        Toggle("Automatic static-region dimming", isOn: Binding(
          get: { prefs.oledDetectionDimming },
          set: { on in writer.write(.oledDetectionDimming) { $0.oledDetectionDimming = on } }
        ))
        .themedSwitch()
        .accessibilityLabel("Automatic static-region dimming")
        .prefIdentifier(.oledDetectionDimming, persistenceKey: persistenceKey)
        // Same row as the switch: a divider would make the warning read as an
        // unrelated setting.
        if prefs.oledDetectionDimming, displaySleepAssertionHeld {
          OledInlineNote(Text("Something is holding the screen awake: video playback, a call, or Keep Display Awake. Nothing is dimmed here for as long as that lasts."))
        }
      }
    }
  }

  // MARK: - Thresholds

  /// Minutes, derived from the engine's own floor rather than chosen here:
  /// `OledDimConfig` refuses anything below `minimumThresholdSeconds`, so this
  /// is the smallest whole minute the config will accept unchanged.
  private static let minimumMinutes = Int(
    (OledDimConfig.minimumThresholdSeconds / 60).rounded(.up)
  )

  /// `max` rather than a literal upper bound: a `ClosedRange` built the wrong
  /// way round traps, and these lower bounds come from constants this file does
  /// not own.
  private static let idleMinuteRange = minimumMinutes...max(30, minimumMinutes)
  private static let unfocusedMinuteRange = minimumMinutes...max(120, minimumMinutes)

  /// Likewise the engine's blackout gap, not a local constant.
  ///
  /// The idle term rounds UP, unlike `minutes(_:)` which rounds to nearest for
  /// display. A non-whole-minute idle threshold (reachable with a
  /// `defaults write`) would otherwise put this floor up to 30 s UNDER the
  /// engine's, and the engine would silently clamp a value the stepper allowed.
  /// Rounding up can only overshoot, which the engine accepts unchanged.
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
        // Raising idle past blackout would leave the engine to clamp blackout
        // silently, so the page would keep showing a value nothing uses. Moved
        // here instead, where the user can see it move: one batch write.
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

  /// A threshold in whole minutes. The written phrase is the control's spoken
  /// label, so the drawn copy leaves the accessibility tree.
  ///
  /// `prefIdentifier` comes from the CALLER for `levelRow`'s reason: one helper
  /// serves three thresholds. Same tripwire: deleting the `.prefIdentifier` call
  /// below while keeping the parameter leaves all three steppers bare with the
  /// coverage test still green.
  private func minutesStepper(
    phrase: String,
    prefIdentifier: PrefName,
    value: Binding<Int>,
    in range: ClosedRange<Int>
  ) -> some View {
    HStack(spacing: 12) {
      Text(verbatim: phrase)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
      Spacer(minLength: 16)
      Stepper(value: value, in: range) { EmptyView() }
        .accessibilityLabel(Text(verbatim: phrase))
        .prefIdentifier(prefIdentifier, persistenceKey: persistenceKey)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// A threshold past the system `displaysleep` setting is dead configuration:
  /// the panel blanks before the dim engages. Stated with both numbers, because
  /// the fix is to change one of them.
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
  /// display is left, so lower is darker; the range is
  /// `OledDimConfig.brightnessRange`, which the config sanitises to exactly, and
  /// a slider that could express more would lie.
  ///
  /// The accessibility identifier comes from the CALLER: one helper serves both
  /// levels, and a hardcoded name would put the idle identifier on both sliders.
  /// The coverage scan sees these two cases ONLY through the argument label, so
  /// deleting the `.prefIdentifier` call inside this helper while keeping the
  /// parameter leaves both sliders bare with the test still green.
  private func levelRow(
    label: LocalizedStringKey,
    caption: LocalizedStringKey,
    prefIdentifier: PrefName,
    draft: Binding<Double?>,
    value: Double,
    accessibilityName: String,
    commit: @MainActor @escaping (Double) -> Void
  ) -> some View {
    let live = draft.wrappedValue ?? value
    let readout = Self.percent(live)
    return SettingRow(caption) {
      HStack(spacing: 12) {
        // Spoken by the slider, which carries the setting's name rather than
        // this shared two-word label.
        Text(label).accessibilityHidden(true)
        Spacer(minLength: 16)
        ThemedSlider(
          value: Binding(get: { live }, set: { draft.wrappedValue = $0 }),
          range: OledDimConfig.brightnessRange,
          // 10% steps: the smallest change anyone can see in a dim, and the
          // grid a keyboard or VoiceOver step lands on.
          step: 0.1,
          // The stored number is a fraction; the row says what the display
          // will be left at, so the readout is what VoiceOver reads too.
          accessibilityValueText: readout,
          onEditingChanged: { editing in
            guard !editing else { return }
            // Written once, when the drag ends; dropping the draft is what lets
            // the row read the pref again. An adjustable action opens and closes
            // its own editing session, so a keyboard or VoiceOver step commits
            // per step BY DESIGN: never debounce the accessibility path.
            if let dragged = draft.wrappedValue {
              draft.wrappedValue = nil
              if dragged != value { commit(dragged) }
            }
          }
        )
        .frame(width: 150)
        .accessibilityLabel(Text(verbatim: accessibilityName))
        .prefIdentifier(prefIdentifier, persistenceKey: persistenceKey)
        // The keyboard path, where the edit never closes: the draft would show
        // as changed, never be written, and snap back on the next re-render.
        // Restarted by every change, so it commits after the user stops.
        .task(id: live) {
          guard draft.wrappedValue != nil else { return }
          try? await Task.sleep(for: .milliseconds(500))
          guard !Task.isCancelled, let pending = draft.wrappedValue else { return }
          draft.wrappedValue = nil
          if pending != value { commit(pending) }
        }
        Text(verbatim: readout)
          .foregroundStyle(SettingsTheme.bodyColor)
          .monospacedDigit()
          .frame(width: 42, alignment: .trailing)
      }
    }
  }

  // MARK: - Formatting

  private static func percent(_ brightness: Double) -> String {
    "\(Int((brightness * 100).rounded()))%"
  }

  /// English only, and singular matters: the idle threshold's floor is one
  /// minute, so "1 minutes" would be on screen on any display tuned that low.
  private static func minutesPhrase(_ value: Int) -> String {
    value == 1 ? "1 minute" : "\(value) minutes"
  }

  /// The hours line, with the counter's own state in it. `oledHoursTracking` off
  /// freezes both figures, and saying so is the difference between a paused
  /// counter and a stuck one.
  private func hoursLine(_ tracker: PanelHoursTracker) -> String {
    let figures = "\(PanelHealthCopy.hours(tracker.totalHours)) in total · "
      + "\(PanelHealthCopy.hours(tracker.hoursSinceStandby)) since the last standby"
    return prefs.oledHoursTracking ? figures : figures + " · counting is paused"
  }
}
