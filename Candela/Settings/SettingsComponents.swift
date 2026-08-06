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
  private let caption: SettingsCaption?
  private let control: Control

  init(_ caption: LocalizedStringKey? = nil, @ViewBuilder control: () -> Control) {
    self.init(caption: caption.map { SettingsCaption($0) }, control: control)
  }

  init(caption: SettingsCaption?, @ViewBuilder control: () -> Control) {
    self.caption = caption
    self.control = control()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      control
      caption
    }
  }
}

/// Secondary explanatory text under a control — the pane-wide caption idiom
/// (replaces the fork's three divergent sectionBox helpers with one component).
///
/// Two initialisers because a sentence with a display name or a count in it
/// cannot be a `LocalizedStringKey` literal, and the alternative — the caller
/// hand-rolling `Text` with the same three modifiers — is how the styling drifts
/// one caption at a time.
struct SettingsCaption: View {
  private let content: Text

  init(_ text: LocalizedStringKey) {
    content = Text(text)
  }

  init(verbatim text: String) {
    content = Text(verbatim: text)
  }

  var body: some View {
    content
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
