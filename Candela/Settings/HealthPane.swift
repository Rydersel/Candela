import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// The Health pillar's settings-side front door: what each display's
/// record says, and the controls that decide what goes into it. The cards are
/// summaries; the Heat Map window is the reading surface.
///
/// Measurement and record only, never a dimming behavior (settled 2026-08-20):
/// anything that changes what the screen looks like belongs on the display's
/// OLED Care page. Every pref written here is per-display.
///
/// `@MainActor`: a `View`'s stored and computed properties are nonisolated
/// under complete concurrency checking, and these read `AppModel` outside `body`.
@MainActor
struct HealthPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  /// The display the controls below act on, or nil to follow the connected set.
  /// Not seeded at appearance: a pinned key outlives the display's unplug, while
  /// resolving per render falls back to a connected display.
  @State private var scopedKey: String?

  var body: some View {
    // Prefs are plain `UserDefaults` and not observable, so this is the only
    // thing that re-reads them after a write.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SettingsPageHeader(
        title: "Health",
        subtitle: "A display does not tell you what it has been through. "
          + "Health is where Candela's record is read: hours of use, and where on the screen the light has fallen."
      )

      // Leads the cards: every figure below is stored history, and the hours
      // switch reads ON for a counter that is not counting.
      if model.isSafeMode {
        safeModeNote
      }

      displaysSection

      if let scoped {
        measurementSection(for: scoped)
        collectedSection(for: scoped.display.persistenceKey)
        // Soak-only instrument, kept off the shipped window until the
        // exposure-model verdict is recorded; the key is an escape hatch.
        if DisplayPrefs(persistenceKey: scoped.display.persistenceKey).showModelComparison {
          OledModelComparisonSection(persistenceKey: scoped.display.persistenceKey)
        }
      }
    }
    // One-shot scope handoff from a link on another pane. Cleared on
    // adoption, so a later visit from the sidebar keeps this pane's own state.
    .onAppear {
      guard let pending = actions.pendingHealthScope else { return }
      actions.pendingHealthScope = nil
      // A key naming no connected display is dropped: parked in `scopedKey` it
      // would move the switcher by itself when that display came back.
      if displays.contains(where: { $0.display.persistenceKey == pending }) {
        scopedKey = pending
      }
    }
  }

  // MARK: - Safe Mode

  /// Safe Mode's visibility rule. `OledCareCoordinator.start` returns at its safe-mode
  /// guard, so nothing here is measuring while the figures and the hours switch
  /// look live. Pane-level, because no per-control note covers the cards, the
  /// switch and the histogram at once.
  private var safeModeNote: some View {
    SettingsCard {
      // Surfaceless: the card is the surface.
      SettingsNotice(drawsSurface: false) {
        Text(verbatim: SafeModeCopy.careSessionNotice)
          .font(.callout.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
        SettingsCaption("Shift was held at launch. The figures below are what was recorded before this session, and the settings you make here are saved for the next normal launch.")
      }
      .padding(.vertical, 2)
    }
  }

  // MARK: - Scope

  /// External displays only: nothing measures the built-in.
  private var displays: [AppModel.DisplayState] { model.displays }

  /// The chosen display, or the first connected one; falling back rather than
  /// going empty keeps the controls reachable after an unplug.
  private var scoped: AppModel.DisplayState? {
    displays.first { $0.display.persistenceKey == scopedKey } ?? displays.first
  }

  private func name(_ state: AppModel.DisplayState) -> String {
    DisplayOrdering.title(
      friendlyName: DisplayPrefs(persistenceKey: state.display.persistenceKey).friendlyName,
      hardwareName: state.display.name)
  }

  // MARK: - Displays

  /// One card per display, enrollment notwithstanding. Separate cards so
  /// the sentence under them stands on the canvas rather than inside a card.
  private var displaysSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsSectionTitle(text: "Displays")

      // Once for the page: repeated under each card it would read as a
      // different file per display.
      SettingsRowNote(verbatim: ProvenanceCopy.note)

      // Keyed by `persistenceKey`, never `DisplayState.id`: IDs reassign across
      // a replug (measured, the MAG and the Dell swapped over one dock cycle),
      // and a reused id hands the OLD view instance to the OTHER card.
      ForEach(displays, id: \.display.persistenceKey) { state in
        HealthDisplayCard(state: state)
      }

      if displays.isEmpty {
        // Carded: a bare sentence where the cards would be reads as a page
        // that failed to load.
        SettingsCard {
          SettingsCaption("Connect an external display to start a record for it. Nothing is measured on the built-in display.")
        }
      }
    }
  }

  // MARK: - Measurement

  /// The measurement controls, scoped to one named display. The switcher's
  /// contract is `SubPageHeader`'s: a persistence key out, and nothing
  /// here reaching into navigation state it does not own.
  @ViewBuilder private func measurementSection(for state: AppModel.DisplayState) -> some View {
    let key = state.display.persistenceKey
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        SettingsSectionTitle(text: "Measurement")
        Spacer(minLength: 12)
        if displays.count > 1 {
          Picker("Display", selection: Binding(get: { key }, set: { scopedKey = $0 })) {
            ForEach(displays, id: \.display.persistenceKey) { candidate in
              // A display's name, never a lookup key.
              Text(verbatim: name(candidate)).tag(candidate.display.persistenceKey)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .fixedSize()
          .accessibilityLabel("Display")
        }
      }

      // Only where there is a choice to be misread: with one display attached
      // the controls' own "this display" is unambiguous.
      if displays.count > 1 {
        SettingsCaption(
          verbatim: "These settings are \(name(state))'s alone; every display is measured on its own."
        )
        .text
        .font(.caption)
        .foregroundStyle(SettingsTheme.faintColor)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 4)
      }

      SettingsCard {
        VStack(alignment: .leading, spacing: 0) {
          // Heads the card because it governs every control under it: observation
          // and hours default ON, but `reconcileEnrollment` drops un-enrolled keys,
          // so three switches can read ON for a display nothing measures. The
          // prefs are legitimately set ahead of enrollment, so nothing is disabled.
          if !DisplayPrefs(persistenceKey: key).oledCareEnrolled {
            VStack(alignment: .leading, spacing: 8) {
              OledInlineNote(Text(verbatim: "Measurement currently runs on displays enrolled in OLED care, and \(name(state)) is not enrolled. These settings are saved and start applying when it is."))
              Button("Open OLED Care") { actions.reveal(.pane(.oledCare)) }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .accessibilityLabel(Text(verbatim: "Open OLED Care for \(name(state))"))
            }
            .padding(.vertical, 8)
            SettingsCardDivider()
          }
          MeasurementControls(persistenceKey: key)
          SettingsCardDivider()
          HoursToggle(persistenceKey: key)
        }
      }
    }
  }

  // MARK: - Collected so far

  @ViewBuilder private func collectedSection(for persistenceKey: String) -> some View {
    let summary = model.oledCare.healthSummary(for: persistenceKey)
    let tracker = model.oledCare.wearTracker(for: persistenceKey)
    let buckets = tracker.secondsByBucket()
    let hasHistogram = buckets.contains(where: { $0 > 0 })
    let telemetry = DisplayPrefs(persistenceKey: persistenceKey).oledTelemetry
    if hasHistogram || telemetry {
      SettingsCardSection(title: "Collected so far") {
        if hasHistogram {
          usageHistogram(tracker: tracker, buckets: buckets)
        }
        if hasHistogram, telemetry {
          SettingsCardDivider()
        }
        if telemetry {
          OledTelemetryTicker(
            sampleCount: summary.sampleCount,
            lastSample: summary.lastSample,
            grantPresent: CGPreflightScreenCaptureAccess())
            .padding(.vertical, 6)
        }
      }
    }
  }

  /// How long this display ran at each brightness, and the share of
  /// MASK-COULD-APPLY time spent in a protective dim.
  ///
  /// The two do NOT share a denominator (ruled 2026-08-18): the bars cover every
  /// state, the percentage only the time the mask could act in. That is what the
  /// caption is for, and why the percentage is not rewritten to match the bars.
  private func usageHistogram(tracker: WearSignalTracker, buckets: [Double]) -> some View {
    let fraction = tracker.wearWeightableFraction
    return VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        Text("Time at brightness")
          .font(.caption)
          .foregroundStyle(SettingsTheme.faintColor)
        Spacer(minLength: 8)
        if let fraction, fraction > 0 {
          Text(verbatim: "\(Int((fraction * 100).rounded()))% of tracked time in a protective dim")
            .font(.caption)
            .foregroundStyle(SettingsTheme.faintColor)
        }
      }
      OledBrightnessHistogram(secondsByBucket: buckets)
      // Only with the percentage on screen: otherwise there are not two
      // readings to tell apart.
      if let fraction, fraction > 0 {
        Text(verbatim: OledCareCopy.wearFractionScope)
          .font(.caption)
          .foregroundStyle(SettingsTheme.faintColor)
      }
    }
    .padding(.vertical, 6)
  }
}

