import SwiftUI

/// A page's opening lockup. Left-aligned, unlike the guided setup flow's
/// centered heading: a settings page is a working surface, so the title anchors
/// where the content does.
struct SettingsPageHeader: View {
  var title: String
  var subtitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 24, weight: .bold, design: .rounded))
        .foregroundStyle(SettingsTheme.titleColor)
        .settingsHeading()
      if let subtitle {
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(SettingsTheme.bodyColor)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
