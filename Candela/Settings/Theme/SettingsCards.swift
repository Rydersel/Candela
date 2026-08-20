import SwiftUI

/// The settings surface: the onboarding card at settings sharpness. Tighter
/// corner and padding than the flow's card, macOS density over stage presence.
struct SettingsCard<Content: View>: View {
  var isSelected = false
  @ViewBuilder var content: Content

  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    content
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
          .fill(isSelected ? lighting.accent.opacity(0.12) : SettingsTheme.cardFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
          .stroke(
            isSelected ? lighting.accent.opacity(0.5) : SettingsTheme.cardStroke,
            lineWidth: 1)
      )
  }
}

/// A titled group of rows on one card: this window's answer to a `Form`
/// section. The kicker is a VoiceOver heading like every other settings section
/// header (accessibility contract 4).
struct SettingsCardSection<Content: View>: View {
  var title: String?
  @ViewBuilder var content: Content

  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let title {
        Text(title.uppercased())
          .font(.caption.weight(.semibold))
          .kerning(1.1)
          .foregroundStyle(lighting.accent.opacity(0.85))
          .padding(.leading, 4)
          // The uppercasing is typography; VoiceOver gets the written name.
          .accessibilityLabel(Text(title))
          .settingsHeading()
      }
      SettingsCard {
        VStack(alignment: .leading, spacing: 0) {
          content
        }
      }
    }
  }
}

/// Hairline between rows on one card.
struct SettingsCardDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color.white.opacity(0.07))
      .frame(height: 1)
  }
}
