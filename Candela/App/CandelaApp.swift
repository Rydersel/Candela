import CandelaKit
import SwiftUI

@main
struct CandelaApp: App {
  // The menu-bar panel is AppKit-owned: StatusItemController hosts PanelView
  // in a real NSMenu so an auto-hidden menu bar stays visible while the panel
  // is open (see StatusItemController for the full rationale).
  @NSApplicationDelegateAdaptor(StatusItemController.self) private var statusItemController

  var body: some Scene {
    Settings {
      SettingsRootView()
        .environment(statusItemController.model)
        .environment(statusItemController.settingsActions)
    }
    // The sidebar redesign made this matter. A `Settings` scene sizes itself to
    // its content and refuses to resize by default; with a split view and panes
    // of very different heights, that pins the window to whichever pane it
    // happened to open on — measured at a hard 900×512, immovable in both
    // directions. `.contentMinSize` lets the user grow it, while the root
    // view's `minWidth`/`minHeight` still hold the floor.
    .windowResizability(.contentMinSize)
  }
}
