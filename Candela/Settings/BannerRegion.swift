import Accessibility
import CandelaKit
import CoreGraphics
import SwiftUI

/// This region's single banner placement: rendered above the hub root and above every
/// pushed sub-page, so no page owns a banner. Everything is keyed to the
/// destination display, so a preview on another display renders nothing here.
///
/// `@MainActor` because a `View`'s properties other than `body` are nonisolated
/// under complete concurrency, and these read main-actor types.
@MainActor
struct BannerRegion: View {
  let state: AppModel.DisplayState
  /// Only ONE answerable surface is allowed, and the hub root keeps rendering behind
  /// a pushed page. Both placements matched the same `displayID` and drew two
  /// answerable banners for one question. The pushed page wins; passive cards
  /// stay on both.
  var ownsAnswerableCountdown = true

  @Environment(AppModel.self) private var model
  @Environment(SettingsActions.self) private var actions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Measured by `measureDomainFreshness()`, never in `body`. Re-measured on
  /// the display change and on `prefsRevision`, which is every event that can
  /// flip it: both resets bump it, so a wiped domain reads as fresh again
  /// rather than staying stale behind a cache.
  @State private var domainIsFresh: Bool?

  private var persistenceKey: String { state.display.persistenceKey }
  private var displayID: CGDirectDisplayID { state.display.id }
  private var coordinator: DisplayModeCoordinator { model.displayModes }
  private var prefs: DisplayPrefs { DisplayPrefs(persistenceKey: persistenceKey) }
  private var writer: DisplayPrefWriter {
    DisplayPrefWriter(persistenceKey: persistenceKey, actions: actions)
  }

  var body: some View {
    // `DisplayPrefs` is plain UserDefaults, not observable; this re-runs the
    // strand and first-sight checks after a write anywhere.
    let _ = model.prefsRevision
    // Read once and handed down, so the animation key and the rendered card
    // cannot disagree.
    let cards = visibleCards
    // Spacing per card, not on the stack: a padded container would leave dead
    // space when every banner is absent, the usual state here.
    VStack(spacing: 0) {
      countdownBanner
      startFailureBanner
      synthesisRefusalBanner
      reapplyBanner
      strandedMuteBanner
      firstSightBanner(cards.firstSight)
    }
    // Keyed to WHICH cards are present, nothing else: a tick or a changed
    // sentence inside a card already on screen is not an arrival.
    .animation(Motion.notice(reduceMotion: reduceMotion), value: cards)
    // A failure notice is about a display that is still muted, so an unmute by
    // any route retires it. `.failed` only: a run in flight passes through
    // unmuted before the wire settles, and clearing there would retire the
    // spinner over a recovery that may yet put the mute back.
    .onChange(of: state.volume.isMuted) { _, isMuted in
      guard !isMuted, case .failed = model.muteRecoveryPhases[persistenceKey] else { return }
      model.setMuteRecoveryPhase(nil, for: persistenceKey)
    }
    .onAppear { measureDomainFreshness() }
    .onChange(of: persistenceKey) { _, _ in measureDomainFreshness() }
    .onChange(of: model.prefsRevision) { _, _ in measureDomainFreshness() }
  }

  /// One banner's chrome, in the same content column as the page below. Applied
  /// per banner so an empty region is exactly zero-height. The notice symbol and
  /// title weight are what keep a timed keep-or-revert decision from reading like
  /// an ordinary page section; pass `symbol: nil` when the headline carries its own.
  private func card(
    symbol: String? = "exclamationmark.triangle", @ViewBuilder _ content: () -> some View
  ) -> some View {
    SettingsCard {
      if let symbol {
        SettingsNotice(symbol: symbol, drawsSurface: false) { content() }
      } else {
        content()
      }
    }
    .frame(maxWidth: SettingsTheme.pageWidth, alignment: .leading)
    .padding(.horizontal, 32)
    .frame(maxWidth: .infinity)
    .padding(.top, 10)
    // Opacity only: the stack's animated layout supplies the collapse, so
    // nothing slides sideways.
    .transition(.opacity)
  }

  // MARK: - What is on screen

  /// Which cards are showing, and the region's only animation key. Each field
  /// reads the same property its `@ViewBuilder` branch does, so the key cannot
  /// drift from what is rendered. No defaults: a field left out is a compile
  /// error, not a card that silently never animates.
  private struct VisibleCards: Equatable {
    var countdown: Bool
    var startFailure: Bool
    var synthesisRefusal: Bool
    var reapply: Bool
    var strandedMute: Bool
    var firstSight: Bool
  }

