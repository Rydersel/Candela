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
///
/// The caption is also published as the control's `accessibilityHint`
/// (accessibility contract 3) from here rather than per call site, so it cannot
/// be forgotten on a new row. Both initialisers go through the same seam.
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
      // Attached unconditionally, empty when there is no caption: an `if` here
      // would swap `_ConditionalContent` branches whenever a caption appears or
      // disappears (`MirroringSection`'s cannot-start reason does), rebuilding
      // the control and losing its focus and in-progress edits. The
      // `isEnabled:` overload that would say this directly is macOS 15+.
      control.accessibilityHint(caption?.text ?? Text(verbatim: ""))
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
  /// The unstyled sentence, so `SettingRow` can republish it as a hint.
  /// Deliberately `Text` and not `String`: a `LocalizedStringKey` cannot be read
  /// back as a string, and most callers hand one over — several through
  /// `MirroringCopy`/`RotationCopy`/`DisplayModeCopy`, which are shared with the
  /// confirmation panels and cannot become `String` for this alone.
  let text: Text

  init(_ text: LocalizedStringKey) {
    self.text = Text(text)
  }

  init(verbatim text: String) {
    self.text = Text(verbatim: text)
  }

  var body: some View {
    text
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

extension View {
  /// Every settings section header is a VoiceOver heading (accessibility
  /// contract 4).
  func settingsHeading() -> some View { accessibilityAddTraits(.isHeader) }
}
