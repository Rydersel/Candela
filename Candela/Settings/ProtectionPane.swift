import SwiftUI

/// The Protection pillar: the policies that guard a display's configuration
/// (SC6).
///
/// A placeholder for now, and an honest one: the startup and wake restore
/// controls it will host are still in General, so the page says where they are
/// rather than drawing an empty imitation of them. Nothing unbuilt is listed
/// here at all. The follow-up task replaces this body wholesale.
@MainActor
struct ProtectionPane: View {
  var body: some View {
    SettingsPageScaffold {
      SettingsPageHeader(
        title: "Protection",
        subtitle: "macOS does not always give an external display back the setup it had. "
          + "Protection is where the rules that restore it are kept."
      )

      SettingsCard {
        Text("Not built yet. Startup and wake restore are still in General, under Startup.")
          .font(.callout)
          .foregroundStyle(SettingsTheme.bodyColor)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
