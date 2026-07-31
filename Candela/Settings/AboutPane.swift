import SwiftUI

/// `@MainActor` from the start: later tasks store `@MainActor` types
/// (`LoginItem`, `SettingsActions`, `DisplayPrefWriter`) on these structs, and
/// a plain `View` conformance leaves everything but `body` nonisolated.
@MainActor
struct AboutPane: View {
  var body: some View {
    Form {
      Text(verbatim: "…") // replaced by Task 15
    }
    .formStyle(.grouped)
  }
}
