import CandelaKit
import SwiftUI

/// Handles the `--vd-engage` helper contract BEFORE any app machinery runs: the
/// virtual display host re-executes this binary to enumerate display modes,
/// which the creating process cannot do. That call never returns.
@main
enum CandelaMain {
  static func main() {
    VirtualDisplayHost.handleEngageHelperInvocation()
    CandelaApp.main()
  }
}

struct CandelaApp: App {
  // A real NSMenu rather than SwiftUI: an auto-hidden menu bar stays visible
  // while the panel is open. Full rationale in StatusItemController.
  @NSApplicationDelegateAdaptor(StatusItemController.self) private var statusItemController

  var body: some Scene {
    Settings {
      SettingsRootView()
        .environment(statusItemController.model)
        .environment(statusItemController.settingsActions)
        .environment(statusItemController.updaterModel)
    }
    // A `Settings` scene sizes to its content and refuses to resize by default,
    // which pinned the window to whichever pane it opened on (a hard 900x512,
    // immovable). `.contentMinSize` lets the user grow it; the root view's
    // `minWidth`/`minHeight` still hold the floor.
    .windowResizability(.contentMinSize)

    // Display Health (OCR-A1) is deliberately NOT a scene. Adding a WindowGroup
    // for it changed plain launch behavior on this LSUIElement app: the settings
    // window opened where a control build opened nothing [MEASURED 2026-08-17],
    // and the suppressing API does not exist at the macOS 14 floor.
    // `DisplayHealthWindowPresenter` makes those windows on demand instead.
  }
}
