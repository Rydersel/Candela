import SwiftUI

/// Which act of the flow the canvas is lighting. The accent shifts per act:
/// cool through detection, the display's warmth through care, green
/// at the finish.
enum OnboardingAct: Equatable {
  case welcome
  case permission
  case detection
  case size
  case oled
  case finish

  init(page: OnboardingPage) {
    switch page {
    case .welcome: self = .welcome
    case .accessibility: self = .permission
    case .detection, .noDisplays: self = .detection
    case .size: self = .size
    case .oledSelect, .oledCare: self = .oled
    case .finish: self = .finish
    }
  }

  var accent: Color {
    switch self {
    case .welcome: Color(red: 0.56, green: 0.36, blue: 1.0)
    case .permission: Color(red: 0.30, green: 0.52, blue: 1.0)
    case .detection: Color(red: 0.20, green: 0.78, blue: 0.92)
    case .size: Color(red: 0.22, green: 0.74, blue: 0.70)
    case .oled: Color(red: 1.0, green: 0.62, blue: 0.26)
    case .finish: Color(red: 0.30, green: 0.85, blue: 0.48)
    }
  }

  /// A second hue for the far blob so the glow reads as an environment, not
  /// a single lamp.
  var secondary: Color {
    switch self {
    case .welcome: Color(red: 0.25, green: 0.30, blue: 0.95)
    case .permission: Color(red: 0.45, green: 0.30, blue: 0.95)
    case .detection: Color(red: 0.25, green: 0.40, blue: 1.0)
    case .size: Color(red: 0.20, green: 0.55, blue: 0.95)
    case .oled: Color(red: 0.85, green: 0.30, blue: 0.55)
    case .finish: Color(red: 0.15, green: 0.60, blue: 0.75)
    }
  }
}

/// The persistent layer under every page: a near-black ground, two
/// drifting glow blobs in the act's hues, and a vignette. Slow movement
/// while the window is being looked at; Reduce Motion stills it entirely.
struct OnboardingCanvas: View {
  var act: OnboardingAct

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var activeState

  /// Off-key time is discounted from the drift clock, so coming back resumes the
  /// motion instead of jumping it forward.
  @State private var offKeySince: Date?
  @State private var offKeyTotal: TimeInterval = 0

  var body: some View {
    ZStack {
      Color(red: 0.035, green: 0.035, blue: 0.06)
      if reduceMotion {
        blobs(at: 0)
      } else if activeState == .key {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
          blobs(at: drift(at: context.date))
        }
      } else {
        // Off-key covers behind another app, minimized and another Space alike.
        blobs(at: drift(at: offKeySince ?? .now))
      }
      // Vignette keeps edges dark so content owns the middle.
      RadialGradient(
        colors: [.clear, Color.black.opacity(0.55)],
        center: .center, startRadius: 180, endRadius: 560
      )
    }
    .animation(.easeInOut(duration: 1.4), value: act)
    .ignoresSafeArea()
    .accessibilityHidden(true)
    .onAppear { if activeState != .key, offKeySince == nil { offKeySince = .now } }
    .onChange(of: activeState) { _, state in
      if state == .key {
        if let since = offKeySince { offKeyTotal += Date.now.timeIntervalSince(since) }
        offKeySince = nil
      } else if offKeySince == nil {
        offKeySince = .now
      }
    }
  }

  private func drift(at date: Date) -> TimeInterval {
    date.timeIntervalSinceReferenceDate - offKeyTotal
  }

  private func blobs(at time: TimeInterval) -> some View {
    GeometryReader { proxy in
      let size = proxy.size
      // Slow orbits, incommensurate periods so the drift never loops visibly.
      let t1 = time / 23
      let t2 = time / 31
      ZStack {
        Circle()
          .fill(act.accent.opacity(0.34))
          .frame(width: size.width * 0.9)
          .blur(radius: 90)
          .position(
            x: size.width * (0.30 + 0.12 * CGFloat(sin(t1))),
            y: size.height * (0.22 + 0.10 * CGFloat(cos(t1 * 1.3)))
          )
        Circle()
          .fill(act.secondary.opacity(0.26))
          .frame(width: size.width * 0.8)
          .blur(radius: 100)
          .position(
            x: size.width * (0.78 - 0.10 * CGFloat(cos(t2))),
            y: size.height * (0.85 + 0.08 * CGFloat(sin(t2 * 1.7)))
          )
      }
    }
  }
}
