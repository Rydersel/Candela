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
/// settings-origin start failure, a synthesis refusal (SS9), unread reapply
/// notices (SO8), the
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    // Read ONCE per body and handed down. `hasAnyStoredValue` behind
    // `firstSight` materialises the whole UserDefaults dictionary, and this
    // region re-renders every second of a countdown, in two placements.
    let cards = visibleCards
    // Spacing lives on each card, not on this stack: a padded container would
    // keep its padding as dead space when every banner is absent, which is the
    // usual state of this region.
    VStack(spacing: 0) {
      countdownBanner
      startFailureBanner
      synthesisRefusalBanner
      reapplyBanner
      strandedMuteBanner
      firstSightBanner(cards.firstSight)
    }
    // Keyed to WHICH cards are present and to nothing else. The countdown's
    // per-second tick, a report's sentence and the strand's cause all change
    // inside a card that is already on screen, and a card already on screen is
    // not an arrival; a page-wide or unkeyed animation here would put every one
    // of them on a curve.
    .animation(Motion.notice(reduceMotion: reduceMotion), value: cards)
    // A failure notice describes a display that is still muted, so the display
    // ceasing to be muted is what retires it, whichever route did it: the
    // slider and the keys work again the moment the register does, and they are
    // the likelier route once the user has turned HDR off.
    // `.failed` only. A run in flight passes through unmuted on its way to its
    // own answer (`toggleMute` clears the flag before the wire is settled), and
    // clearing the phase there would retire the spinner over a recovery that
    // has not finished and may yet put the mute back.
    .onChange(of: state.volume.isMuted) { _, isMuted in
      guard !isMuted, case .failed = model.muteRecoveryPhases[persistenceKey] else { return }
      model.setMuteRecoveryPhase(nil, for: persistenceKey)
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
      // Opacity only, per card: the stack's animated layout supplies the
      // collapse and the growth, so nothing slides sideways and the cards below
      // a departing one keep their order.
      .transition(.opacity)
  }

  // MARK: - What is on screen

  /// Which cards the region is showing, and the only animation key it has.
  ///
  /// Each field is read from the same property the matching `@ViewBuilder`
  /// branches on, so the key cannot come to disagree with what is rendered: a
  /// second, drifting copy of these tests would animate cards that are not
  /// there and leave arriving ones to jump.
  ///
  /// No defaults: a field left out of the key below is a compile error rather
  /// than a card that silently never animates.
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
      // Presence only. The countdown's two FORMS are a branch swap that rebuilds
      // the answerable banner's controls, so a surface change lands instantly
      // rather than cross-fading two different cards.
      //
      // Latent, and worth knowing if the preview model changes: `surface` is
      // fixed at preview start and `ownsAnswerableCountdown` follows the
      // navigation stack, so today neither can flip in the same update as
      // another card's presence. If one ever could, that update would carry an
      // animation and the form swap would cross-fade a live control.
      countdown: countdownForm != nil,
      startFailure: startFailure != nil,
      synthesisRefusal: synthesisRefusal != nil,
      reapply: reapplyReport != nil,
      strandedMute: showsStrandedMute,
      firstSight: showsFirstSight
    )
  }

  // MARK: - Countdown (SO6)

  /// The one place the settings window renders an outstanding preview. Which
  /// FORM it takes is the preview's own `surface`, decided at start: buttons
  /// when this window owns the answer, passive text when the floating window
  /// does, nothing when the guided setup window does. Never two answers to one
  /// question (SO6).
  @ViewBuilder private var countdownBanner: some View {
    if let preview = coordinator.preview, let form = countdownForm {
      switch form {
      case .answerable:
        card { AnswerableModeBanner(coordinator: coordinator, preview: preview) }
      case .passive:
        card {
          Text(verbatim: DisplayModeCopy.passiveCountdown(preview.secondsRemaining))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
    }
  }

  /// Which form the countdown card takes, or nil when there is no card. Read by
  /// the builder above and by the animation key, so presence has one definition.
  enum CountdownForm: Equatable { case answerable, passive }

  /// Nameable rather than inline, so the app test bundle can assert on it: the
  /// three surfaces answer differently here and only one of them puts buttons
  /// on screen, which is the SO6 property nothing else in this file states.
  static func countdownForm(
    preview: DisplayModeCoordinator.Preview?, displayID: CGDirectDisplayID,
    ownsAnswerableCountdown: Bool
  ) -> CountdownForm? {
    guard let preview, preview.displayID == displayID else { return nil }
    switch preview.surface {
    case .settingsBanner:
      return ownsAnswerableCountdown ? .answerable : nil
    case .floatingPanel:
      // Status only while the countdown is armed. Once it is spent (a failed
      // expiry) the floating window is the whole story, and a passive line
      // saying "reverting in 0 seconds" would be false.
      return preview.isCountingDown ? .passive : nil
    case .guidedSetup:
      // Nothing at all (DM11). The setup window owns the answer and renders it
      // itself, and this region can be on screen at the same time in a
      // background settings window: an answerable banner there would be a
      // second answer to one question, which is what the surface model exists
      // to prevent. A passive line is not ruled out on taste; it is simply not
      // this change.
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
  /// panel-origin ones — the settings window stays on screen, so this region
  /// can report its own.
  @ViewBuilder private var startFailureBanner: some View {
    if let failure = startFailure {
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

  /// This display's start failure, or nil. One reading for the builder and the
  /// animation key.
  private var startFailure: DisplayModeCoordinator.StartFailure? {
    guard let failure = coordinator.startFailure, failure.displayID == displayID else { return nil }
    return failure
  }

  /// A synthesized size that did not engage, or a teardown that did not finish
  /// (SS9, and `SynthesisFailure.unwindIncomplete`).
  ///
  /// HERE rather than beside the opt-in row it usually answers, for SO7's
  /// reason: this region renders above the hub root AND above every pushed
  /// page, and a synthesized size can be picked from the All Sizes page, which
  /// is a pushed page whose own body a hub-root row never reaches. Same
  /// placement as the start failure directly above, whose route into this
  /// region was the same argument.
  ///
  /// No `.help`: the diagnostic a start failure puts in a tooltip is a
  /// CoreGraphics error code, and no synthesis refusal has one. The sentence is
  /// the whole answer.
  @ViewBuilder private var synthesisRefusalBanner: some View {
    if let refusal = synthesisRefusal {
      card {
        VStack(alignment: .leading, spacing: 6) {
          SettingsCaption(SynthesisCopy.refusal(refusal.reason))
          Button("OK") { model.synthesis.dismissRefusal() }
            .accessibilityLabel("OK")
        }
      }
    }
  }

  /// This display's refusal, or nil. One reading for the builder and the key,
  /// like the start failure above: the coordinator holds ONE refusal for the
  /// request just made, and every surface that renders it checks the display.
  private var synthesisRefusal: SynthesisCoordinator.Refusal? {
    guard let refusal = model.synthesis.refusal, refusal.displayID == displayID else { return nil }
    return refusal
  }

  // MARK: - Reapply notices (SO8)

  /// What reapply could not do, said on the display it could not do it to.
  /// An unplug does not take it away; only OK does, through the one dismissal
  /// path every surface shares.
  @ViewBuilder private var reapplyBanner: some View {
    if let report = reapplyReport {
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

  private var reapplyReport: DisplayModeCoordinator.ReapplyReport? {
    coordinator.report(for: displayID)
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
    if showsStrandedMute {
      card {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Label(strandedMuteHeadline, systemImage: "speaker.slash")
            Spacer()
            // In flight, the button gives way to the spinner: the same shape
            // the reset button takes while a reset runs, and for the same
            // reason. This is not D29 rule 3's forbidden state (a recovery
            // control disabled in the state it recovers from) but the seconds
            // during which it is doing the recovering, released by a `defer`.
            if recoveryPhase == .running {
              ProgressView().controlSize(.small)
            } else {
              Button(strandedMuteButtonTitle) {
                Task { await recoverFromHardwareMute() }
              }
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

  /// The strand, plus the two states the recovery itself can be in. The failure
  /// notice has to outlive the strand: clearing the availability prefs reopens
  /// the slider and the keys, so a recovery that got that far and then could not
  /// reach the display is no longer `isStrandedMuted` while the display is still
  /// silent, and the one thing the user must not be shown is the card vanishing
  /// over a monitor that never came back.
  private var showsStrandedMute: Bool { isStrandedMuted || recoveryPhase != nil }

  private var strandedMuteHeadline: LocalizedStringKey {
    if case .failed = recoveryPhase { return "This display is still muted." }
    return "This display is muted in hardware."
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

  /// Clears the prefs that closed the other routes FIRST, then unmutes. Doing
  /// it in the other order is a silent no-op for the hardware-control cause:
  /// `toggleMute` returns `isMuted` unchanged while `isAvailable` is false, and
  /// the user is left believing they unmuted.
  ///
  /// The unmute itself drives the controller directly and consults no
  /// capability verdict, which is what makes this recovery immune to the gates
  /// that created the second cause.
  ///
  /// The sequence itself is `StrandedMuteRecovery` in CandelaKit, where the
  /// ordering can be tested; this end supplies the pref clearing and renders the
  /// outcome. What the engine adds over the original inline version is evidence:
  /// DDC is dead while a display is in HDR and the panel ACKs the loss anyway,
  /// so an unmute sent then cleared the muted flag and hid this card over a
  /// display that was still silent.
  ///
  /// The card fades out over 0.2 s and stays hit-testable while it does, so a
  /// second click mid-fade must not drive a second unmute; the recovery's own
  /// in-flight guard answers that, and `toggleMute` is never reached twice.
  private func recoverFromHardwareMute() async {
    model.setMuteRecoveryPhase(.running, for: persistenceKey)
    let outcome = await StrandedMuteRecovery.recover(
      volume: state.volume, hdrOwner: state.controller
    ) {
      // D29 rule 2, and it runs whatever the display turns out to be doing:
      // three prefs, three rows, one union (`writeAll`, never a single
      // representative name). `audioSinkOverride` is here because it is one of
      // the ways in, and clearing it is honest in both directions: it undoes an
      // "Always disabled" choice, and on a display that denies the command it
      // changes nothing, which is why the copy does not claim the slider
      // returns. `enableMuteUnmute` is deliberately NOT touched: the display was
      // muted under whatever strategy is in force, and that strategy has to
      // still be in force for the unmute to send the right wire value.
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

  // MARK: - First sight (SO22)

  /// An empty pref domain is the honest test for "never configured": every
  /// per-display key — prefs, tuning, saved levels — carries the persistence
  /// key, so a display that has ANY history fails it. Dismissal is
  /// session-scoped and in-memory on purpose; a marker pref would defeat the
  /// very emptiness this line is gated on.
  ///
  /// Takes the answer rather than re-deriving it: `hasAnyStoredValue` reads the
  /// whole domain, and `body` has already asked once for the animation key.
  @ViewBuilder private func firstSightBanner(_ shows: Bool) -> some View {
    if shows {
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

  private var showsFirstSight: Bool {
    // Never for the built-in. This banner narrates the replug identity story:
    // a monitor seen for the first time starts fresh, and its settings will
    // survive an unplug. The built-in display is present from the app's very
    // first launch, so "first time seeing this display" is false there, and
    // because dismissal is session-scoped while the gate is an EMPTY pref
    // domain, an untouched built-in showed the note again on every launch.
    persistenceKey != "builtIn"
      && !model.dismissedFirstSightKeys.contains(persistenceKey)
      && !DisplayPrefs.hasAnyStoredValue(forKey: persistenceKey)
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
          .transition(.opacity)
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
        // something else. Keeping writes the stored mode when this display's
        // Remember toggle is on; reverting and expiry never do.
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
    // The failure caption is a pure insert under the buttons, so it fades in and
    // the buttons give way to it. Keyed to that one fact, so the seconds ticking
    // inside this same stack animate nothing.
    //
    // The countdown/expiry pair below the caption DOES animate with it, and that
    // is accepted rather than avoided: `adopt` assigns the whole `Preview` at
    // once, so a failed expiry flips `failure` and `isCountingDown` in one
    // observation and the swap lands inside this transaction. Both branches are
    // plain text with no control and no focus in them, so the cross-fade costs
    // nothing.
    .animation(Motion.notice(reduceMotion: reduceMotion), value: preview.failure != nil)
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