// MARK: - One display's card

/// A display's record at a glance, with an explicit button to the Heat Map:
/// the destination is a separate window, which a whole-card tap does not
/// promise. A display with no record names the enrollment coupling rather than
/// hiding it; decoupling measurement from enrollment is filed as its own work.
@MainActor
private struct HealthDisplayCard: View {
  let state: AppModel.DisplayState

  @State private var justCopied = false
  /// Cancelled and replaced on every copy, so a second click restarts the two
  /// seconds instead of inheriting the first click's timer.
  @State private var confirmationTask: Task<Void, Never>?
  @State private var saveError: String?

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var persistenceKey: String { state.display.persistenceKey }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }

  private var name: String {
    DisplayOrdering.title(friendlyName: prefs.friendlyName, hardwareName: state.display.name)
  }

  var body: some View {
    let summary = model.oledCare.healthSummary(for: persistenceKey)
    let recording = prefs.oledCareEnrolled
    SettingsCard {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .center, spacing: 14) {
          PanelExposureMiniSurface(
            cells: summary.cells,
            displayID: state.display.id,
            showsMap: recording && summary.confidence == .measured)
          VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: name)
              .font(.system(size: 15, weight: .semibold, design: .rounded))
              .foregroundStyle(SettingsTheme.titleColor)
              .lineLimit(1)
              .truncationMode(.middle)
            Text(verbatim: statusLine(summary: summary, recording: recording))
              .font(.callout)
              .foregroundStyle(SettingsTheme.bodyColor)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 12)
          if recording {
            Button("Open Heat Map") { actions.openDisplayHealth(persistenceKey) }
              .buttonStyle(SettingsSecondaryButtonStyle())
              // Otherwise every card speaks the same label, naming the button
              // but not the display.
              .accessibilityLabel(Text(verbatim: "Open Heat Map for \(name)"))
          } else {
            Button("Open OLED Care") { actions.reveal(.pane(.oledCare)) }
              .buttonStyle(SettingsSecondaryButtonStyle())
              .accessibilityLabel(Text(verbatim: "Open OLED Care for \(name)"))
          }
        }
        .padding(.vertical, 2)

        // On every card, enrolled or not: an un-enrolled display still has an
        // identity and a checkup history to hand on.
        SettingsCardDivider()
        HStack(spacing: 10) {
          Button(ProvenanceCopy.export) { exportProvenance() }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .accessibilityLabel(Text(verbatim: "Export provenance for \(name)"))
          Button(justCopied ? ProvenanceCopy.copied : ProvenanceCopy.copySummary) { copySummary() }
            .buttonStyle(SettingsSecondaryButtonStyle())
            // The visible title flips to "Copied", so the label flips with it
            // or VoiceOver never hears the confirmation.
            .accessibilityLabel(
              Text(verbatim: justCopied
                ? "Copied provenance summary for \(name)"
                : "Copy provenance summary for \(name)"))
          Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
      }
    }
    .alert(
      ProvenanceCopy.exportFailed,
      isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
    ) {
      Button(ProvenanceCopy.acknowledge) { saveError = nil }
    } message: {
      Text(verbatim: saveError ?? "")
    }
  }

  /// The kit's own encoder, so two exports of one record are byte-identical and
  /// the verifier answers the same on both.
  private func exportProvenance() {
    let record = ProvenanceExporter.record(for: state, model: model)
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = ProvenanceEnvelope.exportFileName(for: record)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try ProvenanceEnvelope.encoded(try ProvenanceEnvelope(record: record)).write(to: url, options: .atomic)
    } catch {
      // A save that did not happen has to say so; silence looks like a file.
      saveError = error.localizedDescription
    }
  }

  private func copySummary() {
    let record = ProvenanceExporter.record(for: state, model: model)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(ProvenanceSummaryText.render(record), forType: .string)
    withAnimation(Motion.notice(reduceMotion: reduceMotion)) { justCopied = true }
    confirmationTask?.cancel()
    confirmationTask = Task {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      withAnimation(Motion.notice(reduceMotion: reduceMotion)) { justCopied = false }
    }
  }

  /// Shares `OledCareCardCopy` with the OLED Care overview, so the two surfaces
  /// cannot report one display's readings differently. The dim state the
  /// overview prepends is left off: this pane is about what was recorded.
  private func statusLine(summary: PanelHealthSummary, recording: Bool) -> String {
    guard recording else {
      return "Not measured yet. Measurement currently runs on displays enrolled in OLED care."
    }
    return OledCareCardCopy.measurementLine(
      hours: PanelHealthCopy.hours(model.oledCare.hoursTracker(for: persistenceKey).totalHours),
      summary: summary,
      safeMode: model.isSafeMode,
      grantPresent: CGPreflightScreenCaptureAccess())
  }
}

