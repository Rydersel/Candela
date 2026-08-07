import Accessibility
import CandelaKit
import CoreGraphics
import SwiftUI

/// SO7's single banner placement: rendered by `SettingsRootView` above the hub
/// root AND above every pushed sub-page, so pages never own banners and a new
/// sub-page cannot forget one. Everything here is keyed to the DESTINATION's
/// display — a preview on another display renders nothing on this one.
///
/// Top to bottom: the countdown surface (answerable or passive, SO6), a
/// settings-origin start failure, unread reapply notices (SO8), the
/// stranded-mute recovery block (SO4/D29 rule 3 — the hub root renders this
/// region, so the recovery is visible in the state it recovers from without any
/// drill-in), and the first-sight line (SO22).
///
/// `@MainActor` for the reason every settings view records: a `View`'s stored
/// and computed properties other than `body` are nonisolated under complete
/// concurrency, and these read main-actor types.
@MainActor
struct BannerRegion: View {
  let state: AppModel.DisplayState

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions

  private var persistenceKey: String { state.display.persistenceKey }
  private var displayID: CGDirectDisplayID { state.display.id }
  private var coordinator: DisplayModeCoordinator { model.displayModes }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults and not observable; this is what
    // re-runs the strand and first-sight checks after a write anywhere.
    let _ = model.prefsRevision
    // Spacing lives on each card, not on this stack: a padded container would
    // keep its padding as dead space when every banner is absent, which is the
    // usual state of this region.
    VStack(spacing: 0) {
      countdownBanner
      startFailureBanner
      reapplyBanner
      strandedMuteBanner
      firstSightBanner
    }
  }

  /// One banner's chrome. Applied per banner so an empty region is exactly
  /// zero-height.
  private func card(@ViewBuilder _ content: () -> some View) -> some View {
    content()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(.quaternary.opacity(0.5))
      )
      .padding(.horizontal, 20)
      .padding(.top, 10)
  }

  // MARK: - Countdown (SO6)

  /// The one place the settings window renders an outstanding preview. Which
  /// FORM it takes is the preview's own `surface`, decided at start: buttons
  /// when this window owns the answer, passive text when the floating window
  /// does — never both (SO6).
  @ViewBuilder private var countdownBanner: some View {
    if let preview = coordinator.preview, preview.displayID == displayID {
      switch preview.surface {
      case .settingsBanner:
        card { AnswerableModeBanner(coordinator: coordinator, preview: preview) }
      case .floatingPanel:
        // Status only while the countdown is armed. Once it is spent (a failed
        // expiry) the floating window is the whole story, and a passive line
        // saying "reverting in 0 seconds" would be false.
        if preview.isCountingDown {
          card {
            Text(verbatim: DisplayModeCopy.passiveCountdown(preview.secondsRemaining))
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
      }
    }
  }

  // MARK: - A selection that never took effect

  /// A settings-origin `begin()` failure. The floating window carries only
  /// panel-origin ones — the settings window stays on screen, so this region
  /// can report its own.
  @ViewBuilder private var startFailureBanner: some View {
    if let failure = coordinator.startFailure, failure.displayID == displayID {
      card {
        VStack(alignment: .leading, spacing: 6) {
          SettingsCaption(DisplayModeCopy.startFailure(failure.reason))
            .help(DisplayModeCopy.startFailureDiagnostic(failure.reason))
          Button("OK") { coordinator.dismissStartFailure() }
        }
      }
    }
  }

  // MARK: - Reapply notices (SO8)

  /// What reapply could not do, said on the display it could not do it to.
  /// An unplug does not take it away; only OK does, through the one dismissal
  /// path every surface shares.
  @ViewBuilder private var reapplyBanner: some View {
    if let report = coordinator.report(for: displayID) {
      card {
        VStack(alignment: .leading, spacing: 6) {
          SettingsCaption(DisplayModeCopy.reapply(
            requested: report.requested, notice: report.notice
          ))
          .modifier(ReapplyDiagnostic(notice: report.notice))
          // Keyed by the report on screen, so OK can only clear the notice the
          // user is reading — and the same call the panel's OK makes.
          Button("OK") { coordinator.dismissReport(forKey: report.key) }
        }
      }
    }
  }

  // MARK: - Stranded mute recovery (SO4)

  /// D29 rule 3 — the explicit unmute affordance, never `.disabled`. This is
  /// the ONLY control that can leave the state, because `toggleMute` refuses
  /// while `isAvailable` is false; it clears the two prefs that make it false
  /// FIRST (D29 rule 2), then unmutes while the display's current mute strategy
  /// is still in force. Rendered here so it is on the hub root AND every
  /// sub-page — the DDC toggle that can cause the strand lives on Advanced, and
  /// the recovery must be visible where the damage was done (SO4).
  @ViewBuilder private var strandedMuteBanner: some View {
    if isStrandedMuted {
      card {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Label("This display is muted in hardware.", systemImage: "speaker.slash")
            Spacer()
            Button("Turn Hardware Control Back On and Unmute") { recoverFromHardwareMute() }
          }
          SettingsCaption("Muting used the display's own mute command, and that command can only be undone over hardware control. This turns hardware control back on for this display and unmutes it.")
        }
      }
    }
  }

  /// Hardware-muted with the volume command turned off: `toggleMute` refuses
  /// while `isAvailable` is false, so nothing but `recoverFromHardwareMute`
  /// leaves this state.
  private var isStrandedMuted: Bool {
    state.volume.isMuted && !state.volume.isAvailable
  }

  /// Clears the availability prefs FIRST, then unmutes. Doing it in the other
  /// order is a silent no-op: `toggleMute` returns `isMuted` unchanged while
  /// `isAvailable` is false, and the user is left believing they unmuted.
  /// `enableMuteUnmute` is deliberately NOT touched — the display was muted
  /// under whatever strategy is in force, and that strategy has to still be in
  /// force for the unmute to send the right wire value.
  private func recoverFromHardwareMute() {
    // Two prefs, two rows, one union — `writeAll`, never a single
    // representative name.
    writer.writeAll([.forceSw, .unavailableDDC]) { prefs in
      prefs.forceSoftware = false
      var tuning = prefs.tuning(for: .volume)
      tuning.unavailableDDC = false
      prefs.setTuning(tuning, for: .volume)
    }
    _ = state.volume.toggleMute()
  }

  // MARK: - First sight (SO22)

  /// An empty pref domain is the honest test for "never configured": every
  /// per-display key — prefs, tuning, saved levels — carries the persistence
  /// key, so a display that has ANY history fails it. Dismissal is
  /// session-scoped and in-memory on purpose; a marker pref would defeat the
  /// very emptiness this line is gated on.
  @ViewBuilder private var firstSightBanner: some View {
    if !model.dismissedFirstSightKeys.contains(persistenceKey),
       !DisplayPrefs.hasAnyStoredValue(forKey: persistenceKey) {
      card {
        HStack(alignment: .firstTextBaseline) {
          Text("First time seeing this display. Its settings start fresh.")
            .foregroundStyle(.secondary)
          Spacer()
          Button("OK") { model.dismissFirstSight(persistenceKey) }
        }
      }
    }
  }
}

