import SwiftUI

/// A control and the caption explaining it, as ONE `Form` row.
///
/// A caption placed as its own row gets a divider above it and full row
/// padding, so every piece of help text reads as a separate setting and the
/// page grows to roughly twice the height it needs. `listRowSeparator` and
/// `listRowInsets` do not fix that — neither applies inside a grouped `Form`
/// on macOS (measured: no visible change). Putting both in one row is what
/// actually binds the explanation to the thing it explains, which is how
/// System Settings tucks its secondary text under a control.
struct SettingRow<Control: View>: View {
  private let caption: LocalizedStringKey?
  private let control: Control

  init(_ caption: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
    self.caption = caption
    self.control = control()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      control
      if let caption {
        SettingsCaption(caption)
      }
    }
  }
}

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
