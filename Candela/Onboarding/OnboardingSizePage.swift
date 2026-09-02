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
        title: "A better size for \(model.displayName(forKey: displayKey))",
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

  /// The keep and revert bar, the safety shape the picker ships. The copy
  /// states the semantic: expiry reverts, so the size sticks only on Keep.
  private func countdownBar(seconds: Int) -> some View {
    VStack(spacing: 12) {
      Text("Reverting to the previous size in \(seconds)s unless you keep it")
        .font(.callout)
        .foregroundStyle(OnboardingStyle.bodyColor)
        .monospacedDigit()
        .contentTransition(.numericText())
      HStack(spacing: 14) {
        Button("Keep") { model.keepSize() }
          .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
          .keyboardShortcut(.defaultAction)
        Button("Revert") { model.revertSize() }
          .buttonStyle(OnboardingSecondaryButtonStyle())
      }
    }
  }
}
