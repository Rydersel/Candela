import CandelaKit
import CoreGraphics
import SwiftUI

/// One display's OLED Care page, pushed from the pane's overview (OCR1):
/// enrollment, the glanceable hero, everything that dims (OCR2: idle, lock,
/// blackout, unfocused, never behind a second click), and the two drill-in
/// rows. An un-enrolled display's page is the enrollment pitch (OCR10): the
/// toggle, an empty map frame, and what the recommended settings would do,
/// with no dead controls.
///
/// The hero here is glanceable only (OCR5): map beside four stats, and the
/// map is the doorway to Display Health. The lens picker, window outlines and
/// crosshair live on that page now.
///
/// Copy rule for every sentence in this file (OC11): software has exactly two
/// levers against burn-in, reduce luminance and reduce time at luminance.
/// Nothing here may claim more than that.
@MainActor
struct OledCareDisplayPage: View {
  let state: AppModel.DisplayState
  let path: Binding<[OledCarePage]>
  let displays: [(key: String, name: String)]
  let onSwitch: (String) -> Void

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `pmset -g` costs a 79 ms process spawn [MEASURED 2026-08-06]. Read ONCE
  /// per page appearance into state, never from `body` (which re-evaluates on
  /// every pref write and on every dim-state change).
  @State private var displaySleepMinutes: Int?

