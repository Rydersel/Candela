import SwiftUI

/// The window's standard action button: macOS bordered-button geometry
/// (rounded rect, compact padding) with the destination accent carrying the
/// primary. Quieter than the guided setup flow's glowing capsule, which is a
/// stage control; this one sits in a card beside a switch.
struct SettingsPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverLabel(configuration: configuration)
  }

  private struct HoverLabel: View {
    let configuration: Configuration
    @State private var hovering = false
    @Environment(\.settingsAccent) private var lighting
    @Environment(\.isEnabled) private var isEnabled

    /// Hover lives on the pointer, which still moves over a disabled button.
    private var lit: Bool { hovering && isEnabled }

    var body: some View {
      configuration.label
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 5.5)
        .background(
          RoundedRectangle(cornerRadius: 6.5, style: .continuous)
            .fill(lighting.accent.opacity(lit ? 0.9 : 0.78))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6.5, style: .continuous)
            .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .opacity(isEnabled ? 1 : SettingsTheme.disabledOpacity)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        .animation(SettingsTheme.hoverMotion, value: lit)
    }
  }
}

/// Quiet sibling of the primary: same geometry, neutral fill.
struct SettingsSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverLabel(configuration: configuration)
  }

  private struct HoverLabel: View {
    let configuration: Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var lit: Bool { hovering && isEnabled }

    var body: some View {
      configuration.label
        .font(.callout)
        .foregroundStyle(lit ? SettingsTheme.titleColor : SettingsTheme.bodyColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 5.5)
        .background(
          RoundedRectangle(cornerRadius: 6.5, style: .continuous)
            .fill(Color.white.opacity(configuration.isPressed ? 0.13 : (lit ? 0.10 : 0.07)))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6.5, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : SettingsTheme.disabledOpacity)
        .onHover { hovering = $0 }
        .animation(SettingsTheme.hoverMotion, value: lit)
    }
  }
}

/// The secondary in warning red: same macOS geometry, and deliberately not the
/// destination accent, which everywhere else means "this is on".
struct SettingsDangerButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    HoverLabel(configuration: configuration)
  }

  private struct HoverLabel: View {
    let configuration: Configuration
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var lit: Bool { hovering && isEnabled }

    var body: some View {
      configuration.label
        .font(.callout.weight(.medium))
        .foregroundStyle(lit ? Color.white : SettingsTheme.dangerTint)
        .padding(.horizontal, 14)
        .padding(.vertical, 5.5)
        .background(
          RoundedRectangle(cornerRadius: 6.5, style: .continuous)
            .fill(
              SettingsTheme.dangerTint.opacity(
                configuration.isPressed ? 0.38 : (lit ? 0.28 : 0.12)))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6.5, style: .continuous)
            .stroke(SettingsTheme.dangerTint.opacity(lit ? 0.5 : 0.3), lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : SettingsTheme.disabledOpacity)
        .onHover { hovering = $0 }
        .animation(SettingsTheme.hoverMotion, value: lit)
    }
  }
}
