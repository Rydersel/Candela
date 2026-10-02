import AppKit
import CoreGraphics

/// Whether a display's menu bar is on screen, and its height.
///
/// `NSScreen` cannot tell [MEASURED 2026-10-02]. `frame.maxY - visibleFrame.maxY`
/// reads 38 hidden and 39 shown on the notched built-in (the notch's safe area),
/// 0 on an external either way; `menuBarAllowance` reports the bar's thickness
/// even while it is hidden.
///
/// The window server's bar window does change: owner "Window Server", layer 24,
/// at the display's top-left, full width, bar height (0,0 1800x39 on the
/// built-in, 1800,0 2560x30 on an external). With the bar auto-hidden no Window
/// Server window sits at layer 24 on any display. Matched on owner, layer and
/// bounds, never the "Menubar" title: titles are withheld without Screen
/// Recording, which the app does not request.
@MainActor
enum MenuBarVisibility {
  private static let barLayer = 24
  /// Room for any bar thickness, short of a real window's height.
  private static let heightRange: ClosedRange<CGFloat> = 1...60

  /// Nil while the bar is hidden, or when the window list cannot say.
  static func height(on screen: NSScreen) -> CGFloat? {
    guard let displayID = screen.displayID,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    // Both are in the global top-left space, so no flip.
    let display = CGDisplayBounds(displayID)
    for window in windows {
      guard window[kCGWindowOwnerName as String] as? String == "Window Server",
            window[kCGWindowLayer as String] as? Int == barLayer,
            let dict = window[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: dict),
            bounds.origin == display.origin,
            bounds.width == display.width,
            heightRange.contains(bounds.height)
      else { continue }
      return bounds.height
    }
    return nil
  }
}
