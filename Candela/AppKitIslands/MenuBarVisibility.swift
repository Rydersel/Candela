import AppKit
import CoreGraphics

/// Whether a display's menu bar is on screen right now, and how tall it is.
///
/// Neither `NSScreen` answer works [MEASURED 2026-10-02]. `frame.maxY -
/// visibleFrame.maxY` reads 38 on the notched built-in with the bar auto-hidden
/// (the notch's safe area) and 39 with it shown, and 0 on an external either
/// way. `menuBarAllowance` returns the bar's thickness even while it is hidden.
///
/// What does change is the window server's own bar window: owner "Window
/// Server", layer 24, origin at the display's top-left, the display's full
/// width and the bar's height (0,0 1800x39 on the built-in, 1800,0 2560x30 on
/// an external). With the bar auto-hidden no Window Server window sits at
/// layer 24 on any display. It is matched on owner, layer and bounds, never on
/// its "Menubar" title: window titles are withheld from a process without
/// Screen Recording, which the app does not ask for, while owner, layer and
/// bounds are reported regardless.
@MainActor
enum MenuBarVisibility {
  private static let barLayer = 24
  /// Generous for any bar thickness, short of anything that could be a real window.
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