  /// Slider drafts, live only while a drag is in progress. A `Slider` bound
  /// straight to a pref writes, and fans out, and bumps `prefsRevision`, on
  /// every pixel of the drag, re-rendering the page under the user's pointer.
  /// Nil means "read the pref", so an external write shows up immediately.
  @State private var idleLevelDraft: Double?
  @State private var unfocusedLevelDraft: Double?
  /// `PanelHoursTracker` is a plain class with no observation, so nothing
  /// re-renders this page when the hours line changes. Bumped by the one
  /// action that changes it from here (Dismiss); the numbers otherwise refresh
  /// whenever anything else re-renders the page.
  @State private var hoursRevision = 0
  /// The hero map is a button into Display Health, and a still image does not
  /// read as one. Hover lift plus a brightened caption say so before the
  /// click; lift rather than tint, because an inactive window draws every
  /// accent grey (the measured glance-tile lesson).
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
    Form {
      Section {
        SubPageHeader(
          title: name,
          currentKey: persistenceKey,
          displays: displays,
          onSwitch: onSwitch)

        // One sentence (SO15); the same caption rides the hub's enrollment
        // toggle so the two surfaces cannot describe enrollment differently.
        SettingRow("Enrolling applies the recommended settings; nothing changes until this display has been idle for a while.") {
          Toggle("Enroll this display in OLED care", isOn: Binding(
            get: { prefs.oledCareEnrolled },
            set: { on in writer.write(.oledCareEnrolled) { $0.oledCareEnrolled = on } }
          ))
        }

        if prefs.oledCareEnrolled {
          hero
          standbyNote
        } else {
          unenrolledHero
        }
      } footer: {
        // OCR10's pitch: what enrolling would do, stated where the decision
        // is. The numbers are the Recommended preset's (spec §5); change them
        // together or the pitch lies.
        if !prefs.oledCareEnrolled {
          SettingsCaption("Enrolling applies the recommended settings: dim to 50% after 5 idle minutes, dim while locked, and count hours of use. Everything can be changed afterward, and nothing outside this display is touched.")
        }
      }

      if prefs.oledCareEnrolled {
        Section {
          idleControls
          lockControls
          blackoutControls
          unfocusedControls
        } header: {
          Text("Dimming").settingsHeading()
        }

        Section {
          NavigationRow(
            title: "Measurement & Data",
            value: measurementRowPreview,
            action: { path.wrappedValue.append(.measurement(persistenceKey)) })
          NavigationRow(
            title: "Display Health",
            value: healthRowPreview,
            // A window, not a push (OCR-A1): the settings window cannot
            // resize to a portrait display's map, and a window sized to its
            // content can.
            action: { actions.openDisplayHealth(persistenceKey) })
        } header: {
          Text("More").settingsHeading()
        }
      }
    }
    .formStyle(.grouped)
    .task {
      displaySleepMinutes = OledCareSignalSources.displaySleepMinutes()
    }
  }

  // MARK: - Row previews (SO3)

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

  /// The page's opening image (OCR5): the display's accumulated history as a
  /// picture beside the facts as plain rows. Every fact the map draws is
  /// stated in words in the stat column, so the map stays decorative to
  /// VoiceOver, and the honesty precedence is the health page's exactly:
  /// Safe Mode, then the grant, then confidence. The whole map column is a
  /// button into Display Health.
  @ViewBuilder private var hero: some View {
    let summary = model.oledCare.healthSummary(for: persistenceKey)
    let tracker = model.oledCare.hoursTracker(for: persistenceKey)
    let historyBlank = summary.confidence != .measured
    // Display aspect and rotation: the hero shows the monitor as it hangs,
    // portrait mounts included. Storage stays panel-native underneath.
    let aspect =
      OledPanelGeometry.displayAspect(for: state.display.id)
      ?? CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows)

    HStack(alignment: .top, spacing: 20) {
      Button {
        // Same doorway as the More row: Display Health's own window (OCR-A1),
        // an AppKit island reached through the actions closure.
        actions.openDisplayHealth(persistenceKey)
      } label: {
        VStack(alignment: .leading, spacing: 8) {
          if historyBlank {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
              .fill(.quaternary)
              .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                  .strokeBorder(.separator, lineWidth: 1)
              }
              .aspectRatio(aspect, contentMode: .fit)
            Text(verbatim: mapPlaceholder(summary))
              .font(.caption)
              .foregroundStyle(.secondary)
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
              // The marked cell explains itself on the map (OCR8); the full
              // multiple lives one push away, so the tag here is one word.
              OledHotspotTag(
                cells: summary.cells,
                rotation: OledPanelGeometry.rotation(for: state.display.id),
                text: "Hottest")
            }
            PanelExposureLegend()
          }
          // The visible affordance for the button this whole column is; on
          // hover it brightens alongside the lift.
          Text("Display Health ›")
            .font(.caption)
            .foregroundStyle(heroHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        // A portrait display at the landscape width would tower over the stat
        // column AND push the Dimming section below the fold (measured on the
        // rotated Dell at 200 pt: the map ran ~355 pt tall in a 520 pt
        // window). The hero is glanceable (OCR5), so a portrait map caps
        // near the landscape map's own height; the big reading surface is
        // one push away on Display Health.
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
      .accessibilityLabel("Display Health")

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

  /// OCR10's hero-shaped blank: the display's real shape with nothing claimed
  /// about it, beside the one honest stat.
  @ViewBuilder private var unenrolledHero: some View {
    let aspect =
      OledPanelGeometry.displayAspect(for: state.display.id)
      ?? CGFloat(PanelGrid.cols) / CGFloat(PanelGrid.rows)
    HStack(alignment: .top, spacing: 20) {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(.quaternary)
        .overlay {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(.separator, lineWidth: 1)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: aspect < 1 ? 130 : 300)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 10) {
        heroStat("Status") { Text("Not enrolled") }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 4)
  }

  /// A notice about the display, not a setting, so it stays beside the hours
  /// it explains rather than moving to Measurement & Data with the toggle.
  @ViewBuilder private var standbyNote: some View {
    // ONE tracker per display, from the coordinator. Never construct one here:
    // a second live instance reads a stale count and clobbers the real one on
    // its next write-through.
    let tracker = model.oledCare.hoursTracker(for: persistenceKey)
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
  /// history behind it (the health page's own rule). Single lens here: the
  /// live reading lives on Display Health now.
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

  /// The pulse's honesty: live means the pipeline produced a reading inside
  /// the last two sampling intervals, so a dead grant stills the dot within
  /// two minutes whatever the prefs claim.
  private func isMeasuringLive(_ summary: PanelHealthSummary) -> Bool {
    guard !model.isSafeMode, prefs.oledTelemetry, CGPreflightScreenCaptureAccess(),
      let last = summary.lastSample
    else { return false }
    return Date().timeIntervalSince(last) < 180
  }

  /// The tag is the pointer (OCR8); prose coordinates were cut as noise. Past
  /// tense for the owner, the health page's reason: the snapshot behind it is
  /// up to a minute old.
  private func hottestSentence(_ summary: PanelHealthSummary) -> String? {
    guard let owner = summary.hottestOwner else { return "Marked on the map." }
    return "Marked on the map. \(owner) was there at the last reading."
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
    // SS8: the pause survives under a synthesized size in v1, but the reason
    // does not. `synthesisSuspensions` is the same tick's verdict as
    // `dimStates`, so the two cannot disagree about why this display is paused.
    case .suspended:
      return OledCareCopy.suspendedStatus(
        synthesized: model.oledCare.synthesisSuspensions.contains(persistenceKey))
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
    // and OC15's honesty rule needs the second sentence: a key wakes the
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
  /// whole number of minutes, reachable with a `defaults write` (D26), would
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
        // engine to clamp the blackout silently, so the page would keep showing
        // a value nothing uses. Move it here instead, where the user can see it
        // move: one batch write, fanning out to the union of both rows.
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
        // written, and would snap back on the next re-render. Restarted by
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

  /// The hours line, with the counter's own state in it. `oledHoursTracking`
  /// off freezes both figures; saying so is the difference between a paused
  /// counter and a stuck one.
  private func hoursLine(_ tracker: PanelHoursTracker) -> String {
    let figures = "\(PanelHealthCopy.hours(tracker.totalHours)) in total · "
      + "\(PanelHealthCopy.hours(tracker.hoursSinceStandby)) since the last standby"
    return prefs.oledHoursTracking ? figures : figures + " · counting is paused"
  }
}
