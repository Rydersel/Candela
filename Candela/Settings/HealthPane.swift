import AppKit
import CandelaKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// The Health pillar's settings-side front door (SC4): what each display's
/// record says, and every control that decides what goes into it.
///
/// The cards at the top are summaries, never instruments. The reading surface
/// is the Heat Map window, which stays content-sized (OCR-A1 stands), and
/// every card that has a record to show opens it.
///
/// Below the cards is what used to be OLED Care's Measurement & Data page,
/// moved here whole when SC5 retired it: the measurement toggle and its Screen
/// Recording consent site, the permission-free observation, the hours counter,
/// what has been collected so far, and the temporary model comparison. Nothing
/// was re-derived on the way over; every control keeps its `PrefName` write
/// through `SettingsActions` (D27).
///
/// **Measurement and record only, never a dimming behavior** (Ryder,
/// 2026-08-20). The static-region dim arrived here with that page and went
/// back out to the display's OLED Care page, which is where everything that
/// dims lives (OCR2); it depends on the two measurement settings above and
/// says so from there. Anything that changes what the screen looks like
/// belongs on that page, not this one.
///
/// **Per display, not global.** Every pref written here is per-display, as it
/// was on the page it came from (SC10), so this pane names the display it is
/// acting on and switches between them rather than quietly promoting a
/// per-display setting to an app-level one. The cards above are the scope's
/// visible half: one per display, each carrying that display's own state.
///
/// `@MainActor` is load-bearing for `DisplayDetailView`'s reason: a `View`'s
/// stored and computed properties are nonisolated under complete concurrency
/// checking, and these read `AppModel` from outside `body`.
@MainActor
struct HealthPane: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  /// The display the controls below the cards act on, or nil to follow the
  /// connected set. Deliberately not seeded once at appearance: a key pinned
  /// on arrival would outlive the display's unplug, and resolving the default
  /// on every render means a departure falls back to a connected display
  /// instead of leaving the section acting on nothing.
  @State private var scopedKey: String?

  var body: some View {
    // Prefs are plain `UserDefaults` and not observable, so this is the only
    // thing that re-reads them after a write from here or from anywhere else.
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SettingsPageHeader(
        title: "Health",
        subtitle: "A display does not tell you what it has been through. "
          + "Health is where Candela's record is read: hours of use, and where on the screen the light has fallen."
      )

      // The exceptional state leads, before the cards, which is the OLED Care
      // overview's placement rule and for a sharper reason here: every figure
      // below is stored history, and the hours switch reads ON for a counter
      // that is not counting.
      if model.isSafeMode {
        safeModeNote
      }

      displaysSection

      if let scoped {
        measurementSection(for: scoped)
        collectedSection(for: scoped.display.persistenceKey)
        OledModelComparisonSection(persistenceKey: scoped.display.persistenceKey)
      }
    }
    // The care cross-link's one-shot scope handoff (SC4). Adopted here rather
    // than observed: `pendingHealthScope` is set by a link on ANOTHER pane, so
    // this pane is never on screen when it is written and every reveal reaches
    // it through a fresh appearance. Cleared on adoption, so a later visit by
    // the sidebar keeps the pane's own state.
    .onAppear {
      guard let pending = actions.pendingHealthScope else { return }
      actions.pendingHealthScope = nil
      // A key that no longer names a connected display is dropped rather than
      // stored: `scoped` would fall back anyway, but a stale key parked in
      // `scopedKey` would move the switcher by itself when that display came
      // back.
      if displays.contains(where: { $0.display.persistenceKey == pending }) {
        scopedKey = pending
      }
    }
  }

  // MARK: - Safe Mode

  /// D11's visibility rule on the pane that most needs it. `OledCareCoordinator.start`
  /// returns at its safe-mode guard before the driver loop is built, so nothing
  /// on this pane is measuring, sampling or counting, while the cards' figures
  /// and the hours switch below both look live.
  ///
  /// Pane-level rather than per-card: `OledCareCardCopy.measurementLine` returns
  /// the bare hours string under safe mode by design (its own test pins that),
  /// and the OLED Care overview's card prepends the pause itself. Saying it once
  /// at the top covers the cards, the hours switch and the histogram together,
  /// which no per-control note reaches.
  private var safeModeNote: some View {
    SettingsCard {
      // Surfaceless: the card is the surface. Same shape as the OLED Care
      // overview's note, same sentence, from `SafeModeCopy`.
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

  /// External displays only: nothing measures the built-in, so it never
  /// appears here or in the switcher.
  private var displays: [AppModel.DisplayState] { model.displays }

  /// The chosen display, or the first connected one. Falling back rather than
  /// going empty is what keeps the controls reachable after the chosen display
  /// is unplugged.
  private var scoped: AppModel.DisplayState? {
    displays.first { $0.display.persistenceKey == scopedKey } ?? displays.first
  }

  private func name(_ state: AppModel.DisplayState) -> String {
    DisplayOrdering.title(
      friendlyName: DisplayPrefs(persistenceKey: state.display.persistenceKey).friendlyName,
      hardwareName: state.display.name)
  }

  // MARK: - Displays

  /// One card per display, every display, enrollment notwithstanding (SC4).
  /// Several cards rather than one section, so the sentence under them stands
  /// on the canvas instead of inside a card, which is the OLED Care overview's
  /// rhythm and the shape a reader arrives from.
  private var displaysSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      SettingsSectionTitle(text: "Displays")

      // Once for the page, not once per card: repeating it under each would read
      // as a different file per display.
      SettingsRowNote(verbatim: ProvenanceCopy.note)

      // Keyed by `persistenceKey`, never `DisplayState.id`: IDs reassign
      // across a replug (measured, the MAG and the Dell swapped across one
      // dock cycle), and a `ForEach` keyed on a reused id hands the OLD view
      // instance to the OTHER display's card.
      ForEach(displays, id: \.display.persistenceKey) { state in
        HealthDisplayCard(state: state)
      }

      if displays.isEmpty {
        // On a card of its own, because a bare sentence on the canvas where
        // the cards would be reads as a page that failed to load.
        SettingsCard {
          SettingsCaption("Connect an external display to start a record for it. Nothing is measured on the built-in display.")
        }
      }
    }
  }

  // MARK: - Measurement

  /// The retired page's controls, with the display they act on named at the
  /// top. The switcher's contract is `SubPageHeader`'s (SO23): a persistence
  /// key out, and nothing here reaching into navigation state it does not own.
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

      // Only where there is a choice to be misread. With one display attached
      // the controls' own "this display" is unambiguous, and the sentence
      // would be answering a question nobody asked.
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

  /// The wear signal's first reader (OC20 built it; nothing displayed it):
  /// how long this display has run at each brightness, and the share of
  /// MASK-COULD-APPLY time spent in a protective dim, which is OC17's own gate
  /// number. Both are counts of seconds; neither is a model.
  ///
  /// The two do NOT share a denominator, ruled 2026-08-18: the bars cover every
  /// state, the percentage covers only the time the mask could act in. That is
  /// what the caption below is for, and it is the reason the percentage is not
  /// rewritten to match the bars.
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
      // Only where both numbers are on screen: with no percentage beside the
      // bars there are not two readings to tell apart.
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

