import AppKit
import CoreGraphics

/// Whether a display's menu bar is on screen right now, and how tall it is.
///
/// Neither `NSScreen` answer works [MEASURED 2026-10-02]. `frame.maxY -
/// visibleFrame.maxY` reads 38 on the notched built-in with the bar auto-hidden
/// (the notch's safe area) and 39 with it shown, and 0 on an external either
/// way. `menuBarAllowance` returns the bar's thickness even while it is hidden.
/// What does change is the window server's own "Menubar" window: it is on
/// screen, at the display's top and the bar's height, only while that
/// display's bar is visible.
@MainActor
enum MenuBarVisibility {
  /// Nil while the bar is hidden, or when the window list cannot say.
  static func height(on screen: NSScreen) -> CGFloat? {
    guard let displayID = screen.displayID,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    // Both are in the global top-left space, so no flip.
    let display = CGDisplayBounds(displayID)
    for window in windows {
      guard window[kCGWindowOwnerName as String] as? String == "Window Server",
            window[kCGWindowName as String] as? String == "Menubar",
            let dict = window[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: dict),
            bounds.height > 0,
            display.contains(CGPoint(x: bounds.midX, y: bounds.midY))
      else { continue }
      return bounds.height
    }
    return nil
  }
}
