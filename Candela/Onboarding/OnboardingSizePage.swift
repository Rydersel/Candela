import SwiftUI

/// The recommended size for one display. RM11 copy: renders at a higher
/// resolution and scales the result, never "native HiDPI". Applying keeps the
/// keep/revert countdown (PD9); the mock ticks a real countdown so the page
/// behaves as it will ship.
struct OnboardingSizePage: View {
  @Bindable var model: OnboardingFlowModel
  let displayKey: String
  let accent: Color

  @State private var showsAlternatives = false
  @State private var showsFullList = false
  @State private var applied = false
  @State private var countdown = 15
  @State private var ticker: Task<Void, Never>?

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
          sizeLabel(suggestion: suggestion, display: display)
        }
      } else {
        DisplayGlyph(
          aspect: display.drawnAspect,
          accent: accent,
          faceOverlay: AnyView(sizeLabel(suggestion: suggestion, display: display))
        )
        .frame(height: 170)
      }
      Spacer(minLength: 16)
      if applied {
        countdownBar
          .transition(.opacity)
      } else {
        choices(suggestion: suggestion)
      }
      Spacer(minLength: 22)
    }
    .onDisappear { ticker?.cancel() }
  }

  private func sizeLabel(
    suggestion: OnboardingSizeSuggestion, display: OnboardingDisplayEntry
  ) -> some View {
    VStack(spacing: 3) {
      Text("Looks like")
        .font(.caption2)
        .foregroundStyle(OnboardingStyle.faintColor)
      // verbatim: interpolation into a LocalizedStringKey formats numbers
      // with grouping separators, and a size is "2560 x 1440", never
      // "2,560 x 1,440".
      Text(
        verbatim: applied
          ? "\(suggestion.looksLikeWidth) x \(suggestion.looksLikeHeight)"
          : "\(display.currentLooksLikeWidth) x \(display.currentLooksLikeHeight)"
      )
      .font(.system(.title3, design: .rounded).weight(.semibold))
      .foregroundStyle(OnboardingStyle.titleColor)
      .lineLimit(1)
      .contentTransition(.numericText())
    }
  }

  @ViewBuilder
  private func choices(suggestion: OnboardingSizeSuggestion) -> some View {
    VStack(spacing: 12) {
      Button {
        apply(width: suggestion.looksLikeWidth, height: suggestion.looksLikeHeight, choice: .recommended)
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
          apply(
            width: choice.looksLikeWidth, height: choice.looksLikeHeight,
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

  /// The keep/revert bar, exactly the safety shape the picker ships (PD9).
  private var countdownBar: some View {
    VStack(spacing: 12) {
      Text("Keeping this size in \(countdown)s unless you revert")
        .font(.callout)
        .foregroundStyle(OnboardingStyle.bodyColor)
        .contentTransition(.numericText())
      HStack(spacing: 14) {
        Button("Keep") { finishApply() }
          .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
          .keyboardShortcut(.defaultAction)
        Button("Revert") { revert() }
          .buttonStyle(OnboardingSecondaryButtonStyle())
      }
    }
  }

  private func apply(width: Int, height: Int, choice: OnboardingSizeChoice) {
    model.sizeChoices[displayKey] = choice
    withAnimation(.spring(duration: 0.5)) { applied = true }
    countdown = 15
    ticker?.cancel()
    ticker = Task { @MainActor in
      while countdown > 0 {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        withAnimation { countdown -= 1 }
      }
      finishApply()
    }
  }

  private func finishApply() {
    ticker?.cancel()
    model.advance()
  }

  private func revert() {
    ticker?.cancel()
    model.sizeChoices[displayKey] = .keepCurrent
    withAnimation(.spring(duration: 0.4)) { applied = false }
  }
}