  private var visibleCards: VisibleCards {
    VisibleCards(
      // Presence only. The two countdown FORMS are a branch swap that rebuilds
      // the banner's controls, so a surface change lands instantly rather than
      // cross-fading two different cards.
      countdown: countdownForm != nil,
      startFailure: startFailure != nil,
      synthesisRefusal: synthesisRefusal != nil,
      reapply: reapplyReport != nil,
      strandedMute: showsStrandedMute,
      firstSight: showsFirstSight
    )
  }

  // MARK: - Countdown

  /// The settings window's only outstanding-preview surface. The form follows
  /// `preview.surface`: buttons when this window owns the answer, passive text
  /// when the floating window does, nothing under guided setup.
  @ViewBuilder private var countdownBanner: some View {
    if let preview = coordinator.preview, let form = countdownForm {
      switch form {
      case .answerable:
        card { AnswerableModeBanner(coordinator: coordinator, preview: preview) }
      case .passive:
        card {
          Text(verbatim: DisplayModeCopy.passiveCountdown(preview.secondsRemaining))
            .font(.callout)
            .foregroundStyle(SettingsTheme.bodyColor)
            .monospacedDigit()
        }
      }
    }
  }

  /// Read by the builder and by the animation key, so presence has one definition.
  enum CountdownForm: Equatable { case answerable, passive }

  /// Named rather than inline so the app test bundle can assert it: only one of
  /// the three surfaces puts buttons on screen, which is the
  /// one-answerable-surface property.
  static func countdownForm(
    preview: DisplayModeCoordinator.Preview?, displayID: CGDirectDisplayID,
    ownsAnswerableCountdown: Bool
  ) -> CountdownForm? {
    guard let preview, preview.displayID == displayID else { return nil }
    switch preview.surface {
    case .settingsBanner:
      return ownsAnswerableCountdown ? .answerable : nil
    case .floatingPanel:
      // Status only while the countdown is armed: after a failed expiry a
      // passive "reverting in 0 seconds" would be false.
      return preview.isCountingDown ? .passive : nil
    case .guidedSetup:
      // Nothing at all. The setup window owns the answer, and this
      // region can be on screen behind it in a background settings window: a
      // banner here would be a second answer to one question.
      return nil
    }
  }

  private var countdownForm: CountdownForm? {
    Self.countdownForm(
      preview: coordinator.preview, displayID: displayID,
      ownsAnswerableCountdown: ownsAnswerableCountdown
    )
  }

  // MARK: - A selection that never took effect

  /// A settings-origin `begin()` failure. The floating window carries only
  /// panel-origin ones, so this region reports its own.
  @ViewBuilder private var startFailureBanner: some View {
    if let failure = startFailure {
      card {
        VStack(alignment: .leading, spacing: 6) {
          SettingsCaption(DisplayModeCopy.startFailure(failure.reason))
            .help(DisplayModeCopy.startFailureDiagnostic(failure.reason))
          Button("OK") { coordinator.dismissStartFailure() }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .accessibilityLabel("OK")
        }
      }
    }
  }

  /// One reading for the builder and the animation key.
  private var startFailure: DisplayModeCoordinator.StartFailure? {
    guard let failure = coordinator.startFailure, failure.displayID == displayID else { return nil }
    return failure
  }

  /// A synthesized size that did not engage, or a teardown that did not finish
  /// (see `SynthesisFailure.unwindIncomplete`). Here rather than beside the
  /// opt-in row it answers, because the size can be picked from All Sizes, a
  /// pushed page a hub-root row never reaches. No `.help`: no refusal carries a
  /// diagnostic code, so the sentence is the whole answer.
  @ViewBuilder private var synthesisRefusalBanner: some View {
    if let refusal = synthesisRefusal {
      card {
        VStack(alignment: .leading, spacing: 6) {
          SettingsCaption(SynthesisCopy.refusal(refusal.reason))
          Button("OK") { model.synthesis.dismissRefusal() }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .accessibilityLabel("OK")
        }
      }
    }
  }

