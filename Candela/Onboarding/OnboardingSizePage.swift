import CandelaKit
import SwiftUI

/// The recommended size for one display. The copy rule: renders at a higher
/// resolution and scales the result, never "native HiDPI". Applying starts
/// the keep and revert countdown through the model's apply seam; this
/// page renders the seam's state and never owns a timer of its own.
struct OnboardingSizePage: View {
  @Bindable var model: OnboardingFlowModel
  let displayKey: String
  let accent: Color

  @State private var showsAlternatives = false
  @State private var showsFullList = false
  /// The bar is a timed decision, so it lands the cursor on its answer the way
  /// the settings mode banner does. Everywhere else the heading takes it.
  @AccessibilityFocusState private var keepFocused: Bool
  @AccessibilityFocusState private var revertFocused: Bool

  private var display: OnboardingDisplayEntry? { model.display(forKey: displayKey) }

  var body: some View {
    if let display, let suggestion = display.sizeSuggestion {
      content(display: display, suggestion: suggestion)
    } else {
      // The subject vanished mid-flow; the model replans around it.
      Color.clear.onAppear { model.advance() }
    }
  }

  private func content(
    display: OnboardingDisplayEntry, suggestion: OnboardingSizeSuggestion
  ) -> some View {
    VStack(spacing: 0) {
      Spacer(minLength: 20)
      OnboardingHeading(
        title: OnboardingTitles.size(displayName: model.displayName(forKey: displayKey)),
        subtitle: "Everything stays sharp: the display renders at a higher resolution and scales the result. Text and controls get the size this display was made for."
      )
      Spacer(minLength: 14)
      // A tall face (the rotated Dell) is too narrow for text inside it, so
      // the label moves below the glyph there.
      if display.drawnAspect < 0.9 {
        VStack(spacing: 8) {
          DisplayGlyph(aspect: display.drawnAspect, accent: accent)
            .frame(height: 140)
          sizeLabel(display: display)
        }
      } else {
        DisplayGlyph(
          aspect: display.drawnAspect,
          accent: accent,
          faceOverlay: AnyView(sizeLabel(display: display))
        )
        .frame(height: 170)
      }
      Spacer(minLength: 16)
      if let seconds = model.applyCountdownSecondsRemaining(forKey: displayKey) {
        countdownBar(seconds: seconds)
          .transition(.opacity)
      } else {
        choices(suggestion: suggestion)
      }
      Spacer(minLength: 22)
    }
    // Keyed to the seam state so ticks, the choices/countdown swap and the
    // revert's return all animate; a plain VStack animates both directions.
    .animation(.spring(duration: 0.45), value: model.applyState)
    // The tick this page already re-renders on, never a timer of its own. The
    // applier publishes the seconds and the achieved size in one update, so
    // both halves are observed together.
    .onChange(of: countdownTick) { previous, current in
      speakCountdown(divergedThisTick: previous.achieved == nil && current.achieved != nil)
    }
    .onDisappear {
      // An unanswered countdown must not outlive its page (the commit-on-advance
      // rule keeps only
      // what was confirmed); the model reverts it and stops ticking.
      model.sizePageDisappeared()
    }
  }

  /// The size the glyph should read: the size under countdown while one is
  /// open, the kept size after a keep, else what is on the glass now.
  private func shownSize(display: OnboardingDisplayEntry) -> (width: Int, height: Int) {
    if let pending = model.pendingAppliedSize(forKey: displayKey) {
      return pending
    }
    switch model.sizeChoices[displayKey] {
    case let .custom(width, height):
      return (width, height)
    case .recommended:
      if let suggestion = display.sizeSuggestion {
        return (suggestion.looksLikeWidth, suggestion.looksLikeHeight)
      }
    case .keepCurrent, nil:
      break
    }
    return (display.currentLooksLikeWidth, display.currentLooksLikeHeight)
  }

  private func sizeLabel(display: OnboardingDisplayEntry) -> some View {
    let size = shownSize(display: display)
    return VStack(spacing: 3) {
      Text("Looks like")
        .font(.caption2)
        .foregroundStyle(OnboardingStyle.faintColor)
      // verbatim: interpolation into a LocalizedStringKey formats numbers
      // with grouping separators, and a size is "2560 x 1440", never
      // "2,560 x 1,440".
      Text(verbatim: "\(size.width) x \(size.height)")
        .font(.system(.title3, design: .rounded).weight(.semibold))
        .foregroundStyle(OnboardingStyle.titleColor)
        .lineLimit(1)
        .contentTransition(.numericText())
    }
  }

