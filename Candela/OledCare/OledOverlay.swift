import AppKit
import CandelaKit
import os

/// OLED care's own overlay windows: one black, full-screen window per enrolled
/// display, whose content-view alpha carries the care dim.
///
/// Deliberately NOT `ShadeOverlay`, whose shape this copies: the brightness
/// engine owns those windows and clears them wholesale on topology changes
/// (`removeAllShades()`), on a schedule that has nothing to do with the dimming
/// state machine's. Sharing them would let either owner erase the other's work.
///
/// The ID arriving here is the display OLED care is enrolled on. Mirror
/// resolution is NOT done here — OC13 suspends care on a mirror participant
/// before any of this is reached.
@MainActor
final class OledOverlay {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "oledcare")

  private var windows: [CGDirectDisplayID: NSWindow] = [:]

  /// `alpha` nil removes the overlay; otherwise it is clamped to 0...1 and
  /// applied to the content view (the window itself stays opaque with a clear
  /// background — an alpha-faded *window* gets different compositor treatment
  /// and reads washed out, per `ShadeOverlay`).
  func apply(alpha: Double?, blackout: Bool, on displayID: CGDirectDisplayID) {
    guard let alpha else {
      self.remove(for: displayID)
      return
    }
    guard let window = self.window(for: displayID) else {
      Self.log.warning("No screen matches display \(displayID, privacy: .public); OLED care overlay not applied")
      return
    }
    // OC15: blackout swallows mouse input (at full black a click-through click
    // is a blind click on live UI); every other level stays click-through so
    // the waking click lands where the user aimed.
    window.ignoresMouseEvents = !blackout
    window.contentView?.alphaValue = CGFloat(min(max(alpha, 0), 1))
  }

  func remove(for displayID: CGDirectDisplayID) {
    guard let window = self.windows.removeValue(forKey: displayID) else {
      return
    }
    // Safe for the same reason `ShadeOverlay.removeShade` is: the window is
    // borderless and `isReleasedWhenClosed` is false at creation, so ARC owns
    // the lifetime and closing the last reference drops it.
    window.close()
    Self.log.info("OLED care overlay removed for display \(displayID, privacy: .public)")
  }

  func removeAll() {
    for displayID in Array(self.windows.keys) {
      self.remove(for: displayID)
    }
  }

  func repinFrames() {
    for (displayID, window) in self.windows {
      guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
        // Display gone, or not back yet. Leave the window alone rather than
        // guessing a frame; the coordinator decides whether it survives at all.
        continue
      }
      window.setFrame(screen.frame, display: true)
    }
  }

  /// OC12: presence answered by the window server, never by our own `NSWindow`
  /// state — `isVisible` restates the request we issued. Asks whether the
  /// window ID is in the window server's list AND on screen; the on-screen key
  /// is the achieved half of the answer, since a window that exists but was
  /// never composited still has an entry.
  ///
  /// No TCC grant needed: only `kCGWindowName` is gated by Screen Recording.
  func verifyPresence(on displayID: CGDirectDisplayID) -> Bool {
    guard let window = self.windows[displayID] else {
      return false
    }
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]],
          let info = list.first
    else {
      return false
    }
    // The key is present only while the window is on screen.
    return info[kCGWindowIsOnscreen as String] as? Bool ?? false
  }

  /// Returns the display's overlay, creating it on first use. Nil only when no
  /// `NSScreen` currently matches the display (offline/unmatched).
  private func window(for displayID: CGDirectDisplayID) -> NSWindow? {
    if let existing = self.windows[displayID] {
      return existing
    }
    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
      return nil
    }
    // The initial content rect is a throwaway — the real frame is applied below.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 1), styleMask: [], backing: .buffered, defer: false)
    window.title = "Candela OLED Care Overlay for Display \(displayID)"
    window.isReleasedWhenClosed = false
    window.isMovableByWindowBackground = false
    // The window is clear; the black lives in the content view's layer.
    window.backgroundColor = .clear
    window.ignoresMouseEvents = true
    // Above the screen saver and above the HUD — anything that could paint over
    // the overlay would escape the dimming.
    window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    // `.fullScreenAuxiliary` keeps the overlay dimming over full-screen apps
    // instead of being dropped when a space goes full-screen.
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    window.setFrame(screen.frame, display: true)
    window.contentView?.wantsLayer = true
    window.contentView?.alphaValue = 0
    window.contentView?.layer?.backgroundColor = .black
    window.orderFrontRegardless()
    self.windows[displayID] = window
    Self.log.info("OLED care overlay created for display \(displayID, privacy: .public)")
    return window
  }
}