  /// One reading for the builder and the key. The coordinator holds one refusal
  /// at a time, so every surface that renders it checks the display.
  private var synthesisRefusal: SynthesisCoordinator.Refusal? {
    guard let refusal = model.synthesis.refusal, refusal.displayID == displayID else { return nil }
    return refusal
  }

  // MARK: - Reapply notices

  /// What reapply could not do, said on the display it could not do it to. An
  /// unplug does not clear it; only OK does, through the shared dismissal path.
  @ViewBuilder private var reapplyBanner: some View {
    if let report = reapplyReport {
      card {
        VStack(alignment: .leading, spacing: 6) {
          SettingsCaption(DisplayModeCopy.reapply(
            requested: report.requested, notice: report.notice
          ))
          .modifier(ReapplyDiagnostic(notice: report.notice))
          // Keyed by the report on screen, so OK clears only the notice the
          // user is reading. Same call the panel's OK makes.
          Button("OK") { coordinator.dismissReport(forKey: report.key) }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .accessibilityLabel("OK")
        }
      }
    }
  }

  private var reapplyReport: DisplayModeCoordinator.ReapplyReport? {
    coordinator.report(for: displayID)
  }

  // MARK: - Stranded mute recovery

  /// A recovery control that is never disabled in the state it recovers from:
  /// the explicit unmute affordance, never `.disabled`. It is the
  /// only route out of the strand, so it clears the prefs that closed the other
  /// routes FIRST (clearing availability prefs before the unmute), then unmutes
  /// while the display's current mute strategy is still in force. Rendered on
  /// the hub root and every sub-page because the DDC toggle that causes the
  /// strand lives on Advanced.
  ///
  /// Two causes reach it and each needs its own sentence: copy naming the wrong
  /// cause sends the user to fix something that is not broken.
  @ViewBuilder private var strandedMuteBanner: some View {
    if showsStrandedMute {
      // No leading symbol: this banner's headline is a `Label` carrying its own.
      card(symbol: nil) {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            // Symbol AND text, never state by color alone.
            Label(strandedMuteHeadline, systemImage: "speaker.slash")
              .font(.callout.weight(.medium))
              .foregroundStyle(SettingsTheme.titleColor)
            Spacer()
            // In flight the button gives way to a spinner. Not the forbidden
            // state (a recovery control disabled in the state it
            // recovers from): these are the seconds it is doing the recovering.
            if recoveryPhase == .running {
              ProgressView().controlSize(.small)
            } else {
              // Primary: the only way out of the state this card exists for.
              // Never `.disabled`.
              Button(strandedMuteButtonTitle) {
                Task { await recoverFromHardwareMute() }
              }
              .buttonStyle(SettingsPrimaryButtonStyle())
              .accessibilityLabel(strandedMuteButtonTitle)
              .accessibilityIdentifier("action.strandedMuteRecovery.\(persistenceKey)")
            }
          }
          SettingsCaption(strandedMuteExplanation)
        }
      }
    }
  }

  private var recoveryPhase: AppModel.MuteRecoveryPhase? {
    model.muteRecoveryPhases[persistenceKey]
  }

  /// The failure notice has to outlive the strand: clearing the availability
  /// prefs reopens the slider and the keys, so a recovery that then failed to
  /// reach the display is no longer `isStrandedMuted` while the display is still
  /// silent. The card must not vanish over a monitor that never came back.
  private var showsStrandedMute: Bool { isStrandedMuted || recoveryPhase != nil }

  private var strandedMuteHeadline: LocalizedStringKey {
    if case .failed = recoveryPhase { return "This display is still muted." }
    return "This display is muted in hardware."
  }

  /// Hardware-muted with no way back inside the app. Two ways in: the volume
  /// command turned off, where `toggleMute` refuses on `isAvailable`; or the
  /// display's volume controls disabled, by an "Always disabled" choice or the
  /// display's own denial, which greys the sliders and swallows the mute key.
  /// The route needing no user choice: a mute lands while the capabilities probe
  /// is still out (absent reads as unknown, which allows) and the answer comes
  /// back a denial.
  ///
  /// A display that denies only the MUTE register is NOT a cause: its volume
  /// path is live, so any upward move clears `isMuted` and sends the unmute
  /// inside `apply()`.
  private var isStrandedMuted: Bool {
    state.volume.isMuted && (!state.volume.isAvailable || !model.volumeSliderEnabled(state))
  }

  /// Checked FIRST: it disables the volume command outright, so its sentence
  /// stays true even when the volume controls are switched off too.
  private var isHardwareControlOff: Bool { !state.volume.isAvailable }

  private var strandedMuteButtonTitle: String {
    isHardwareControlOff ? "Turn Hardware Control Back On and Unmute" : "Unmute This Display"
  }

  /// Never promises the slider comes back: when the display itself denies the
  /// command, setting the choice to automatic leaves it greyed. The cause
  /// sentence is the one the greyed slider gives on hover, because a fused
  /// sentence tells a user who chose "Always disabled" that their monitor
  /// refused, and sends them after a bad cable.
  private var strandedMuteExplanation: LocalizedStringKey {
    // The failure sentences come first: once a recovery has run, the cause
    // sentences below describe prefs it has already cleared.
    switch recoveryPhase {
    case .failed(.blockedByHDR):
      return "Hardware control does not reach a display while it is in HDR mode, so no unmute was sent. Turn HDR off for this display and try again."
    case .failed:
      return "The unmute could not be confirmed as reaching the display, so it is still recorded as muted rather than reported as a change that may not have happened. Try again."
    case .running, .none:
      break
    }
    if isHardwareControlOff {
      return "Muting used the display's own mute command, and that command can only be undone over hardware control. This turns hardware control back on for this display and unmutes it."
    }
    // Non-nil exactly when the slider is disabled, which is this branch's own
    // condition; the fallback exists for the compiler, not for a reachable state.
    let cause = model.volumeSliderCompactReason(state) ?? "This display's volume controls are off."
    return "\(cause) Muting used the display's own mute command, so no slider or key can undo it. This unmutes the display and sets its volume slider back to Enable automatically."
  }

  /// Clears the prefs that closed the other routes FIRST, then unmutes.
  /// The other order is a silent no-op for the hardware-control cause:
  /// `toggleMute` returns `isMuted` unchanged while `isAvailable` is false and
  /// the user believes they unmuted. The unmute drives the controller directly
  /// and consults no capability verdict, so the gates that created the second
  /// cause cannot block the recovery.
  ///
  /// `StrandedMuteRecovery` owns the sequence, where the ordering is testable,
  /// and it confirms the unmute: DDC is dead while a display is in HDR and the
  /// panel ACKs the loss anyway, so an unconfirmed unmute cleared the muted flag
  /// and hid this card over a display that was still silent.
  ///
  /// The card stays hit-testable through its fade, so the recovery's in-flight
  /// guard is what keeps a second click from sending a second unmute.
  private func recoverFromHardwareMute() async {
    model.setMuteRecoveryPhase(.running, for: persistenceKey)
    let outcome = await StrandedMuteRecovery.recover(
      volume: state.volume, hdrOwner: state.controller
    ) {
      // Clears availability prefs before the unmute, and it runs whatever the
      // display turns out to be doing. Clearing `audioSinkOverride` undoes an
      // "Always disabled" choice and changes nothing on a display that denies
      // the command, which is why the copy does not claim the slider returns.
      // `enableMuteUnmute` is
      // deliberately NOT touched: the display was muted under the strategy in
      // force, and the unmute has to send the same wire value.
      writer.writeAll([.forceSw, .unavailableDDC, .audioSinkOverride]) { prefs in
        prefs.forceSoftware = false
        var tuning = prefs.tuning(for: .volume)
        tuning.unavailableDDC = false
        prefs.setTuning(tuning, for: .volume)
        prefs.audioSinkOverride = .auto
      }
    }
    switch outcome {
    case .unmuted, .notMuted:
      model.setMuteRecoveryPhase(nil, for: persistenceKey)
    case .blockedByHDR, .unconfirmed:
      model.setMuteRecoveryPhase(.failed(outcome), for: persistenceKey)
    case .alreadyRunning:
      break // the click that owns the run also owns the phase
    }
  }

  // MARK: - First sight

  /// An empty pref domain is the honest test for "never configured": every
  /// per-display key carries the persistence key, so any history fails it.
  /// Dismissal stays in memory for the session on purpose; a marker pref would
  /// defeat the emptiness the gate reads.
  @ViewBuilder private func firstSightBanner(_ shows: Bool) -> some View {
    if shows {
      card {
        HStack(alignment: .firstTextBaseline) {
          Text("First time seeing this display. Its settings start fresh.")
            .font(.callout)
            .foregroundStyle(SettingsTheme.bodyColor)
          Spacer()
          Button("OK") { model.dismissFirstSight(persistenceKey) }
            .buttonStyle(SettingsSecondaryButtonStyle())
            .accessibilityLabel("OK")
        }
      }
    }
  }

  private var showsFirstSight: Bool {
    // Never for the built-in: it is present from the app's first launch, so
    // "first time seeing this display" is false. With session-scoped dismissal
    // and an empty-domain gate, an untouched built-in showed the note on every
    // launch.
    persistenceKey != "builtIn"
      && !model.dismissedFirstSightKeys.contains(persistenceKey)
      && domainIsFresh == true
  }

  /// Whether this display's prefs domain is empty, or nil until measured.
  ///
  /// `hasAnyStoredValue` materialises the whole UserDefaults dictionary and
  /// scans it by suffix, and this region renders on two placements and
  /// re-evaluates every countdown second, so it cannot run from `body`. nil
  /// draws no banner: erring to silent for one frame beats flashing "first time
  /// seeing this display" at a display that has settings.
  private func measureDomainFreshness() {
    domainIsFresh = !DisplayPrefs.hasAnyStoredValue(forKey: persistenceKey)
  }
}