  @ViewBuilder
  private func choices(suggestion: OnboardingSizeSuggestion) -> some View {
    VStack(spacing: 12) {
      if model.applyState == .failed {
        Text("That size could not be applied. Try again, or keep the current size.")
          .font(.callout)
          .foregroundStyle(OnboardingStyle.faintColor)
          .transition(.opacity)
      }
      Button {
        model.applySize(displayKey: displayKey, choice: .recommended)
      } label: {
        Text(verbatim: "Use Looks Like \(suggestion.looksLikeWidth) x \(suggestion.looksLikeHeight)")
      }
      .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
      .keyboardShortcut(.defaultAction)
      HStack(spacing: 14) {
        Button("Keep Current Size") {
          model.sizeChoices[displayKey] = .keepCurrent
          model.advance()
        }
        .buttonStyle(OnboardingSecondaryButtonStyle())
        Button(showsAlternatives ? "Hide Other Sizes" : "Choose Another…") {
          withAnimation(.spring(duration: 0.4)) {
            showsAlternatives.toggle()
            if !showsAlternatives { showsFullList = false }
          }
        }
        .buttonStyle(OnboardingLinkButtonStyle())
      }
      if showsAlternatives {
        alternativeList(suggestion: suggestion)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
      OnboardingSkipLink(model: model)
    }
  }

  /// Collapsed: the sizes nearest the recommendation plus a bubble opening
  /// the complete list. Expanded: every curated size, wrapping.
  @ViewBuilder
  private func alternativeList(suggestion: OnboardingSizeSuggestion) -> some View {
    let shown = showsFullList ? suggestion.alternatives : Array(suggestion.alternatives.prefix(4))
    let hidden = suggestion.alternatives.count - shown.count
    VStack(spacing: 10) {
      sizeGrid(shown, suggestion: suggestion)
      if hidden > 0 {
        Button("All \(suggestion.alternatives.count) Sizes…") {
          withAnimation(.spring(duration: 0.4)) { showsFullList = true }
        }
        .buttonStyle(OnboardingLinkButtonStyle())
      }
    }
  }

  private func sizeGrid(
    _ choices: [OnboardingSizeSuggestion.Choice], suggestion: OnboardingSizeSuggestion
  ) -> some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10
    ) {
      ForEach(choices) { choice in
        Button {
          model.applySize(
            displayKey: displayKey,
            choice: .custom(
              looksLikeWidth: choice.looksLikeWidth, looksLikeHeight: choice.looksLikeHeight))
        } label: {
          VStack(spacing: 2) {
            Text(verbatim: "\(choice.looksLikeWidth) x \(choice.looksLikeHeight)")
              .font(.callout.weight(.medium))
            if choice.looksLikeWidth == suggestion.looksLikeWidth,
              choice.looksLikeHeight == suggestion.looksLikeHeight {
              Text("Recommended")
                .font(.caption2)
                .foregroundStyle(accent)
            }
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(OnboardingSecondaryButtonStyle())
      }
    }
    .padding(.horizontal, 60)
  }

  /// One sentence for what the display is actually showing, from
  /// `DisplayModeCopy` so this page cannot word it differently from the other
  /// three surfaces that ask the same question.
  ///
  /// In THIS page's dialect: every size here is written "2560 x 1440" and the
  /// noun is always "size", so the shared sentence arrives spelled the way the
  /// glyph, the apply button and the alternatives grid above it already are.
  static func achievedCaption(_ achieved: OnboardingAchievedSize) -> String {
    switch achieved {
    case let .size(width, height, refreshHz):
      DisplayModeCopy.achievedGeometry(
        width: width, height: height, refreshHz: refreshHz, dialect: .size)
    case .unreadable:
      DisplayModeCopy.unreadableAchievedGeometry(dialect: .size)
    }
  }

  /// The keep and revert bar, the safety shape the picker ships. The copy
  /// states the semantic: expiry reverts, so the size sticks only on Keep.
  static func countdownCaption(seconds: Int, canKeep: Bool) -> String {
    guard seconds > 0 else {
      return "The automatic revert could not restore the previous size. Choose Revert to try again."
    }
    return canKeep
      ? "Reverting to the previous size in \(seconds)s unless you keep it"
      : "Reverting to the previous size in \(seconds)s"
  }

  /// Returns `countdownCaption` itself, so a listener and a reader get the same
  /// sentence. Nil where the cadence rule says nothing.
  ///
  /// Also nil on `divergedThisTick`: the seconds and a divergence arrive in one
  /// update, and this announcement interrupts, so it would cut off the recovery
  /// text that is the only route back out of a diverged commit. The deadline
  /// stays on the bar as a caption.
  static func countdownAnnouncement(
    seconds: Int, canKeep: Bool, cap: Int, divergedThisTick: Bool = false
  ) -> String? {
    guard !divergedThisTick else { return nil }
    guard AnnouncementThresholds.speaks(at: seconds, cap: cap) else { return nil }
    return countdownCaption(seconds: seconds, canKeep: canKeep)
  }

  /// The bar's own title when a commit diverged. Drawn and spoken from one
  /// place: a listener whose cursor is on Revert hears it only here.
  static let divergedTitle = "Size preview could not be verified"

  /// The achieved size said out loud. Not `achievedCaption`, which is display
  /// text down to the times sign and shortened Hz; both are read inconsistently.
  static func spokenAchievedSize(_ achieved: OnboardingAchievedSize) -> String {
    switch achieved {
    case let .size(width, height, refreshHz):
      "The display is showing "
        + ModeSpeech.spoken(logicalWidth: width, logicalHeight: height, refreshHz: refreshHz) + "."
    case .unreadable:
      DisplayModeCopy.unreadableAchievedGeometry(dialect: .size)
    }
  }

  /// What happened, the way out, and what the display is showing instead. The
  /// cursor is on Revert, so the sentences above the buttons reach a listener
  /// nowhere else.
  static func divergenceAnnouncement(_ achieved: OnboardingAchievedSize) -> String {
    "\(divergedTitle). \(DisplayModeCopy.recoveryInstruction(dialect: .size)) "
      + spokenAchievedSize(achieved)
  }

  /// The deadline the caption gives a reader, plus the recovery text when the
  /// commit had already diverged before the bar appeared.
  static func barAnnouncement(seconds: Int, achieved: OnboardingAchievedSize?) -> String {
    let caption = countdownCaption(seconds: seconds, canKeep: achieved == nil)
    guard let achieved else { return caption }
    return "\(divergenceAnnouncement(achieved)) \(caption)"
  }

  private func countdownBar(seconds: Int) -> some View {
    VStack(spacing: 12) {
      Text(verbatim: Self.countdownCaption(
        seconds: seconds, canKeep: model.pendingAchievedSize(forKey: displayKey) == nil))
        .font(.callout)
        .foregroundStyle(OnboardingStyle.bodyColor)
        .monospacedDigit()
        .contentTransition(.numericText())
      if let achieved = model.pendingAchievedSize(forKey: displayKey) {
        Text(verbatim: Self.divergedTitle)
          .font(.callout.weight(.semibold))
          .foregroundStyle(OnboardingStyle.bodyColor)
        Text(verbatim: DisplayModeCopy.recoveryInstruction(dialect: .size))
          .font(.callout)
          .foregroundStyle(OnboardingStyle.bodyColor)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        Text(verbatim: Self.achievedCaption(achieved))
          .font(.callout)
          .foregroundStyle(OnboardingStyle.faintColor)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 14) {
        if model.pendingAchievedSize(forKey: displayKey) == nil {
          Button("Keep") { model.keepSize() }
            .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
            .keyboardShortcut(.defaultAction)
            .accessibilityFocused($keepFocused)
        }
        Button("Revert") { model.revertSize() }
          .buttonStyle(OnboardingSecondaryButtonStyle())
          .keyboardShortcut(.cancelAction)
          .accessibilityFocused($revertFocused)
      }
    }
    // Revert takes the cursor when Keep is gone: a recovery control is never the
    // one the cursor cannot find. The caption goes with the landing, since a
    // deadline nobody speaks is a deadline nobody hears.
    .onAppear {
      landFocus()
      GuidedFlowAnnouncement.queued(
        Self.barAnnouncement(
          seconds: seconds, achieved: model.pendingAchievedSize(forKey: displayKey)))
    }
    // Divergence can land after the bar is up, taking Keep out from under the
    // cursor. The recovery text moves with it, since those sentences are on
    // screen only.
    .onChange(of: model.pendingAchievedSize(forKey: displayKey)) { _, achieved in
      landFocus()
      guard let achieved else { return }
      GuidedFlowAnnouncement.queued(Self.divergenceAnnouncement(achieved))
    }
  }

  /// Observed as a pair, so the divergence and the seconds it arrived with
  /// cannot be read from different updates.
  private struct CountdownTick: Equatable {
    var state: OnboardingApplyState
    var achieved: OnboardingAchievedSize?
  }

  private var countdownTick: CountdownTick {
    CountdownTick(
      state: model.applyState, achieved: model.pendingAchievedSize(forKey: displayKey))
  }

  private func landFocus() {
    let canKeep = model.pendingAchievedSize(forKey: displayKey) == nil
    keepFocused = canKeep
    revertFocused = !canKeep
  }

  /// High priority, so it interrupts: a deadline heard after it expired is not
  /// a deadline.
  private func speakCountdown(divergedThisTick: Bool) {
    guard let seconds = model.applyCountdownSecondsRemaining(forKey: displayKey) else { return }
    guard let text = Self.countdownAnnouncement(
      seconds: seconds,
      canKeep: model.pendingAchievedSize(forKey: displayKey) == nil,
      cap: model.applierCountdownSeconds,
      divergedThisTick: divergedThisTick
    ) else { return }
    GuidedFlowAnnouncement.interrupting(text)
  }
}
