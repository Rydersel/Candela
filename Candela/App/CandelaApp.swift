import CandelaKit
import SwiftUI

/// Two gates that run BEFORE any app machinery. First the `--vd-engage` helper
/// contract: the virtual display host re-executes this binary to enumerate
/// display modes, which the creating process cannot do, and that call never
/// returns. Then the single-instance guard, so a copy that quits here never
/// builds an `AppModel`, starts the updater or touches gamma.
@main
enum CandelaMain {
  static func main() {
    VirtualDisplayHost.handleEngageHelperInvocation()
    SingleInstanceGuard.terminateIfAlreadyRunning()
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

    // Display Health is deliberately NOT a scene. Adding a WindowGroup
    // for it changed plain launch behavior on this LSUIElement app: the settings
    // window opened where a control build opened nothing [MEASURED 2026-08-17],
    // and the suppressing API does not exist at the macOS 14 floor.
    // `DisplayHealthWindowPresenter` makes those windows on demand instead.
  }
}
