import SwiftUI

/// Welcome: one large softly-lit display object under ambient light, the
/// pitch, and Begin Setup. The set piece is the product's subject, not
/// decoration (OB10).
struct OnboardingWelcomePage: View {
  let model: OnboardingFlowModel
  let accent: Color

  @State private var appeared = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 24)
      DisplayGlyph(aspect: heroAspect, accent: accent)
        .frame(width: 300, height: 210)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
      Spacer(minLength: 18)
      OnboardingHeading(
        title: "Welcome to \(AppInfo.productName)",
        subtitle: "\(AppInfo.productName) looks after your external displays: health, burn-in protection, and the everyday controls, done carefully."
      )
      .opacity(appeared ? 1 : 0)
      .offset(y: appeared ? 0 : 10)
      Spacer(minLength: 22)
      VStack(spacing: 10) {
        Button("Begin Setup") { model.advance() }
          .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
          .keyboardShortcut(.defaultAction)
        OnboardingSkipLink(model: model)
      }
      .opacity(appeared ? 1 : 0)
      Spacer(minLength: 30)
    }
    .onAppear {
      withAnimation(reduceMotion ? .easeIn(duration: 0.3) : .spring(duration: 0.9)) {
        appeared = true
      }
    }
  }

  /// The user's own first display when there is one; a plain wide face when
  /// there is not.
  private var heroAspect: Double {
    model.environment.displays.first?.drawnAspect ?? (16.0 / 9.0)
  }
}

/// Accessibility: the why in one line before the ask, the prompt, and the
/// live granted state. Skippable; the app warns later where it matters.
struct OnboardingAccessibilityPage: View {
  @Bindable var model: OnboardingFlowModel
  let accent: Color

  var body: some View {
    VStack(spacing: 0) {
      Spacer()
      // Keys and words are one unit: fixed spacing binds them, so the
      // stretch lands around the group rather than between its parts.
      VStack(spacing: 18) {
        keycaps
        OnboardingHeading(
          title: "Your keyboard, everywhere",
          subtitle: "macOS delivers the brightness, volume and mute keys through Accessibility. \(AppInfo.productName) needs that access to see those key presses, and it reads nothing else."
        )
      }
      Spacer()
      // The actions are one cluster pinned to the bottom: the primary
      // directly above its quiet escape, never floating mid-page.
      VStack(spacing: 12) {
        permissionState
        if !model.accessibilityGranted {
          Button("Not Now") { model.advance() }
            .buttonStyle(OnboardingLinkButtonStyle())
        }
        OnboardingSkipLink(model: model)
      }
      .padding(.bottom, 44)
    }
  }

  /// The symbols the keys themselves carry, never decorative icons: this row is
  /// the keyboard the user is looking at.
  private var keycaps: some View {
    HStack(spacing: 14) {
      keycap("sun.max.fill")
      keycap("speaker.wave.2.fill")
      keycap("speaker.slash.fill")
    }
    .accessibilityHidden(true)
  }

  private func keycap(_ symbol: String) -> some View {
    Image(systemName: symbol)
      .font(.system(size: 24, weight: .medium))
      .foregroundStyle(.white.opacity(0.9))
      .frame(width: 64, height: 64)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.white.opacity(0.14), .white.opacity(0.05)],
              startPoint: .top, endPoint: .bottom
            )
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(accent.opacity(0.5), lineWidth: 1)
      )
      .shadow(color: accent.opacity(0.35), radius: 10, y: 3)
  }

  @ViewBuilder
  private var permissionState: some View {
    if model.accessibilityGranted {
      VStack(spacing: 14) {
        Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
          .font(.headline)
          .foregroundStyle(Color(red: 0.35, green: 0.9, blue: 0.5))
        Button("Continue") { model.advance() }
          .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
          .keyboardShortcut(.defaultAction)
      }
      .transition(.opacity)
    } else if model.accessibilityRequested {
      VStack(spacing: 10) {
        Button("Open System Settings…") { model.openAccessibilitySettings() }
          .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
        Text("Turn \(AppInfo.productName) on under Privacy & Security, Accessibility. This page updates on its own once you do.")
          .font(.caption)
          .foregroundStyle(OnboardingStyle.faintColor)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 380)
      }
    } else {
      Button("Allow Accessibility Access") { model.requestAccessibility() }
        .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
        .keyboardShortcut(.defaultAction)
    }
  }
}

