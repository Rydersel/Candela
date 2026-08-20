import CandelaKit
import CoreGraphics
import SwiftUI

/// One display's measurement and data settings, pushed from its OLED Care
/// page (OCR6): everything about COLLECTING rather than dimming, ordered by
/// what each source costs the user; the system permission first, then the
/// permission-free observation, then the consumers. Below the switches, what
/// has been collected so far, and the temporary model comparison (OCR7).
@MainActor
struct OledCareMeasurementPage: View {
  let state: AppModel.DisplayState
  let displays: [(key: String, name: String)]
  let onSwitch: (String) -> Void

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var persistenceKey: String { state.display.persistenceKey }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }

  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }

  var body: some View {
    let _ = model.prefsRevision
    SettingsPageScaffold {
      SubPageHeader(
        title: "Measurement & Data",
        currentKey: persistenceKey,
        displays: displays,
        onSwitch: onSwitch)

      SettingsCardSection {
        measurementControls
        SettingsCardDivider()
        hoursToggle
      }

      collectedSection
      OledModelComparisonSection(persistenceKey: persistenceKey)
    }
  }

  // MARK: - Measurement

  /// The two data sources behind the health page, in the order they cost
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
        // The ONE control on this page that gets its own safe-mode note, and
        // only because it is the one that spends something: the setter above
        // raises the Screen Recording dialog whenever it is switched ON
        // (turning measurement off asks for nothing), so without this
        // a safe-mode session grants a system permission to a sampler that
        // cannot run until the next normal launch, with every visible signal
        // (switch on, no not-granted note) saying it worked. Every other
        // control here is covered by the display page's status row and the
        // overview's pane-level note.
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

    SettingsCardDivider()

    // Last in the group and off by default, and the copy leads with what
    // it does to the screen rather than with what it protects.
    //
    // Every other control in OLED care acts while the user is away or the
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
      .themedSwitch()
      .prefIdentifier(.oledDetectionDimming, persistenceKey: persistenceKey)
    }
  }

  // MARK: - Hours

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
  private var hoursToggle: some View {
    SettingRow("Counted while the display is awake and not mirrored, and kept per display even when it is unplugged. A display switched off at the monitor itself can still be counted, because macOS reports a blanked display as awake.") {
      Toggle("Count hours of use", isOn: Binding(
        get: { prefs.oledHoursTracking },
        set: { on in writer.write(.oledHoursTracking) { $0.oledHoursTracking = on } }
      ))
      .themedSwitch()
      .prefIdentifier(.oledHoursTracking, persistenceKey: persistenceKey)
    }
  }

  // MARK: - Collected so far

  @ViewBuilder private var collectedSection: some View {
    let summary = model.oledCare.healthSummary(for: persistenceKey)
    let tracker = model.oledCare.wearTracker(for: persistenceKey)
    let buckets = tracker.secondsByBucket()
    let hasHistogram = buckets.contains(where: { $0 > 0 })
    if hasHistogram || prefs.oledTelemetry {
      SettingsCardSection(title: "Collected so far") {
        if hasHistogram {
          usageHistogram(tracker: tracker, buckets: buckets)
        }
        if hasHistogram, prefs.oledTelemetry {
          SettingsCardDivider()
        }
        if prefs.oledTelemetry {
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