/// The answerable countdown banner (owned by the settings window), plus
/// accessibility contract 8: focus lands on Keep, an announcement names the mode
/// and the deadline, and the 10- and 3-second ticks re-announce. Return keeps and
/// Escape reverts while this window is key. Same words as the floating
/// confirmation window; two spellings of one statement are two things to keep true.
private struct AnswerableModeBanner: View {
  let coordinator: DisplayModeCoordinator
  let preview: DisplayModeCoordinator.Preview

  @AccessibilityFocusState private var keepFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Keep this resolution?")
        .font(.callout.weight(.semibold))
        .foregroundStyle(SettingsTheme.titleColor)
      Text(verbatim: "\(DisplayModeCopy.size(preview.mode)), \(DisplayModeCopy.refresh(preview.mode.refreshHz))")
        .font(.callout)
        .foregroundStyle(SettingsTheme.bodyColor)

      if let failure = preview.failure {
        // Nothing auto-retries a failed resolution. Silence here would leave
        // the display on a mode the user never approved.
        SettingsCaption(DisplayModeCopy.resolveFailure)
          .help("CoreGraphics error \(failure.cgErrorCode)")
          .transition(.opacity)
      }
      if preview.isCountingDown {
        Text(verbatim: DisplayModeCopy.countdown(preview.secondsRemaining))
          .font(.callout)
          .foregroundStyle(SettingsTheme.bodyColor)
          .monospacedDigit()
      } else if preview.failure != nil {
        SettingsCaption(DisplayModeCopy.expiryAlreadyRan)
      }

