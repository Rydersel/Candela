import SwiftUI

/// Secondary explanatory text under a control — the pane-wide caption idiom
/// (replaces the fork's three divergent sectionBox helpers with one component).
struct SettingsCaption: View {
  let text: LocalizedStringKey

  init(_ text: LocalizedStringKey) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
