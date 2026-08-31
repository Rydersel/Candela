import AppKit
import CoreGraphics

/// The display hosting the frontmost app's frontmost window (the fork's
/// `getCurrentDisplay(byFocus: true)`). nil when nothing resolves; callers fall
/// back to the pointer display.
@MainActor
enum FocusedDisplay {
  static func frontmostWindowDisplayID() -> CGDirectDisplayID? {
    guard let frontmost = NSWorkspace.shared.frontmostApplication,
          let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
          ) as? [[String: Any]]
    else { return nil }
    // The list is front-to-back, so the first window owned by the frontmost app
    // is its frontmost window.
    for info in windows {
      guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
            pid == frontmost.processIdentifier,
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
            let x = bounds["X"], let y = bounds["Y"],
            let w = bounds["Width"], let h = bounds["Height"]
      else { continue }
      let center = CGPoint(x: x + w / 2, y: y + h / 2)
      var id: CGDirectDisplayID = 0
      var count: UInt32 = 0
      if CGGetDisplaysWithPoint(center, 1, &id, &count) == .success, count > 0 {
        return id
      }
    }
    return nil
  }
}
