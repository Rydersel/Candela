import SwiftUI

/// The settings surface: the onboarding card at settings sharpness. Tighter
/// corner and padding than the flow's card, macOS density over stage presence.
struct SettingsCard<Content: View>: View {
  /// Lit in the destination accent: the card's subject is on, enrolled, or
  /// otherwise the one the page is about. Not a selection cursor.
  var isLit = false
  @ViewBuilder var content: Content

  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    content
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
          .fill(isLit ? lighting.accent.opacity(0.12) : SettingsTheme.cardFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
          .stroke(
            isLit ? lighting.accent.opacity(0.5) : SettingsTheme.cardStroke,
            lineWidth: 1)
      )
  }
}

/// A section kicker with no card under it, for a stretch of page that is
/// several cards rather than one. Same type, same accent, same heading trait as
/// the kicker `SettingsCardSection` draws, because it is that kicker.
struct SettingsSectionTitle: View {
  let text: String

  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    Text(text.uppercased())
      .font(.caption.weight(.semibold))
      .kerning(1.1)
      .foregroundStyle(lighting.accent.opacity(0.85))
      .padding(.leading, 4)
      // The uppercasing is typography; VoiceOver gets the written name.
      .accessibilityLabel(Text(text))
      .settingsHeading()
  }
}

/// A titled group of rows on one card: this window's answer to a `Form`
/// section. The kicker is a VoiceOver heading like every other settings section
/// header (accessibility contract 4).
struct SettingsCardSection<Content: View>: View {
  var title: String?
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if let title {
        SettingsSectionTitle(text: title)
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

/// A state the page is in, said once: a leading symbol and the sentences that
/// explain it.
///
/// Monochrome on purpose. The symbol carries the state alongside the words, so
/// nothing is signalled by color alone, and it stays at `faintColor` rather
/// than taking the destination accent, which in this window means "this is on".
/// Outer spacing belongs to the call site: where a notice sits in its card is a
/// property of the card, not of the notice.
struct SettingsNotice<Content: View>: View {
  var symbol: String = "exclamationmark.triangle"
  /// False where the notice already sits on a card, which would otherwise draw
  /// a second surface inside the first.
  var drawsSurface = true
  @ViewBuilder var content: Content

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: symbol)
        .foregroundStyle(SettingsTheme.faintColor)
      VStack(alignment: .leading, spacing: 4) { content }
        .foregroundStyle(SettingsTheme.titleColor)
    }
    .padding(drawsSurface ? 11 : 0)
    .background(surface)
    .overlay(edge)
  }

  @ViewBuilder private var surface: some View {
    if drawsSurface {
      RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
        .fill(SettingsTheme.cardFill)
    }
  }

  @ViewBuilder private var edge: some View {
    if drawsSurface {
      RoundedRectangle(cornerRadius: SettingsTheme.cardRadius, style: .continuous)
        .stroke(SettingsTheme.cardStroke, lineWidth: 1)
    }
  }
}

/// A qualifier at row weight inside a card: a sentence with no control of its
/// own, in the voice `SettingRow` gives a caption, so two kinds of qualifier on
/// one card carry the same weight.
struct SettingsRowNote: View {
  private let sentence: LocalizedStringKey

  init(_ sentence: LocalizedStringKey) {
    self.sentence = sentence
  }

  var body: some View {
    Text(sentence)
      .font(.caption)
      .foregroundStyle(SettingsTheme.faintColor)
      .fixedSize(horizontal: false, vertical: true)
  }
}