/// The slim flow's pivot: no external display connected right now.
struct OnboardingNoDisplaysPage: View {
  let model: OnboardingFlowModel
  let accent: Color

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 30)
      DisplayGlyph(aspect: 16.0 / 9.0, accent: accent, lit: 0.25)
        .frame(width: 240, height: 170)
      Spacer(minLength: 20)
      OnboardingHeading(
        title: "No external displays yet",
        subtitle: "Plug one in anytime. \(AppInfo.productName) picks it up automatically and offers the right size for it in Settings."
      )
      Spacer(minLength: 24)
      VStack(spacing: 10) {
        Button("Continue") { model.advance() }
          .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
          .keyboardShortcut(.defaultAction)
        OnboardingSkipLink(model: model)
      }
      Spacer(minLength: 30)
    }
  }
}

/// Finish: the green bloom, a cascade of what was configured, and the OB13
/// launch at login decision.
struct OnboardingFinishPage: View {
  @Bindable var model: OnboardingFlowModel
  let accent: Color

  @State private var revealed = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 26)
      // Check and title are one unit; fixed spacing keeps them together.
      // The mark draws itself in, then idles on the float.
      VStack(spacing: 14) {
        AnimatedCheckmark(accent: accent)
          .frame(width: 68, height: 68)
          .onboardingFloat(active: true)
        OnboardingHeading(title: "You're all set")
      }
      Spacer(minLength: 18)
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(summaryLines.enumerated()), id: \.offset) { pair in
          summaryRow(pair.element)
            .opacity(revealed > pair.offset + 1 ? 1 : 0)
            .offset(x: revealed > pair.offset + 1 ? 0 : -8)
        }
      }
      .frame(maxWidth: 400, alignment: .leading)
      Spacer(minLength: 18)
      // A switch, not a checkbox: a checked box under a page of green
      // checks reads as one more completed item, not a decision to make.
      Toggle(isOn: $model.launchAtLogin) {
        Text("Open \(AppInfo.productName) at login")
          .foregroundStyle(OnboardingStyle.bodyColor)
      }
      .toggleStyle(.switch)
      .controlSize(.small)
      .tint(accent)
      .fixedSize()
      Spacer(minLength: 16)
      Button("Start Using \(AppInfo.productName)") { model.advance() }
        .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
        .keyboardShortcut(.defaultAction)
      Spacer(minLength: 26)
    }
    .onAppear { reveal() }
  }

  private func summaryRow(_ line: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(accent)
      Text(line)
        .foregroundStyle(OnboardingStyle.bodyColor)
    }
    .font(.callout)
  }

  private var summaryLines: [String] {
    var lines: [String] = []
    lines.append(
      model.accessibilityGranted
        ? "Keyboard keys are ready to use"
        : "Keyboard access can be granted later in Settings")
    let displayCount = model.environment.displays.count
    if displayCount > 0 {
      lines.append(displayCount == 1 ? "1 display configured" : "\(displayCount) displays configured")
    }
    let protected = model.designatedOleds.intersection(model.careEnabled).count
    if protected > 0 {
      lines.append(protected == 1 ? "OLED care is protecting 1 display" : "OLED care is protecting \(protected) displays")
    }
    return lines
  }

  private func reveal() {
    let steps = summaryLines.count + 1
    guard !reduceMotion else {
      revealed = steps + 1
      return
    }
    revealed = 0
    for step in 1...(steps + 1) {
      withAnimation(.spring(duration: 0.5).delay(0.15 * Double(step))) {
        revealed = step
      }
    }
  }
}
