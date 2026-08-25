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
/// change made in System Settings — a `Toggle` bound to these properties needs
/// property-level observation to follow anything it did not itself cause.
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

  // Both setters record what the system reports, never what was asked for. A
  // chrome write can fail silently — CFPreferences takes any value and the Dock
  // restart is fire-and-forget — and caching the request would leave the pane's
  // switch ON over a system that never moved. Assuming a write landed is the
  // defect class behind #53/#65.
  //
  // Both setters decide against a LIVE read, never against the cached value.
  // The cache is only refreshed while the OLED Care pane is on screen, so any
  // change made while it is not (System Settings, a login, another tool) leaves
  // the cache behind the system, and a guard on the cache turns the user's
  // click into a silent no-op with nothing on screen to say so. That is the
  // D29 rule 1 shape applied to chrome: the control that disables a mechanism
  // must be able to restore the state, in every state it can be reached from.
  public func setMenuBarAutoHide(_ on: Bool) {
    let current = writer.readMenuBarAutoHide()
    if current != menuBarAutoHide { menuBarAutoHide = current }
    guard on != current else { return }
    writer.writeMenuBarAutoHide(on)
    menuBarAutoHide = writer.readMenuBarAutoHide()
  }

  public func setDockAutoHide(_ on: Bool) {
    let current = writer.readDockAutoHide()
    if current != dockAutoHide { dockAutoHide = current }
    guard on != current else { return }
    writer.writeDockAutoHide(on)
    dockAutoHide = writer.readDockAutoHide()
  }
}
