import SwiftUI

/// System Settings' row idiom: a tinted rounded-rect tile holding a white SF
/// Symbol, then the title. The tile is decoration — the title carries the
/// meaning, so nothing here is communicated by color alone.
struct SettingsSymbolTile: View {
  let symbol: String
  let tint: Color

  var body: some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
      .fill(tint)
      .frame(width: 18, height: 18)
      .overlay(
        Image(systemName: symbol)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.white)
      )
      .accessibilityHidden(true)
  }
}

@MainActor
struct SettingsSidebar: View {
  @Binding var selection: SettingsDestination?

  var body: some View {
    List(selection: $selection) {
      ForEach(SettingsRegistry.panes) { pane in
        Label {
          Text(pane.title)
        } icon: {
          SettingsSymbolTile(symbol: pane.symbol, tint: pane.tint)
        }
        .tag(SettingsDestination.pane(pane.id))
      }
    }
    .listStyle(.sidebar)
    // A settings window has exactly one navigation surface, and collapsing it
    // leaves a detail pane you cannot navigate out of. `NavigationSplitView`
    // adds the toggle by default, which parked a stray button in the middle of
    // the sidebar's toolbar strip and reserved a band of empty space under the
    // window controls. Removing it reclaims both.
    .toolbar(removing: .sidebarToggle)
  }
}
