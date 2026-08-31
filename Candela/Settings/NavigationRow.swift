import SwiftUI

/// A chevron row that pushes a sub-page, with the sub-page's current value
/// previewed on the right.
///
/// ONE accessibility element carrying the button trait: the chevron is
/// decoration, and the value gets a spoken form so VoiceOver reads
/// `2,560 by 1,440 at 60 hertz` rather than the glyph-packed display string. At
/// accessibility text sizes `ViewThatFits` drops the value onto its own line
/// instead of truncating.
///
/// Never `.accessibilityElement(children: .ignore)` on a `Button`. It does not
/// annotate the button's element, it REPLACES it with a synthesized generic one:
/// measured on macOS 26, the row lost `AXPress` (an `AXUIElementPerformAction`
/// still returned `.success` and pushed nothing) and lost `AXFocused` outright,
/// so a screen-reader user could not reach the pushed pages at all.
/// `.accessibilityAction` gives the press back but not the focus. The `Button`
/// is already one element with the button trait and merges its own content.
struct NavigationRow: View {
  let title: String
  let value: String?
  var spokenValue: String? = nil
  let action: () -> Void

  @State private var hovering = false
  @Environment(\.settingsAccent) private var lighting

  var body: some View {
    Button(action: action) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          titleText
          Spacer(minLength: 16)
          // Only on this candidate: a wrapping value would let the row "fit"
          // at any width and the fallback would never be reached.
          valueText.lineLimit(1)
          chevron
        }
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 12) {
            titleText
            Spacer(minLength: 16)
            chevron
          }
          valueText
        }
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 6)
      // The lift is the only thing saying a card row is a doorway; the chevron
      // alone reads as decoration at this density.
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .fill(Color.white.opacity(hovering ? 0.06 : 0))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(SettingsTheme.hoverMotion, value: hovering)
    .accessibilityLabel(title)
    .accessibilityValue(spokenValue ?? value ?? "")
  }

  private var titleText: some View {
    Text(title).foregroundStyle(SettingsTheme.titleColor)
  }

  @ViewBuilder
  private var valueText: some View {
    if let value {
      Text(verbatim: value).foregroundStyle(SettingsTheme.bodyColor)
    }
  }

  private var chevron: some View {
    Image(systemName: "chevron.right")
      .font(.caption.weight(.semibold))
      .foregroundStyle(hovering ? lighting.accent : SettingsTheme.faintColor)
      .accessibilityHidden(true)
  }
}
