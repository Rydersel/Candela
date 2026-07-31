import SwiftUI

/// `@MainActor` from the start: later tasks store `@MainActor` types
/// (`LoginItem`, `SettingsActions`, `DisplayPrefWriter`) on these structs, and
/// a plain `View` conformance leaves everything but `body` nonisolated.
@MainActor
struct DisplaysPane: View {
  var body: some View {
    Form {
      Text(verbatim: "…") // replaced by Tasks 13–14
    }
    .formStyle(.grouped)
  }
}
