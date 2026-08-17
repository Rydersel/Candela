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

    // Display Health (OCR-A1, #185): its own window, sized to its content, so
    // a portrait display's map gets a portrait-fitting window the settings
    // window can never be. The value is the display's persistence key, the
    // only identity that survives a replug; the root closes the window when
    // that display departs.
    displayHealthScene
  }

  /// An auxiliary window scene in a menu-bar app can auto-open at launch (the
  /// unprompted-window defect class, #180). `defaultLaunchBehavior(.suppressed)`
  /// would state that outright but is macOS 15 API, and `SceneBuilder` on this
  /// toolchain rejects `if #available`, so the root view's nil-value dismissal
  /// is the net instead: an auto-opened window carries no value and closes
  /// itself on appearance. Launch cleanliness is on #185's verification list.
  private var displayHealthScene: some Scene {
    WindowGroup("Display Health", id: "displayHealth", for: String.self) { $key in
      DisplayHealthWindowRoot(persistenceKey: $key)
        .environment(statusItemController.model)
    }
    .windowResizability(.contentSize)
  }
}
