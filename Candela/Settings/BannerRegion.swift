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
  /// SO6 is ONE answerable surface, and this region has two placements: while a
  /// sub-page is pushed, the hub root behind it is still in the stack and still
  /// rendering. Both matched the same `displayID`, so a settings-owned preview
  /// started from a sub-page drew two answerable banners at once: two Return
  /// and Escape equivalents for one question, and two appearance announcements
  /// (accessibility contract 8). The pushed page owns the answer whenever there
  /// is one, so the root placement gives it up while the stack is non-empty.
  /// Passive content is unaffected: a notice or a recovery block on both is
  /// what SO7 asks for.
  var ownsAnswerableCountdown = true

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
        if ownsAnswerableCountdown {
          card { AnswerableModeBanner(coordinator: coordinator, preview: preview) }
        }
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
            .accessibilityLabel("OK")
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
            .accessibilityLabel("OK")
        }
      }
    }
  }

  // MARK: - Stranded mute recovery (SO4)

  /// D29 rule 3 — the explicit unmute affordance, never `.disabled`. This is
  /// the ONLY control that can leave the state, because every other route is
  /// gone in exactly this state; it clears the prefs that closed those routes
  /// FIRST (D29 rule 2), then unmutes while the display's current mute strategy
  /// is still in force. Rendered here so it is on the hub root AND every
  /// sub-page — the DDC toggle that can cause the strand lives on Advanced, and
  /// the recovery must be visible where the damage was done (SO4).
  ///
  /// TWO causes reach this banner and they need different sentences, for the
  /// reason the greyed-slider tooltip needed them: copy that names the wrong
  /// cause sends the user to fix something that is not broken. Hardware control
  /// off is one; a display whose volume controls are switched off or denied is
  /// the other, and that one only became a strand when the volume and mute keys
  /// started obeying the same verdict as the slider.
  @ViewBuilder private var strandedMuteBanner: some View {
    if isStrandedMuted {
      card {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Label("This display is muted in hardware.", systemImage: "speaker.slash")
            Spacer()
            Button(strandedMuteButtonTitle) { recoverFromHardwareMute() }
              .accessibilityLabel(strandedMuteButtonTitle)
          }
          SettingsCaption(strandedMuteExplanation)
        }
      }
    }
  }

  /// Hardware-muted with no way back inside the app. Two ways to get there:
  ///
  /// 1. The volume command turned off, where `toggleMute` refuses on
  ///    `isAvailable`.
  /// 2. The display's volume controls disabled, either by the user's "Always
  ///    disabled" choice or by the display's own denial of the volume command.
  ///    That greys the sliders and, since the keys began sharing the slider's
  ///    verdict, swallows the mute key too. The narrow window that makes this
  ///    real without any user choice: a mute lands while the capabilities probe
  ///    is still out (absent reads as unknown, which allows), and the answer
  ///    comes back as a denial.
  ///
  /// A display that denies only the MUTE register is deliberately NOT a cause:
  /// its volume path is still live, and any upward volume move clears `isMuted`
  /// and sends the unmute inside `apply()`, so the route back never closed.
  private var isStrandedMuted: Bool {
    state.volume.isMuted && (!state.volume.isAvailable || !model.volumeSliderEnabled(state))
  }

  /// Which cause applies. Hardware control off is checked FIRST because it is
  /// the stronger claim: it disables the volume command outright, so its
  /// sentence stays true even when the volume controls are also switched off.
  private var isHardwareControlOff: Bool { !state.volume.isAvailable }

  private var strandedMuteButtonTitle: String {
    isHardwareControlOff ? "Turn Hardware Control Back On and Unmute" : "Unmute This Display"
  }

  /// Says what the button will change and nothing more. The last sentence
  /// deliberately does not promise the slider comes back: when the cause is the
  /// display's own denial, setting the choice back to automatic leaves it
  /// greyed, and the honest claim is about the unmute and the setting.
  ///
  /// The cause sentence is the SAME one the greyed slider gives on hover, from
  /// the policy that made the decision. A fused sentence here would have said
  /// "this display's volume controls are switched off" for both causes, which
  /// is the collapse the slider's own copy was split to fix: told their monitor
  /// refused, a user who set "Always disabled" themselves goes looking for a
  /// bad cable.
  private var strandedMuteExplanation: LocalizedStringKey {
    if isHardwareControlOff {
      return "Muting used the display's own mute command, and that command can only be undone over hardware control. This turns hardware control back on for this display and unmutes it."
    }
    // Non-nil exactly when the slider is disabled, which is this branch's own
    // condition; the fallback exists for the compiler, not for a reachable state.
    let cause = model.volumeSliderCompactReason(state) ?? "This display's volume controls are off."
    return "\(cause) Muting used the display's own mute command, so no slider or key can undo it. This unmutes the display and sets its volume slider back to Enable automatically."
  }

  /// Clears the prefs that closed the other routes FIRST, then unmutes. Doing
  /// it in the other order is a silent no-op for the hardware-control cause:
  /// `toggleMute` returns `isMuted` unchanged while `isAvailable` is false, and
  /// the user is left believing they unmuted.
  ///
  /// `audioSinkOverride` joins the two availability prefs because it is now one
  /// of the ways in (D29 rule 2 covers whatever closed the routes, not a fixed
  /// list). Clearing it to automatic is honest in both directions: it undoes an
  /// "Always disabled" choice, and on a display that denies the command it
  /// changes nothing, which is why the copy does not claim the slider returns.
  ///
  /// `enableMuteUnmute` is deliberately NOT touched — the display was muted
  /// under whatever strategy is in force, and that strategy has to still be in
  /// force for the unmute to send the right wire value.
  ///
  /// The unmute itself drives the controller directly and consults no
  /// capability verdict, which is what makes this recovery immune to the gates
  /// that created the second cause.
  private func recoverFromHardwareMute() {
    // Three prefs, three rows, one union: `writeAll`, never a single
    // representative name.
    writer.writeAll([.forceSw, .unavailableDDC, .audioSinkOverride]) { prefs in
      prefs.forceSoftware = false
      var tuning = prefs.tuning(for: .volume)
      tuning.unavailableDDC = false
      prefs.setTuning(tuning, for: .volume)
      prefs.audioSinkOverride = .auto
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
            .accessibilityLabel("OK")
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
          .accessibilityLabel("Keep")
          .accessibilityFocused($keepFocused)
        Button("Revert Now") { Task { await coordinator.revert(preview) } }
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Revert Now")
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
