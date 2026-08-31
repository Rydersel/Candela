import CandelaKit
import SwiftUI

/// One connected external display's settings destination: a thin host over
/// `DisplayHubView`, so the navigation shell names one stable destination type
/// per display.
///
/// Deliberately EMPTY of structure. The hub owns its own scroll, hero and
/// lifecycle, and a second container here would give the page two scrolls and
/// two content columns. Anything added here must not re-wrap the hub.
@MainActor
struct DisplayDetailView: View {
  let state: AppModel.DisplayState
  @Binding var selection: SettingsDestination?
  @Binding var path: [DisplaySubPage]

  var body: some View {
    DisplayHubView(state: state, selection: $selection, path: $path)
  }
}