      HStack(spacing: 8) {
        // Both answers carry the preview THIS banner renders, so a selection
        // landing between the click and the queued operation is refused as
        // stale. Keeping writes the stored mode when Remember is on; reverting
        // and expiry never do.
        Button("Keep") { Task { await coordinator.confirm(preview) } }
          .buttonStyle(SettingsPrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
          .accessibilityLabel("Keep")
          .accessibilityFocused($keepFocused)
        Button("Revert Now") { Task { await coordinator.revert(preview) } }
          .buttonStyle(SettingsSecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
          .accessibilityLabel("Revert Now")
      }
      // Belt to the intent check: while a selection is landing, an answer to
      // the old preview is pointless.
      .disabled(coordinator.isApplying)
    }
    // Keyed to the caption's presence alone, so the ticking seconds animate
    // nothing. The countdown/expiry text below cross-fades with it, which is
    // free: `adopt` assigns the whole `Preview` at once and both branches are
    // plain text with no control in them.
    .animation(Motion.notice(reduceMotion: reduceMotion), value: preview.failure != nil)
    .accessibilityElement(children: .contain)
    .onAppear {
      keepFocused = true
      AccessibilityNotification.Announcement(
        DisplayModeCopy.previewAnnouncement(mode: preview.mode, seconds: preview.secondsRemaining)
      ).post()
    }
    // Driven by the tick this view already re-renders on, never a timer of its own.
    .onChange(of: preview.secondsRemaining) { _, seconds in
      if seconds == 10 || seconds == 3 {
        AccessibilityNotification.Announcement(DisplayModeCopy.countdown(seconds)).post()
      }
    }
  }
}