/// A display's record at a glance, and the doorway to the window that reads it
/// properly (SC4). Not a navigation row like the OLED Care overview's card:
/// this one carries an explicit button, because the destination is a separate
/// window rather than a push and a whole-card tap that opens a window is a
/// surprise the overview's chevron does not promise.
///
/// A display with no record says why, in the one shape SC4 allows: measurement
/// currently runs on displays enrolled in OLED care, stated as the fact it is,
/// with the way there beside it. Decoupling measurement from enrollment is
/// filed as its own work; until it lands, hiding the coupling would be the
/// dishonest option.
@MainActor
private struct HealthDisplayCard: View {
  let state: AppModel.DisplayState

  @State private var justCopied = false
  /// Cancelled and replaced on every copy, so a second click restarts the two
  /// seconds instead of letting the first click's timer clear the label early.
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
              // Repeated verbatim on every card otherwise, which tells a
              // VoiceOver user which button but not which display.
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
            // The visible title flips to "Copied", so the label flips with it or
            // VoiceOver never hears the confirmation.
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

  /// The kit's own encoder, so an exported file is byte-identical to any other
  /// copy of the same record and the verifier answers the same on all of them.
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

  /// The card's words. An un-enrolled display states the coupling; every other
  /// state is `OledCareCardCopy`'s line, the same one the OLED Care overview's
  /// card carries, so the two surfaces cannot report one display's readings
  /// differently.
  ///
  /// The dim state the overview prepends is deliberately absent: what is
  /// dimming right now is OLED Care's subject, and this pane is about what has
  /// been recorded.
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

/// The two data sources behind a display's record, in the order they cost
/// the user something: the one that needs a system permission first, then the
/// one that needs none.
///
/// Moved here from `OledCareMeasurementPage` when SC5 retired it. The copy,
/// the ordering and the write paths are that page's exactly; what changed is
/// which surface hosts them.
@MainActor
private struct MeasurementControls: View {
  let persistenceKey: String

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }

  var body: some View {
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
            // One of the two places in the app that raise the Screen
            // Recording prompt; the guided setup flow's measured choice is
            // the other. The sampler itself is preflight-only on purpose: a
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
        .themedSwitch()
        .prefIdentifier(.oledTelemetry, persistenceKey: persistenceKey)
        // What "the resolution of this grid" means, at the size it means it.
        PanelGridMark()
        // The ONE control on this pane that gets its own safe-mode note, and
        // only because it is the one that spends something: the setter above
        // raises the Screen Recording dialog whenever it is switched ON
        // (turning measurement off asks for nothing), so without this
        // a safe-mode session grants a system permission to a sampler that
        // cannot run until the next normal launch, with every visible signal
        // (switch on, no not-granted note) saying it worked.
        //
        // What covers everything else on this pane is the pane-level note at
        // the top, NOT the cards: `OledCareCardCopy.measurementLine` returns
        // the bare hours string under safe mode (pinned by
        // `HealthCardCopyTests.safeModeSaysNothingAboutReadings`) and this
        // pane's card adds no prefix of its own. An earlier version of this
        // comment claimed the cards said it, which was a justification a test
        // contradicted.
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

    SettingsCardDivider()

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
      .themedSwitch()
      .prefIdentifier(.oledWindowObservation, persistenceKey: persistenceKey)
    }
  }
}

/// "Hours of use", never "panel hours", in every visible string (SO14: the
/// hardware is a display; "panel" survives only in type names like
/// `PanelHoursTracker` and in comments).
///
/// The second sentence is the honest limit of the number: macOS reports
/// a DPMS-blanked panel as awake, at full resolution, with no reconfiguration,
/// so a panel held in soft standby is indistinguishable from a lit one.
/// "can still be counted" is deliberately hedged. Whether the monitor's own
/// power button reaches soft standby or instead deasserts hot-plug detect
/// (a real departure, handled correctly) is untested per monitor.
/// Display sleep, system sleep and mirroring are all handled correctly, so
/// don't let the caption imply otherwise in either direction.
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
      .prefIdentifier(.oledHoursTracking, persistenceKey: persistenceKey)
    }
  }
}
