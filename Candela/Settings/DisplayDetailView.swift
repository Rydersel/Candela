import CandelaKit
import SwiftUI

/// One connected external display's settings destination — a thin host over
/// `DisplayHubView` (Task 13), kept so the navigation shell names one stable
/// destination type per display.
///
/// Deliberately EMPTY of structure: the hub owns its own `Form`, hero and
/// lifecycle, because a grouped `Form` mis-sizes its scrollable extent when
/// its sections arrive from a child view placed inside a parent's `Form`
/// (measured — see the note in `DisplayHubView.body`). Anything added here
/// must not re-wrap the hub in a container view.
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
