import CandelaKit
import SwiftUI

/// One connected external display's settings destination — a thin host over
/// `DisplayHubView` (Task 13), kept so the navigation shell names one stable
/// destination type per display.
///
/// Deliberately EMPTY of structure: the hub owns its own scroll, hero and
/// lifecycle. That began as a measured constraint of the grouped `Form` this
/// page used to be (its scrollable extent came up short when the sections
/// arrived from a child view) and it stands on its own now: a second container
/// here would give the page two scrolls and two content columns. Anything added
/// here must not re-wrap the hub.
///
/// Promoting displays to top-level sidebar destinations is what actually
/// separates this window from the fork's — and it retires the "Advanced"
/// disclosure, because a full window has room to simply show the controls.
@MainActor
struct DisplayDetailView: View {
  let state: AppModel.DisplayState
  @Binding var selection: SettingsDestination?
  @Binding var path: [DisplaySubPage]

  var body: some View {
    DisplayHubView(state: state, selection: $selection, path: $path)
  }
}
