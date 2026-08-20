import SwiftUI

/// The scan set piece (OB10): a light sweep, outlines tracing in one per
/// display, then the cards resolve with real facts. Roughly two seconds,
/// always click-through-able; Reduce Motion skips straight to the cards.
struct OnboardingDetectionPage: View {
  @Bindable var model: OnboardingFlowModel
  let accent: Color

  /// 0 = sweeping, then one step per display outline, then cards.
  @State private var phase = 0
  @State private var sweep: CGFloat = -0.2
  /// Real-time staging: a delayed `withAnimation` changes the VALUE
  /// immediately (only the animation is delayed), so structural conditions
  /// like the title flip early. The task sleeps for real.
  @State private var scanTask: Task<Void, Never>?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var displays: [OnboardingDisplayEntry] { model.environment.displays }
  private var cardsShown: Bool { phase > displays.count }

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 18)
      OnboardingHeading(
        title: cardsShown ? foundTitle : "Looking at your displays",
        subtitle: cardsShown
          ? "Names can be edited here. Anything else that looks wrong can be adjusted later in Settings."
          : nil
      )
      .animation(.easeInOut(duration: 0.4), value: cardsShown)
      Spacer(minLength: 16)
      glyphRow
      Spacer(minLength: 16)
      if cardsShown {
        cards
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        Spacer(minLength: 16)
        VStack(spacing: 10) {
          Button("Continue") { model.advance() }
            .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
            .keyboardShortcut(.defaultAction)
          OnboardingSkipLink(model: model)
        }
      }
      Spacer(minLength: 22)
    }
    .contentShape(Rectangle())
    .onTapGesture { skipScan() }
    .onAppear { runScan() }
    .onDisappear { scanTask?.cancel() }
  }

  private var foundTitle: String {
    displays.count == 1 ? "Found your display" : "Found \(displays.count) displays"
  }

  private var glyphRow: some View {
    ZStack {
      HStack(alignment: .bottom, spacing: 34) {
        ForEach(Array(displays.enumerated()), id: \.element.id) { pair in
          DisplayGlyph(
            aspect: pair.element.drawnAspect,
            accent: accent,
            trace: phase > pair.offset ? 1 : 0,
            lit: cardsShown ? 1 : 0.35
          )
          .frame(height: cardsShown ? 110 : 150)
          .frame(width: glyphWidth(for: pair.element, tall: !cardsShown))
        }
      }
      .animation(.spring(duration: 0.7), value: cardsShown)
      .animation(.easeInOut(duration: 0.55), value: phase)
      if !cardsShown, !reduceMotion {
        sweepBand
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: cardsShown ? 120 : 170)
    .clipped()
  }

  private func glyphWidth(for display: OnboardingDisplayEntry, tall: Bool) -> CGFloat {
    let height: CGFloat = tall ? 150 : 110
    let faceHeight = height * 0.7
    return max(70, faceHeight * display.drawnAspect + 20)
  }

  /// The traveling light pass over the dark rig.
  private var sweepBand: some View {
    GeometryReader { proxy in
      LinearGradient(
        colors: [.clear, accent.opacity(0.35), .white.opacity(0.4), accent.opacity(0.35), .clear],
        startPoint: .leading, endPoint: .trailing
      )
      .frame(width: 90)
      .blur(radius: 8)
      .offset(x: sweep * (proxy.size.width + 180) - 90)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var cards: some View {
    HStack(alignment: .top, spacing: 14) {
      ForEach(displays) { display in
        card(for: display)
      }
    }
    .padding(.horizontal, 30)
  }

  private func card(for display: OnboardingDisplayEntry) -> some View {
    OnboardingCard {
      VStack(alignment: .leading, spacing: 7) {
        TextField(
          "Name",
          text: Binding(
            get: { model.renames[display.persistenceKey] ?? display.name },
            set: { model.renames[display.persistenceKey] = $0 }
          )
        )
        .textFieldStyle(.plain)
        .font(.headline)
        .foregroundStyle(OnboardingStyle.titleColor)
        factRow(symbol: "ruler", text: geometryLine(for: display))
        factRow(symbol: "gauge.with.dots.needle.67percent", text: refreshLine(for: display))
        factRow(symbol: "slider.horizontal.3", text: controlLine(for: display))
      }
    }
    .frame(maxWidth: 300)
  }

  private func factRow(symbol: String, text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .font(.caption)
        .foregroundStyle(accent.opacity(0.9))
        .frame(width: 14)
        .accessibilityHidden(true)
      Text(text)
        .font(.callout)
        .foregroundStyle(OnboardingStyle.bodyColor)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func geometryLine(for display: OnboardingDisplayEntry) -> String {
    var line = "\(display.nativePixelWidth) x \(display.nativePixelHeight)"
    if let inches = display.diagonalInches {
      line += ", \(Int(inches.rounded())) inch"
    }
    if display.rotationDegrees != 0 {
      line += ", rotated \(display.rotationDegrees)\u{00B0}"
    }
    return line
  }

  private func refreshLine(for display: OnboardingDisplayEntry) -> String {
    "Up to \(Int(display.refreshHz.rounded())) Hz"
  }

  /// OB9: state what works; the display's own denial is its report, and
  /// unknown is never called a failure. Unknown is also never called
  /// verified: a display that answers no reads (the write-only case) cannot
  /// confirm anything, so its line states what the app offers, not what the
  /// display responded to.
  private func controlLine(for display: OnboardingDisplayEntry) -> String {
    switch display.volume {
    case .works:
      "Brightness, contrast and volume respond to \(AppInfo.productName)"
    case .unknown:
      "\(AppInfo.productName) offers brightness, contrast and volume controls"
    case .declinedByDisplay:
      "Brightness and contrast respond; this display reports no volume control"
    }
  }

  private func runScan() {
    guard !cardsShown else { return }
    if reduceMotion {
      phase = displays.count + 1
      return
    }
    withAnimation(.easeInOut(duration: 1.6)) { sweep = 1.2 }
    scanTask = Task { @MainActor in
      for step in 1...(displays.count + 1) {
        try? await Task.sleep(for: .seconds(0.55))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.5)) { phase = step }
      }
    }
  }

  private func skipScan() {
    guard !cardsShown else { return }
    scanTask?.cancel()
    withAnimation(.easeOut(duration: 0.25)) { phase = displays.count + 1 }
  }
}
