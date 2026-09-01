import AppKit
import Combine
import SwiftUI

/// Designation (OB4): every external display as a selectable card, the name
/// guess preselected and labeled as a guess. Nothing is enrolled here; the
/// care page owns that.
struct OnboardingOledSelectPage: View {
  @Bindable var model: OnboardingFlowModel
  let accent: Color

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 22)
      OnboardingHeading(
        title: "Any OLEDs here?",
        subtitle: "OLED displays age where bright, static content sits. \(AppInfo.productName) can protect them from burn-in."
      )
      Spacer(minLength: 18)
      HStack(alignment: .top, spacing: 14) {
        ForEach(model.environment.displays) { display in
          selectCard(for: display)
        }
      }
      .padding(.horizontal, 30)
      if hasNameGuess {
        Text("Candela's OLED detection can make mistakes. Deselect a display if it got one wrong.")
          .font(.caption)
          .foregroundStyle(OnboardingStyle.faintColor)
          .padding(.top, 12)
      }
      Spacer(minLength: 20)
      VStack(spacing: 10) {
        Button(model.designatedOleds.isEmpty ? "None of These Are OLEDs" : "Continue") {
          model.advance()
        }
        .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
        .keyboardShortcut(.defaultAction)
        OnboardingSkipLink(model: model)
      }
      Spacer(minLength: 24)
    }
  }

  private var hasNameGuess: Bool {
    model.environment.displays.contains {
      OnboardingPlan.suggestsOled(productName: $0.productName)
        && model.designatedOleds.contains($0.persistenceKey)
    }
  }

  private func selectCard(for display: OnboardingDisplayEntry) -> some View {
    let key = display.persistenceKey
    let selected = model.designatedOleds.contains(key)
    return Button {
      withAnimation(.spring(duration: 0.35)) {
        if selected {
          model.designatedOleds.remove(key)
          model.careEnabled.remove(key)
        } else {
          model.designatedOleds.insert(key)
          model.careEnabled.insert(key)
        }
      }
    } label: {
      OnboardingCard(isSelected: selected, accent: accent) {
        VStack(alignment: .leading, spacing: 10) {
          DisplayGlyph(
            aspect: display.drawnAspect, accent: selected ? accent : .white.opacity(0.5),
            lit: selected ? 1 : 0.4, showsReflection: false
          )
          .frame(height: 76)
          .frame(maxWidth: .infinity)
          HStack {
            Text(model.displayName(forKey: key))
              .font(.headline)
              .foregroundStyle(OnboardingStyle.titleColor)
              .lineLimit(1)
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              .font(.title3)
              .foregroundStyle(selected ? accent : OnboardingStyle.faintColor)
          }
          if OnboardingPlan.suggestsOled(productName: display.productName) {
            Text("Detected as OLED")
              .font(.caption)
              .foregroundStyle(selected ? accent : OnboardingStyle.faintColor)
          }
        }
      }
      .frame(maxWidth: 280)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "\(model.displayName(forKey: key)), \(selected ? "marked as OLED" : "not marked as OLED")")
  }
}

/// Care (OB5): a miniature demonstration instead of prose, per-display
/// protection, and the measurement choice with Screen Recording as the
/// recommended path.
struct OnboardingOledCarePage: View {
  @Bindable var model: OnboardingFlowModel
  let accent: Color

