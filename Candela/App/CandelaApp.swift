import CandelaKit
import SwiftUI

@main
struct CandelaApp: App {
  // The menu-bar panel is AppKit-owned: StatusItemController hosts PanelView
  // in a real NSMenu so an auto-hidden menu bar stays visible while the panel
  // is open (see StatusItemController for the full rationale).
  @NSApplicationDelegateAdaptor(StatusItemController.self) private var statusItemController

  var body: some Scene {
    // A SwiftUI App must declare at least one scene. Settings is inert for an
    // LSUIElement app until the settings UI arrives (Milestone 5).
    Settings {
      EmptyView()
    }
  }
}
