import Observation

/// Reads and writes the system-wide chrome settings. The app-target
/// implementation writes `_HIHideMenuBar` and `com.apple.dock autohide` through
/// CFPreferences; the Dock write restarts the Dock, visibly.
@MainActor public protocol ChromeWriting: AnyObject {
  func readMenuBarAutoHide() -> Bool
  func writeMenuBarAutoHide(_ on: Bool)
  func readDockAutoHide() -> Bool
  func writeDockAutoHide(_ on: Bool)
}

/// Design rules: reflect live state, never write silently, and only an
/// explicit toggle writes. Enrollment in OLED care suggests auto-hide, never
/// applies it. Kit tests use a fake writer and must never toggle the dev
/// machine's real menu bar.
///
/// `@Observable` so a `Toggle` bound to these properties re-renders when
/// `refresh()` picks up a change made in System Settings.
@MainActor @Observable public final class ChromeAutoHideController {
  public private(set) var menuBarAutoHide: Bool
  public private(set) var dockAutoHide: Bool
  private let writer: any ChromeWriting

  public init(writer: any ChromeWriting) {
    self.writer = writer
    self.menuBarAutoHide = writer.readMenuBarAutoHide()
    self.dockAutoHide = writer.readDockAutoHide()
  }

  /// Re-reads live state, never writes. The Dock has no change notification, so
  /// the pane polls while visible; a poll that wrote would fight System Settings.
  public func refresh() {
    // Assigned only on change: `@Observable` notifies on every set, equal or
    // not, and this runs on a 2 s timer for as long as the pane is open.
    let menuBar = writer.readMenuBarAutoHide()
    if menuBar != menuBarAutoHide { menuBarAutoHide = menuBar }
    let dock = writer.readDockAutoHide()
    if dock != dockAutoHide { dockAutoHide = dock }
  }

  // Both setters record what the system reports, never what was asked for: a
  // chrome write can fail silently, and caching the request would leave the
  // pane's switch ON over a system that never moved.
  //
  // Both decide against a LIVE read, never the cached value, which refreshes
  // only while the OLED Care pane is on screen. Guarding on a stale cache turns
  // the user's click into a silent no-op. The mute-strand rule's first clause
  // applied to chrome: the
  // control must restore the state from every state it can be reached from.
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
