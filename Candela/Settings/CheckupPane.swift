import SwiftUI

/// The Checkup pillar, named and empty (SC7).
///
/// **This page is finished as written.** An unbuilt feature is invisible here,
/// never greyed: no mock report, no disabled Run button, nothing that renders
/// Checkup as existing. The pillar is named because the sidebar names it, and
/// the page says plainly what it will be and that it is not that yet.
@MainActor
struct CheckupPane: View {
  var body: some View {
    SettingsPageScaffold {
      SettingsPageHeader(
        title: "Checkup",
        subtitle: "A new display is easiest to send back in its first days. "
          + "Checkup will examine one while that window is still open."
      )

      SettingsCard {
        Text("Not built yet. There is nothing here to run.")
          .font(.callout)
          .foregroundStyle(SettingsTheme.bodyColor)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
