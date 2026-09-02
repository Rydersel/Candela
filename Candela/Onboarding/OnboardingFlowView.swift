import SwiftUI

/// The flow's root: the persistent canvas, the current page, and the fixed
/// chrome (back, step dots, Skip Setup). Pages slide with a crossfade; Reduce
/// Motion collapses transitions to fades.
struct OnboardingFlowView: View {
  @Bindable var model: OnboardingFlowModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var act: OnboardingAct { OnboardingAct(page: model.currentPage) }

  var body: some View {
    ZStack {
      OnboardingCanvas(act: act)
      page(model.currentPage)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(model.currentPage.id)
        .transition(pageTransition)
      chrome
    }
    .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(duration: 0.55), value: model.currentPage)
    .frame(minWidth: 760, minHeight: 560)
    .preferredColorScheme(.dark)
  }

  private var pageTransition: AnyTransition {
    if reduceMotion {
      return .opacity
    }
    return .asymmetric(
      insertion: .move(edge: .trailing).combined(with: .opacity),
      removal: .move(edge: .leading).combined(with: .opacity)
    )
  }

  @ViewBuilder
  private func page(_ page: OnboardingPage) -> some View {
    switch page {
    case .welcome:
      OnboardingWelcomePage(model: model, accent: act.accent)
    case .accessibility:
      OnboardingAccessibilityPage(model: model, accent: act.accent)
    case .detection:
      OnboardingDetectionPage(model: model, accent: act.accent)
    case .noDisplays:
      OnboardingNoDisplaysPage(model: model, accent: act.accent)
    case let .size(displayKey):
      OnboardingSizePage(model: model, displayKey: displayKey, accent: act.accent)
    case .oledSelect:
      OnboardingOledSelectPage(model: model, accent: act.accent)
    case .oledCare:
      OnboardingOledCarePage(model: model, accent: act.accent)
    case .finish:
      OnboardingFinishPage(model: model, accent: act.accent)
    }
  }

  private var chrome: some View {
    VStack {
      HStack {
        if model.canGoBack, model.currentPage != .finish {
          Button {
            model.back()
          } label: {
            Image(systemName: "chevron.left")
              .font(.body.weight(.semibold))
          }
          .buttonStyle(OnboardingLinkButtonStyle())
          .accessibilityLabel("Back")
        }
        Spacer()
      }
      .padding(.horizontal, 22)
      .padding(.top, 16)
      Spacer()
      // Skip Setup lives under each page's primary action; the rail carries
      // only the dots.
      stepDots
        .padding(.bottom, 12)
    }
  }

  private var stepDots: some View {
    HStack(spacing: 7) {
      ForEach(Array(model.pages.enumerated()), id: \.element.id) { pair in
        Capsule()
          .fill(pair.offset == model.index ? act.accent : Color.white.opacity(0.22))
          .frame(width: pair.offset == model.index ? 18 : 6, height: 6)
      }
    }
    .animation(.spring(duration: 0.4), value: model.index)
    .animation(.spring(duration: 0.4), value: model.pages)
    .accessibilityLabel("Step \(model.index + 1) of \(model.pages.count)")
  }
}