/// The answerable countdown banner (SO6 owner = the settings window), plus
/// accessibility contract 8: focus lands on Keep on appearance, an announcement
/// names the new mode and the deadline, and the 10- and 3-second ticks
/// re-announce. Return keeps and Escape reverts while this window is key — the
/// two `keyboardShortcut`s, which exist only while this banner does.
///
/// Deliberately the same words as the floating confirmation window — these are
/// the same statements, and two spellings of one are two things to keep true.
private struct AnswerableModeBanner: View {
  let coordinator: DisplayModeCoordinator
  let preview: DisplayModeCoordinator.Preview

  @AccessibilityFocusState private var keepFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Keep this resolution?")
        .font(.callout.weight(.semibold))
      Text(verbatim: "\(DisplayModeCopy.size(preview.mode)), \(DisplayModeCopy.refresh(preview.mode.refreshHz))")
        .foregroundStyle(.secondary)

      if let failure = preview.failure {
        // Nothing auto-retries a failed resolution. Staying silent here would
        // leave the display on a mode the user never approved, held only
        // until the app exits.
        SettingsCaption(DisplayModeCopy.resolveFailure)
          .help("CoreGraphics error \(failure.cgErrorCode)")
      }
      if preview.isCountingDown {
        Text(verbatim: DisplayModeCopy.countdown(preview.secondsRemaining))
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else if preview.failure != nil {
        SettingsCaption(DisplayModeCopy.expiryAlreadyRan)
      }

      HStack(spacing: 8) {
        // Both answers carry the preview THIS banner is rendering, so a
        // selection landing between the click and the queued operation is
        // refused as stale rather than resolved by an answer given about
        // something else. Keeping writes NO stored mode (SO19).
        Button("Keep") { Task { await coordinator.confirm(preview) } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .accessibilityFocused($keepFocused)
        Button("Revert Now") { Task { await coordinator.revert(preview) } }
          .keyboardShortcut(.cancelAction)
      }
      // Belt to the intent check's braces: while a selection is still landing
      // the banner is about to change, so offering an answer to the old one
      // is pointless even though it is now harmless.
      .disabled(coordinator.isApplying)
    }
    .accessibilityElement(children: .contain)
    .onAppear {
      keepFocused = true
      AccessibilityNotification.Announcement(
        DisplayModeCopy.previewAnnouncement(mode: preview.mode, seconds: preview.secondsRemaining)
      ).post()
    }
    // Driven by the countdown tick this view already re-renders on, comparing
    // against the two contract values — never a timer of its own.
    .onChange(of: preview.secondsRemaining) { _, seconds in
      if seconds == 10 || seconds == 3 {
        AccessibilityNotification.Announcement(DisplayModeCopy.countdown(seconds)).post()
      }
    }
  }
}
