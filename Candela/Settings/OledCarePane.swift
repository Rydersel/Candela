import CandelaKit
import SwiftUI

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

  var body: some View {
    // Prefs are plain `UserDefaults` and not observable, so this is the only
    // thing that re-reads them after a write from anywhere — including the
    // per-display sections below, which write through `DisplayPrefWriter`.
    let _ = model.prefsRevision
    Form {
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
  /// changes what a control means. The dimming loop and the hours counter do
  /// not run in a safe-mode session; the two chrome switches are explicit
  /// writes to system settings and still work, so this must not claim the pane
  /// is inert.
  private var safeModeNote: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        // Symbol AND text — never state by colour alone.
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
        Text("Safe Mode is on for this session, so no display is being dimmed and no hours of use are being counted.")
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

        SettingsCaption("Both settings belong to macOS rather than to \(AppInfo.productName): they apply to every display, and enrolling a display never changes them on its own.")
      } else {
        SettingsCaption("These settings are not available yet. Reopen this window in a moment.")
      }
    } header: {
      Text("Screen Chrome").settingsHeading()
    }
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
        statusRow
        idleControls
        lockControls
        blackoutControls
        unfocusedControls
        hoursControls
      }
    } header: {
      Text(verbatim: name).settingsHeading()
    }
  }

  // MARK: - Status

  /// What the engine is doing right now. `dimStates` is the coordinator's own
  /// published state, never a second opinion computed here — and a mirrored
  /// display's "paused" reading is the one spec §5 requires to be visible
  /// (OC13).
  private var statusRow: some View {
    LabeledContent("Status") {
      Text(statusText)
        .foregroundStyle(.secondary)
    }
  }

  private var statusText: LocalizedStringKey {
    if model.isSafeMode { return "Paused for this session (Safe Mode)" }
    // Exhaustive, so a new engine state is a compile error here rather than a
    // blank row.
    switch model.oledCare.dimStates[persistenceKey] {
    case .active: return "Not dimming"
    case .idleDim: return "Dimmed: the display has been idle"
    case .blackout: return "Screen off: the display has been idle"
    case .lockDim: return "Dimmed: the screen is locked"
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
      label: "Dim by",
      caption: "\(AppInfo.productName) draws a dark overlay over the display; the display's own brightness setting is untouched, and any key or click restores the picture immediately.",
      draft: $idleLevelDraft,
      value: prefs.oledIdleDimLevel,
      accessibilityName: "Idle dim amount"
    ) { level in
      writer.write(.oledIdleDimLevel) { $0.oledIdleDimLevel = level }
    }
  }

  // MARK: - Lock dim

  private var lockControls: some View {
    SettingRow("Uses the same amount as the idle dim; any key or click lifts it while the screen stays locked, and it comes back after the idle time above.") {
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
        label: "Dim by",
        caption: "Usually lighter than the idle dim: the display is still in view.",
        draft: $unfocusedLevelDraft,
        value: prefs.oledUnfocusedDimLevel,
        accessibilityName: "Unfocused dim amount"
      ) { level in
        writer.write(.oledUnfocusedDimLevel) { $0.oledUnfocusedDimLevel = level }
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

    // Both numbers live here, always — the since-standby figure is the one the
    // note below is about, and a dismissed note must not be the only place it
    // can be read. With counting off the numbers stay on screen (they are the
    // accumulated total, not a live reading) but they stop moving, and two
    // frozen figures with nothing saying so read as a broken counter.
    LabeledContent("Hours of use") {
      Text(verbatim: hoursLine(tracker))
        .foregroundStyle(.secondary)
    }

    if tracker.shouldShowStandbyNote {
      SettingRow(caption: SettingsCaption("Most OLED displays run their own compensation cycle when they go into standby, and skip it while they are in use. Anything that puts the display to sleep counts: the monitor's own power button, or leaving the Mac idle.")) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("This display has not been in standby for a while.")
          Spacer(minLength: 0)
          Button("Dismiss") {
            tracker.dismissStandbyNote()
            hoursRevision &+= 1
          }
        }
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

  /// The dim-amount row, shared by the idle and unfocused levels so the two
  /// cannot drift into different shapes. The range comes from
  /// `OledDimConfig.levelRange` — the config sanitises to exactly that, and a
  /// slider that could express more would be a slider that lies.
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
          in: OledDimConfig.levelRange,
          // 10% steps: SwiftUI draws a tick per step on macOS, and a finer
          // step turned the row into a comb of seventeen marks. Ten percent is
          // also the smallest change anyone can see on a dim overlay.
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

  private static func percent(_ level: Double) -> String {
    "\(Int((level * 100).rounded()))%"
  }

  /// English only (D25), and singular matters: the idle threshold's floor is
  /// one minute, so "1 minutes" would be on screen by default on any display
  /// tuned that low.
  private static func minutesPhrase(_ value: Int) -> String {
    value == 1 ? "1 minute" : "\(value) minutes"
  }

  /// One decimal below ten hours, whole hours above it. A freshly enrolled
  /// display otherwise reads "0 hours" for its first hour, which looks like a
  /// counter that is not running. No singular case: it can only be reached
  /// above ten hours.
  private static func hoursPhrase(_ hours: Double) -> String {
    guard hours.isFinite, hours > 0 else { return "0 hours" }
    if hours < 10 { return String(format: "%.1f hours", hours) }
    return "\(Int(hours.rounded())) hours"
  }
}
