import SwiftUI

/// A chevron row that pushes a sub-page, with the sub-page's current value
/// previewed on the right.
///
/// ONE accessibility element carrying the button trait (accessibility contract
/// 5): the chevron is decoration, and the value gets a spoken form so VoiceOver
/// reads `2,560 by 1,440 at 60 hertz` rather than the glyph-packed display
/// string. At accessibility text sizes the value drops onto its own line
/// instead of truncating (contract 10) — `ViewThatFits` measures the side-by-side
/// layout's ideal width and falls through when it no longer fits.
struct NavigationRow: View {
  let title: String
  let value: String?
  var spokenValue: String? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          Text(title)
          Spacer(minLength: 8)
          // Only on this candidate: a wrapping value would let the row "fit"
          // at any width and the fallback would never be reached.
          valueText.lineLimit(1)
          chevron
        }
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            chevron
          }
          valueText
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(title)
    .accessibilityValue(spokenValue ?? value ?? "")
  }

  @ViewBuilder
  private var valueText: some View {
    if let value {
      Text(verbatim: value).foregroundStyle(.secondary)
    }
  }

  private var chevron: some View {
    Image(systemName: "chevron.right")
      .font(.caption.weight(.semibold))
      .foregroundStyle(.tertiary)
      .accessibilityHidden(true)
  }
}
