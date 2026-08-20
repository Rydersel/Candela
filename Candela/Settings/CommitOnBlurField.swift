import SwiftUI

/// A settings text field that applies what was typed when focus LEAVES it, not
/// only on Return (#144).
///
/// Typing into one box and clicking the next is how a row of fields gets
/// filled in, and the shape this replaces threw that edit away. The mechanism
/// is worth stating, because it is invisible from the call site and the obvious
/// repair (a `.onChange(of: focus)` hook) does not fix it. Measured on macOS 26
/// in an isolated harness, driving focus the way a click does:
///
/// 1. Focus moves to the next field, which re-evaluates the previous field's
///    binding.
/// 2. A getter gated on "am I the focused field" now answers with the STORED
///    text instead of the draft.
/// 3. SwiftUI pushes that text into the `AppKitTextField` that is ending its
///    edit, and it comes back through the binding's SETTER: the draft holding
///    what the user typed is overwritten with the old value.
/// 4. Only then does any focus-change hook run, and it commits the old value.
///
/// So the text lives here, in the field's own state, and nothing derives it
/// from where focus is. That also means the commit hook hangs off the text
/// field itself rather than off a container row: the hook lives on the thing it
/// commits, so no container between the two can swallow it.
///
/// `stored` is a closure rather than a value because it is re-read AFTER the
/// write: it gives the normalized text on success (a stored 0 renders empty)
/// and the text to snap back to on a refusal.
@MainActor
struct CommitOnBlurField: View {
  /// The text the stored value currently means, read on demand.
  let stored: () -> String
  /// Called at most once per edit, and never for a field nobody typed in.
  /// Whether the text is accepted is the commit's own business: it may write
  /// nothing.
  let commit: (String) -> Void
  var prompt: Text?
  var fieldLabel: Text?
  var fieldHint: Text?
  let width: CGFloat

  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    TextField("", text: $text, prompt: prompt)
      // The explicit border is what makes the box a box. A bare `TextField`
      // draws no edge of its own on a card, and with an empty value that
      // renders as nothing at all: no border, no focus ring, no way to know a
      // field is there. The system's rounded border is the one control here
      // that is not on the window's palette; a themed field is a theme-layer
      // addition nobody has written yet, so this stays until one exists.
      .textFieldStyle(.roundedBorder)
      // The label is drawn by the row around the field, so the field's own
      // empty label must not claim space beside it.
      .labelsHidden()
      .focused($focused)
      .onSubmit { apply() }
      .onChange(of: focused) { _, isFocused in
        if !isFocused { apply() }
      }
      // An external write has to show up here: a per-display reset, Restore
      // Advanced Defaults, or the same pref written from another surface. Never
      // while this field is being edited, which is the fight the old shape lost.
      .onChange(of: stored()) { _, current in
        if !focused { text = current }
      }
      .onAppear {
        if !focused { text = stored() }
      }
      // A teardown fires NO focus change (measured), so popping the sub-page or
      // closing the window with an edit pending would drop it. Losing focus by
      // deactivating the app is deliberately not a commit: focus stays on the
      // field, nothing is torn down, and the value applies when the user comes
      // back and moves on.
      .onDisappear { apply() }
      .frame(width: width)
      .accessibilityLabel(optional: fieldLabel)
      .accessibilityHint(optional: fieldHint)
  }

  /// One route for Return and for focus loss, so the two cannot validate
  /// differently. The dirty check is what keeps a field nobody typed in from
  /// writing a pref every time focus passes through it.
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
