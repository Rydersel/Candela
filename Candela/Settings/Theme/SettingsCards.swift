import SwiftUI

/// The onboarding card at settings density: tighter corner and padding.
struct SettingsCard<Content: View>: View {
  /// Lit in the destination accent when the card's subject is on. Not a
  /// selection cursor.
  var isLit = false
  @ViewBuilder var content: Content

  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    content
      .padding(.horizontal, 14)
      .padding(.vertical, SettingsTheme.cardVerticalPadding)
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
/// several cards. Literally the kicker `SettingsCardSection` draws, so the two
/// cannot drift.
struct SettingsSectionTitle: View {
  let text: String

  @Environment(\.settingsAccent) private var lighting
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Text(text.uppercased())
      .font(.caption.weight(.semibold))
      .kerning(1.1)
      // A kicker over a disabled section is the loudest thing on it otherwise.
      .foregroundStyle(
        lighting.accent.opacity(isEnabled ? 0.85 : 0.85 * SettingsTheme.disabledOpacity))
      .padding(.leading, 4)
      // The uppercasing is typography; VoiceOver gets the written name.
      .accessibilityLabel(Text(text))
      .settingsHeading()
  }
}

/// A titled group of rows on one card, this window's answer to a `Form`
/// section. The kicker is a VoiceOver heading like every other section header.
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

/// A state the page is in, said once.
///
/// Monochrome on purpose. The symbol carries the state alongside the words so
/// nothing is signalled by color alone, and it stays at `faintColor` rather
/// than the destination accent, which here means "this is on". Outer spacing
/// belongs to the call site.
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

/// A sentence with no control of its own, in the voice `SettingRow` gives a
/// caption, so two kinds of qualifier on one card carry the same weight.
struct SettingsRowNote: View {
  private let sentence: Text

  @Environment(\.settingsRowIsPadded) private var rowIsPadded
  @Environment(\.isEnabled) private var isEnabled

  init(_ sentence: LocalizedStringKey) {
    self.sentence = Text(sentence)
  }

  /// For a sentence carrying a display name or a count, which cannot be a
  /// `LocalizedStringKey`.
  init(verbatim sentence: String) {
    self.sentence = Text(verbatim: sentence)
  }

  var body: some View {
    sentence
      .font(.caption)
      .foregroundStyle(SettingsTheme.faintColor)
      .fixedSize(horizontal: false, vertical: true)
      .opacity(isEnabled ? 1 : SettingsTheme.disabledOpacity)
      // Standing on the card this is a row of its own; nested, the row wrapper
      // already paid.
      .padding(.vertical, rowIsPadded ? 0 : SettingsTheme.rowVerticalPadding)
  }
}