  private var designated: [OnboardingDisplayEntry] {
    model.environment.displays.filter { model.designatedOleds.contains($0.persistenceKey) }
  }

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 18)
      OnboardingHeading(
        title: "Protect your OLED",
        subtitle: "When you step away, \(AppInfo.productName) eases brightness down and shields the areas that never change, then puts everything back the moment you return."
      )
      Spacer(minLength: 14)
      HStack(alignment: .center, spacing: 26) {
        OnboardingCareDemo(accent: accent, aspect: designated.first?.drawnAspect ?? 16.0 / 9.0)
          .frame(width: 220, height: 150)
        VStack(alignment: .leading, spacing: 10) {
          ForEach(designated) { display in
            protectRow(for: display)
          }
        }
      }
      Spacer(minLength: 14)
      measurementChoice
      Spacer(minLength: 16)
      VStack(spacing: 10) {
        Button("Continue") {
          // Measured is the preselected default, so the recommended path
          // must raise the ask even when the card was never clicked;
          // otherwise the pref lands with no grant behind it.
          if model.measuredTelemetry && !model.screenRecordingRequested {
            model.requestScreenRecording()
          }
          model.advance()
        }
        .buttonStyle(OnboardingPrimaryButtonStyle(accent: accent))
        .keyboardShortcut(.defaultAction)
        OnboardingSkipLink(model: model)
      }
      Spacer(minLength: 22)
    }
    // The grant can land outside the app (System Settings), so the copy
    // re-checks whenever the page comes back on screen.
    .onAppear { model.refreshScreenRecordingGranted() }
    // Coming back from System Settings does not re-run `onAppear` (the page was
    // never removed), so the grant would go unnoticed until the next page turn.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      model.refreshScreenRecordingGranted()
    }
  }

  /// The same toggle for every designated display, enrolled or not: a display
  /// enrolled before this run arrives with it on, and turning it off is the
  /// flow's un-enrollment.
  private func protectRow(for display: OnboardingDisplayEntry) -> some View {
    let key = display.persistenceKey
    return Toggle(isOn: Binding(
      get: { model.careEnabled.contains(key) },
      set: { on in
        if on { model.careEnabled.insert(key) } else { model.careEnabled.remove(key) }
      }
    )) {
      Text("Protect \(model.displayName(forKey: key))")
        .foregroundStyle(OnboardingStyle.bodyColor)
    }
    .toggleStyle(.switch)
    .tint(accent)
  }

  /// OB5: measured is the recommended path; the estimate is the honest
  /// fallback and says so.
  private var measurementChoice: some View {
    HStack(spacing: 12) {
      measurementCard(
        selected: model.measuredTelemetry,
        title: "Measured",
        badge: "Recommended",
        text: measuredCardText
      ) {
        model.measuredTelemetry = true
        if !model.screenRecordingRequested {
          model.requestScreenRecording()
        }
      }
      measurementCard(
        selected: !model.measuredTelemetry,
        title: "Estimated",
        badge: nil,
        text: "No extra permission. Health figures are estimates and less accurate."
      ) {
        model.measuredTelemetry = false
      }
    }
    .padding(.horizontal, 40)
  }

  /// Keyed on what actually happened, never on the click alone: the enabled line
  /// appears only once the preflight confirms the grant.
  private var measuredCardText: String {
    guard model.screenRecordingRequested && model.measuredTelemetry else {
      return "Uses Screen Recording to measure how bright each part of the display is, once a minute. Health figures are measured rather than estimated."
    }
    if model.screenRecordingGranted {
      return "Screen Recording enabled. \(AppInfo.productName) reads the picture only to average its brightness; nothing leaves your Mac."
    }
    return "Waiting for permission. Turn on \(AppInfo.productName) in System Settings, under Privacy & Security, Screen Recording. Health figures stay estimates until then."
  }

  private func measurementCard(
    selected: Bool, title: String, badge: String?, text: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      OnboardingCard(isSelected: selected, accent: accent) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            Text(title)
              .font(.headline)
              .foregroundStyle(OnboardingStyle.titleColor)
            if let badge {
              Text(badge)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(accent.opacity(0.25)))
                .foregroundStyle(accent)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(selected ? accent : OnboardingStyle.faintColor)
          }
          Text(text)
            .font(.caption)
            .foregroundStyle(OnboardingStyle.bodyColor)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .buttonStyle(.plain)
  }
}

/// The demonstration loop: the menu bar band dims, then the whole face eases
/// down, then everything comes back. Repeats gently; Reduce Motion shows the
/// dimmed state as a still.
struct OnboardingCareDemo: View {
  let accent: Color
  var aspect: Double

  @State private var stage = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    DisplayGlyph(
      aspect: aspect,
      accent: accent,
      lit: stage == 2 ? 0.3 : 1,
      faceOverlay: AnyView(demoOverlay)
    )
    .task { await runLoop() }
  }

  private var demoOverlay: some View {
    VStack(spacing: 0) {
      Rectangle()
        .fill(Color.black.opacity(stage >= 1 ? 0.55 : 0))
        .frame(height: 10)
      HStack {
        Spacer()
        // The idle-dim stage gets its moon: asleep, not off.
        Image(systemName: "moon.fill")
          .font(.system(size: 13))
          .foregroundStyle(.white.opacity(0.75))
          .shadow(color: .white.opacity(0.4), radius: 4)
          .padding(7)
          .opacity(stage == 2 ? 1 : 0)
          .accessibilityHidden(true)
      }
      Spacer()
      Text(caption)
        .font(.caption2)
        .foregroundStyle(OnboardingStyle.bodyColor)
        .padding(.bottom, 6)
        .contentTransition(.opacity)
    }
  }

  private var caption: String {
    switch stage {
    case 1: "Shields static areas"
    case 2: "Eases brightness down when idle"
    default: "Watching for idle time"
    }
  }

  private func runLoop() async {
    if reduceMotion {
      stage = 2
      return
    }
    while !Task.isCancelled {
      try? await Task.sleep(for: .seconds(1.6))
      withAnimation(.easeInOut(duration: 0.8)) { stage = 1 }
      try? await Task.sleep(for: .seconds(1.6))
      withAnimation(.easeInOut(duration: 1.2)) { stage = 2 }
      try? await Task.sleep(for: .seconds(2.2))
      withAnimation(.easeInOut(duration: 0.8)) { stage = 0 }
    }
  }
}
