import Observation

/// Reads and writes the two system-wide chrome settings. The app-target
/// implementation writes `_HIHideMenuBar` and `com.apple.dock autohide`
/// through CFPreferences; the Dock write also restarts the Dock, visibly, and
/// the pane copy says so.
@MainActor public protocol ChromeWriting: AnyObject {
  func readMenuBarAutoHide() -> Bool
  func writeMenuBarAutoHide(_ on: Bool)
  func readDockAutoHide() -> Bool
  func writeDockAutoHide(_ on: Bool)
}

/// #47's design rules: reflect live state, never write silently, and only an
/// explicit toggle writes (OC10) — enrollment in OLED care suggests auto-hide
/// and never applies it. Kit tests use a fake writer; a Kit test must never
/// toggle the dev machine's real menu bar.
///
/// `@Observable` so the pane's toggles re-render when `refresh()` picks up a
/// change made in System Settings, and so a rejected set snaps the switch back.
@MainActor @Observable public final class ChromeAutoHideController {
  public private(set) var menuBarAutoHide: Bool
  public private(set) var dockAutoHide: Bool
  private let writer: any ChromeWriting

  public init(writer: any ChromeWriting) {
    self.writer = writer
    self.menuBarAutoHide = writer.readMenuBarAutoHide()
    self.dockAutoHide = writer.readDockAutoHide()
  }

  /// Re-reads live state. Never writes — the Dock has no change notification,
  /// so the pane polls this while visible, and a poll that wrote would fight
  /// System Settings.
  public func refresh() {
    // Assigned only on change: `@Observable` notifies on every set, equal or
    // not, and this runs on a 2 s timer for as long as the pane is open.
    let menuBar = writer.readMenuBarAutoHide()
    if menuBar != menuBarAutoHide { menuBarAutoHide = menuBar }
    let dock = writer.readDockAutoHide()
    if dock != dockAutoHide { dockAutoHide = dock }
  }

  public func setMenuBarAutoHide(_ on: Bool) {
    guard on != menuBarAutoHide else { return }
    writer.writeMenuBarAutoHide(on)
    menuBarAutoHide = on
  }

  public func setDockAutoHide(_ on: Bool) {
    guard on != dockAutoHide else { return }
    writer.writeDockAutoHide(on)
    dockAutoHide = on
  }
}