// MARK: - The moved controls

/// The two data sources behind a display's record, ordered by what they cost:
/// the one that needs a system permission first, then the one that needs none.
@MainActor
private struct MeasurementControls: View {
  let persistenceKey: String

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }

  /// Reads the comparison record because its paired-reading clock is the only
  /// per-sample timestamp the coordinator keeps. A missing grant has its own note.
  ///
  /// The stall window, not the liveness one: this note accuses macOS of taking
  /// the grant. Its copy says "over 10 minutes" and must keep agreeing.
  private var isSamplingStalled: Bool {
    guard prefs.oledTelemetry, !model.isSafeMode, CGPreflightScreenCaptureAccess(),
      let last = model.oledCare.modelComparison(for: persistenceKey).lastPair
    else { return false }
    return Date().timeIntervalSince(last) > OledCareCadence.stallWarningSeconds
  }

  var body: some View {
    // Spec §4's prompt copy, verbatim, so the reason is on screen BEFORE
    // macOS's own dialog, which can only say "record the contents of your
    // screen". The product name is interpolated: the working name is not final.
    SettingRow(caption: SettingsCaption("\(AppInfo.productName) measures how bright each part of the display is, at about the resolution of this grid, once a minute. Nothing is recorded or stored as an image, and nothing leaves this Mac.")) {
      VStack(alignment: .leading, spacing: 8) {
        Toggle("Measure how bright each part of this display is", isOn: Binding(
          get: { prefs.oledTelemetry },
          set: { on in
            // One of two sites that raise the Screen Recording prompt (guided
            // setup is the other); the sampler itself is preflight-only, so no
            // background loop raises a TCC dialog unexplained.
            //
            // The pref is written whether or not the grant arrives: macOS
            // returns false from the request that merely SHOWS the dialog, so
            // gating the switch on the return value leaves it stuck off.
            if on { _ = CGRequestScreenCaptureAccess() }
            writer.write(.oledTelemetry) { $0.oledTelemetry = on }
          }
        ))
        .themedSwitch()
        .accessibilityLabel("Measure how bright each part of this display is")
        .prefIdentifier(.oledTelemetry, persistenceKey: persistenceKey)
        // What "the resolution of this grid" means, at the size it means it.
        PanelGridMark()
        // The one control here with its own safe-mode note, because it is the
        // one that spends something: switching it ON raises the Screen Recording
        // dialog, so without this a safe-mode session grants a permission to a
        // sampler that cannot run until the next normal launch, with every
        // visible signal saying it worked.
        //
        // Safe Mode WINS over the grant note rather than joining it: both are
        // true, but two reasons for one silence read as a bug.
        if model.isSafeMode {
          OledInlineNote(Text("Safe Mode is on for this session, so nothing is being measured whatever this is set to, and Screen Recording is not needed until the next normal launch."))
        } else if prefs.oledTelemetry, !CGPreflightScreenCaptureAccess() {
          OledInlineNote(Text("macOS has not granted Screen Recording, so no readings are being taken. Grant it in System Settings > Privacy & Security > Screen Recording."))
        } else if isSamplingStalled {
          OledInlineNote(Text("No reading in over 10 minutes while measurement is on. If this persists, macOS may have dropped the Screen Recording grant after an update to the app; check System Settings > Privacy & Security > Screen Recording."))
        }
      }
    }

    SettingsCardDivider()

    // The battery clause is stated ONCE, on the last row of the group:
    // `OledCareCoordinator.samplingQualifies` gates BOTH toggles on the same
    // signal, so below the threshold both counters freeze. The number mirrors
    // `OledCareSignalSources.lowBatteryPercent` (20, at or below, on battery
    // only); "on low battery" would not say whether a frozen counter is the
    // gate or a bug.
    SettingRow("Needs no permission: reads each on-screen window's position and the name of the app that owns it, never window titles and never their contents. This is what puts an app's name next to an area of the display. Both measurements pause while the Mac is running on battery at 20% charge or less.") {
      Toggle("Note which apps are on this display", isOn: Binding(
        get: { prefs.oledWindowObservation },
        set: { on in writer.write(.oledWindowObservation) { $0.oledWindowObservation = on } }
      ))
      .themedSwitch()
      .accessibilityLabel("Note which apps are on this display")
      .prefIdentifier(.oledWindowObservation, persistenceKey: persistenceKey)
    }
  }
}

/// "Hours of use", never "panel hours", in every visible string.
///
/// The caption's second sentence is the honest limit of the number: macOS
/// reports a DPMS-blanked panel as awake at full resolution, so soft standby is
/// indistinguishable from a lit panel. Whether a monitor's own power button
/// reaches soft standby or deasserts hot-plug detect (a real departure, handled
/// correctly) is untested per monitor. Display sleep, system sleep and mirroring
/// are all handled correctly, so don't let the caption imply otherwise.
@MainActor
private struct HoursToggle: View {
  let persistenceKey: String

  @Environment(SettingsActions.self) private var actions

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }

  var body: some View {
    SettingRow("Counted while the display is awake and not mirrored, and kept per display even when it is unplugged. A display switched off at the monitor itself can still be counted, because macOS reports a blanked display as awake.") {
      Toggle("Count hours of use", isOn: Binding(
        get: { prefs.oledHoursTracking },
        set: { on in writer.write(.oledHoursTracking) { $0.oledHoursTracking = on } }
      ))
      .themedSwitch()
      .accessibilityLabel("Count hours of use")
      .prefIdentifier(.oledHoursTracking, persistenceKey: persistenceKey)
    }
  }
}
