import SwiftUI

/// The Health pillar's settings-side front door (SC4).
///
/// A placeholder for now, and an honest one: the measurement, export and
/// delete controls it will host still live under OLED Care, so the page says
/// where they are instead of drawing an empty imitation of them. The follow-up
/// task replaces this body wholesale.
@MainActor
struct HealthPane: View {
  var body: some View {
    SettingsPageScaffold {
      SettingsPageHeader(
        title: "Health",
        subtitle: "A display keeps no record of its own wear. "
          + "Health is where Candela's record is read: hours lit, and where on the screen the light has fallen."
      )

      SettingsCard {
        Text(
          "Not built yet. Measurement, export and deletion still live under OLED Care, on a display's Measurement & Data page."
        )
        .font(.callout)
        .foregroundStyle(SettingsTheme.bodyColor)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
