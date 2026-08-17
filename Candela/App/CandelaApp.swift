import CandelaKit
import SwiftUI

/// The real entry point. The one job it has beyond launching the app: honour
/// the `--vd-engage` helper contract BEFORE any app machinery runs, so the
/// virtual display host can re-execute this binary as a fresh process that
/// can enumerate display modes (the creating process cannot; see
/// `VirtualDisplayHost.handleEngageHelperInvocation`). When the argument is
/// present the call never returns.
@main
enum CandelaMain {
  static func main() {
    VirtualDisplayHost.handleEngageHelperInvocation()
    CandelaApp.main()
  }
}

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

    // Display Health (OCR-A1, #185) is deliberately NOT a scene here. Adding
    // a WindowGroup for it changed PLAIN launch behavior on this LSUIElement
    // app: the settings window opened where a control build opened nothing
    // [MEASURED 2026-08-17], and the suppressing API does not exist at the
    // macOS 14 floor (§4). `DisplayHealthWindowPresenter` (AppKit island,
    // wired in StatusItemController) makes those windows on demand instead,
    // which changes nothing at launch by construction.
  }
}
