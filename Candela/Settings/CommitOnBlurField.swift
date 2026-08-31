import SwiftUI

/// A settings text field that applies what was typed when focus LEAVES it, not
/// only on Return. Typing into one box and clicking the next is how a row of
/// fields gets filled in, and the obvious repair (`.onChange(of: focus)`) does
/// not fix it. Measured on macOS 26, driving focus the way a click does: focus
/// moves to the next field, the previous field's binding re-evaluates, a getter
/// gated on "am I focused" answers with the STORED text, SwiftUI pushes that
/// text back through the setter over the draft, and only then does the focus
/// hook run and commit the old value.
///
/// So the text lives in the field's own state and nothing derives it from where
/// focus is. The commit hook hangs off the text field rather than a container
/// row, so no container between the two can swallow it.
///
/// `stored` is a closure because it is re-read AFTER the write: the normalized
/// text on success (a stored 0 renders empty), and what to snap back to on a
/// refusal.
@MainActor
struct CommitOnBlurField: View {
  /// The text the stored value currently means, read on demand.
  let stored: () -> String
  /// Called at most once per edit, never for a field nobody typed in. Whether
  /// the text is accepted is the commit's business; it may write nothing.
  let commit: (String) -> Void
  var prompt: Text?
  var fieldLabel: Text?
  var fieldHint: Text?
  let width: CGFloat

  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    TextField("", text: $text, prompt: prompt)
      // A bare `TextField` draws no edge on a card, so an empty one renders as
      // nothing at all. The system border is the one control here off the
      // window's palette; it stays until a themed field exists.
      .textFieldStyle(.roundedBorder)
      // The row around the field draws the label, so the field's own empty one
      // must not claim space beside it.
      .labelsHidden()
      .focused($focused)
      .onSubmit { apply() }
      .onChange(of: focused) { _, isFocused in
        if !isFocused { apply() }
      }
      // An external write has to show up here (a per-display reset, Restore
      // Advanced Defaults, the same pref from another surface), but never while
      // this field is being edited.
      .onChange(of: stored()) { _, current in
        if !focused { text = current }
      }
      .onAppear {
        if !focused { text = stored() }
      }
      // A teardown fires NO focus change (measured), so popping the sub-page
      // with an edit pending would drop it. Deactivating the app is deliberately
      // not a commit: focus stays, nothing tears down, and the value applies
      // when the user comes back and moves on.
      .onDisappear { apply() }
      .frame(width: width)
      .accessibilityLabel(optional: fieldLabel)
      .accessibilityHint(optional: fieldHint)
  }

  /// One route for Return and focus loss, so the two cannot validate
  /// differently. The dirty check keeps a field nobody typed in from writing a
  /// pref every time focus passes through.
  private func apply() {
    let current = stored()
    guard text != current else { return }
    commit(text)
    text = stored()
  }
}

private extension View {
  @ViewBuilder func accessibilityLabel(optional text: Text?) -> some View {
    if let text { accessibilityLabel(text) } else { self }
  }

  @ViewBuilder func accessibilityHint(optional text: Text?) -> some View {
    if let text { accessibilityHint(text) } else { self }
  }
}
