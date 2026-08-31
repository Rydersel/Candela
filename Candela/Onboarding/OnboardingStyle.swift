import SwiftUI

/// Shared styling for the guided setup flow. The window is forced dark
/// (OB10), so these paint explicit whites over the canvas rather than
/// semantic colors that would follow a theme the window never shows.
enum OnboardingStyle {
  static let titleColor = Color.white
  static let bodyColor = Color.white.opacity(0.68)
  static let faintColor = Color.white.opacity(0.42)
  static let cardFill = Color.white.opacity(0.055)
  static let cardStroke = Color.white.opacity(0.10)
}

/// The one prominent control per page: a glowing accent capsule whose glow
/// lifts slightly on hover.
struct OnboardingPrimaryButtonStyle: ButtonStyle {
  var accent: Color

  func makeBody(configuration: Configuration) -> some View {
    HoverLabel(configuration: configuration, accent: accent)
  }

  private struct HoverLabel: View {
    let configuration: Configuration
    let accent: Color
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.horizontal, 26)
        .padding(.vertical, 11)
        .background(
          Capsule()
            .fill(
              LinearGradient(
                colors: [accent.opacity(hovering ? 1 : 0.95), accent.opacity(hovering ? 0.75 : 0.65)],
                startPoint: .top, endPoint: .bottom
              )
            )
        )
        .overlay(Capsule().stroke(.white.opacity(hovering ? 0.4 : 0.25), lineWidth: 0.5))
        .shadow(
          color: accent.opacity(configuration.isPressed ? 0.25 : (hovering ? 0.7 : 0.55)),
          radius: hovering ? 18 : 14, y: 4
        )
        .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.02 : 1))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
  }
}

/// Quiet secondary action: a hairline capsule that brightens on hover so it
/// reads as clickable before it is clicked.
struct OnboardingSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverLabel(configuration: configuration)
  }

  private struct HoverLabel: View {
    let configuration: Configuration
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(.callout.weight(.medium))
        .foregroundStyle(hovering ? OnboardingStyle.titleColor : OnboardingStyle.bodyColor)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(
          Capsule().fill(
            Color.white.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.10 : 0.06)))
        )
        .overlay(Capsule().stroke(Color.white.opacity(hovering ? 0.28 : 0.14), lineWidth: 0.5))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
  }
}

/// Bare text link. Hover gives it a faint capsule and brightens the text;
/// without that it reads as a caption rather than a control.
struct OnboardingLinkButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverLabel(configuration: configuration)
  }

  private struct HoverLabel: View {
    let configuration: Configuration
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(.callout)
        .foregroundStyle(
          configuration.isPressed
            ? OnboardingStyle.titleColor
            : (hovering ? OnboardingStyle.bodyColor : OnboardingStyle.faintColor)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(hovering ? 0.08 : 0)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
  }
}

/// The rounded translucent surface page content sits on when it needs a
/// surface at all.
struct OnboardingCard<Content: View>: View {
  var isSelected = false
  var accent: Color = .white
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(isSelected ? accent.opacity(0.12) : OnboardingStyle.cardFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(
            isSelected ? accent.opacity(0.65) : OnboardingStyle.cardStroke,
            lineWidth: isSelected ? 1.5 : 1
          )
      )
  }
}

/// Rendered under every page's primary action, so the exit is always in the
/// same place.
@MainActor
struct OnboardingSkipLink: View {
  let model: OnboardingFlowModel

  var body: some View {
    Button("Skip Setup") { model.skip() }
      .buttonStyle(OnboardingLinkButtonStyle())
  }
}

/// A slow idle bob for hero objects, so a resting page keeps a pulse.
/// Reduce Motion stills it.
struct OnboardingFloatModifier: ViewModifier {
  var active: Bool

  @State private var up = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .offset(y: up ? -4 : 3)
      .onAppear { updateFloat() }
      .onChange(of: active) { updateFloat() }
      // Reduce Motion turned on while the page is open stops the float now,
      // not at the next rebuild.
      .onChange(of: reduceMotion) { updateFloat() }
  }

  private func updateFloat() {
    guard active, !reduceMotion else {
      var stop = Transaction()
      stop.disablesAnimations = true
      withTransaction(stop) { up = false }
      return
    }
    withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
      up = true
    }
  }
}

extension View {
  func onboardingFloat(active: Bool) -> some View {
    modifier(OnboardingFloatModifier(active: active))
  }
}

/// Title and subtitle lockup every page opens with.
struct OnboardingHeading: View {
  var title: String
  var subtitle: String?

  var body: some View {
    VStack(spacing: 8) {
      Text(title)
        .font(.system(size: 30, weight: .bold, design: .rounded))
        .foregroundStyle(OnboardingStyle.titleColor)
        .multilineTextAlignment(.center)
      if let subtitle {
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(OnboardingStyle.bodyColor)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 460)
      }
    }
  }
}
