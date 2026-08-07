import AppKit
import CandelaKit
import os

/// OLED care's own overlay windows: one black, full-screen window per enrolled
/// display, whose content-view alpha carries the care dim.
///
/// The window setup mirrors `ShadeOverlay`, transplanted from MonitorControl
/// (MIT). Deliberately NOT the same windows, though: the brightness engine owns
/// those and clears them wholesale on topology changes (`removeAllShades()`), on
/// a schedule that has nothing to do with the dimming state machine's. Sharing
/// them would let either owner erase the other's work.
///
/// The ID arriving here is the display OLED care is enrolled on. Mirror
/// resolution is NOT done here — OC13 suspends care on a mirror participant
/// before any of this is reached.
@MainActor
final class OledOverlay {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "oledcare")

  private var windows: [CGDirectDisplayID: NSPanel] = [:]

  /// An overlay we closed, kept until the window server confirms it is gone.
  ///
  /// Two reasons it holds the panel and not just its number. Detection: without
  /// it the removal half of `verifyPresence` is a tautology — "no window
  /// cached" would answer "not present" for a window we asked to close and the
  /// server never dropped, which is the exact stranded-overlay case OC12 exists
  /// to catch. Recovery: a detected strand needs a lever, and only the window
  /// itself can be closed again.
  ///
  /// The number is captured at close time rather than read back from the panel:
  /// `windowNumber` is only meaningful while the window has a device, so a
  /// closed panel cannot be asked what it used to be.
  private struct ClosedOverlay {
    let panel: NSPanel
    let number: CGWindowID
  }

  private var lastRemoved: [CGDirectDisplayID: ClosedOverlay] = [:]

  /// The state each display's overlay is currently carrying, so an unchanged
  /// `apply` can be a no-op. At the overlay-up cadence an unconditional
  /// re-order would be ~10 window-server round trips per second per display,
  /// and each one re-stacks the overlay above whatever else is at shielding
  /// level (the lock shield, the screen saver) ten times a second.
  private struct AppliedState: Equatable {
    let alpha: Double
    let blackout: Bool
  }

  private var lastApplied: [CGDirectDisplayID: AppliedState] = [:]

  /// Displays already warned about for a missing `NSScreen`. A care overlay is
  /// re-driven on every state tick, so an unrated warning would be a per-tick
  /// log flood for as long as the display stays gone.
  private var warnedMissingScreen: Set<CGDirectDisplayID> = []

  /// `alpha` nil removes the overlay; otherwise it is clamped to 0...1 and
  /// applied to the content view (the window itself stays opaque with a clear
  /// background — an alpha-faded *window* gets different compositor treatment
  /// and reads washed out, per `ShadeOverlay`).
  ///
  /// Returns false when the requested state could not be produced — no
  /// `NSScreen` matches the display, so no overlay exists to carry the dim.
  /// DT17's lesson, and the reason this is not a `Void` call: a caller that
  /// cannot tell will memoise a dimming that never happened. **Removal always
  /// returns true**; a removal the window server did not honour is reported by
  /// `verifyPresence`, not here — this call knows only what it asked for.
  ///
  /// Ordering: the overlay is ordered front when it is created and whenever the
  /// applied state changes, and NOT on an unchanged re-apply, which is a
  /// no-op. Re-asserting a state the window already carries is
  /// `reassert(on:)`'s job — that is the OC12 reconcile's lever, and keeping it
  /// separate is what keeps the steady-state cadence off the window server.
  @discardableResult
  func apply(alpha: Double?, blackout: Bool, on displayID: CGDirectDisplayID) -> Bool {
    guard let alpha else {
      self.remove(for: displayID)
      return true
    }
    let existed = self.windows[displayID] != nil
    guard let window = self.window(for: displayID) else {
      if self.warnedMissingScreen.insert(displayID).inserted {
        Self.log.warning("No screen matches display \(displayID, privacy: .public); OLED care overlay not applied")
      }
      return false
    }
    let state = AppliedState(alpha: min(max(alpha, 0), 1), blackout: blackout)
    guard !existed || self.lastApplied[displayID] != state else {
      return true
    }
    self.lastApplied[displayID] = state
    self.write(state, to: window)
    return true
  }

  /// Re-asserts the overlay's last applied state: the recovery lever for an
  /// OC12 mismatch (`verifyPresence` false while an overlay is wanted), where
  /// the window server dropped a window we still hold — a space transition,
  /// another shielding window, a reconfiguration. `apply` deliberately will not
  /// do this, since the state it is asked for is the state it already has.
  ///
  /// A no-op when the display has no overlay: there is nothing to re-assert,
  /// and creating one here would invent a dim level this class does not own.
  func reassert(on displayID: CGDirectDisplayID) {
    guard let window = self.windows[displayID], let state = self.lastApplied[displayID] else {
      return
    }
    self.write(state, to: window)
  }

  private func write(_ state: AppliedState, to window: NSPanel) {
    // OC15: blackout swallows mouse input (at full black a click-through click
    // is a blind click on live UI); every other level stays click-through so
    // the waking click lands where the user aimed.
    window.ignoresMouseEvents = !state.blackout
    window.contentView?.alphaValue = CGFloat(state.alpha)
    window.orderFrontRegardless()
  }

  func remove(for displayID: CGDirectDisplayID) {
    guard let window = self.windows.removeValue(forKey: displayID) else {
      return
    }
    self.lastApplied.removeValue(forKey: displayID)
    // Retained for the stranded-overlay check and its recovery; cleared once
    // the server confirms the window is gone, or when a new overlay supersedes
    // it. A window that never reached the screen has no number to watch (0 is
    // `kCGNullWindowID`, which would make the query meaningless rather than
    // negative), and nothing to strand.
    if window.windowNumber > 0 {
      self.lastRemoved[displayID] = ClosedOverlay(panel: window, number: CGWindowID(window.windowNumber))
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
  /// state — `isVisible` restates the request we issued. True means an overlay
  /// window for this display is on screen *now*, whether or not we still want
  /// one; both halves of the ruling (an add that did not land, a removal that
  /// did not take) are answered by the same call.
  ///
  /// No TCC grant needed: only `kCGWindowName` is gated by Screen Recording.
  func verifyPresence(on displayID: CGDirectDisplayID) -> Bool {
    if let window = self.windows[displayID] {
      return Self.isOnScreen(CGWindowID(window.windowNumber))
    }
    guard let closed = self.lastRemoved[displayID] else {
      return false
    }
    guard Self.isOnScreen(closed.number) else {
      self.lastRemoved.removeValue(forKey: displayID)
      return false
    }
    // Detecting a strand is only half of it: this window is black over the
    // user's screen and nothing else can close it. Ask again — the entry stays
    // until a later check sees it gone, so a close that keeps failing keeps
    // being retried rather than reported forever.
    Self.log.error("OLED care overlay still on screen after close on display \(displayID, privacy: .public); closing again")
    closed.panel.orderOut(nil)
    closed.panel.close()
    return true
  }

  private static func isOnScreen(_ number: CGWindowID) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], number) as? [[String: Any]],
          let info = list.first
    else {
      return false
    }
    // Window numbers are recycled. Without the owner check, a number reissued
    // to another process's window would read as a strand of ours that no close
    // can ever clear.
    guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() else {
      return false
    }
    // The key is present only while the window is on screen; an entry can
    // outlive that, which is why membership alone is not the answer.
    return info[kCGWindowIsOnscreen as String] as? Bool ?? false
  }

  /// Returns the display's overlay, creating it on first use. Nil only when no
  /// `NSScreen` currently matches the display (offline/unmatched).
  private func window(for displayID: CGDirectDisplayID) -> NSPanel? {
    if let existing = self.windows[displayID] {
      return existing
    }
    guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
      return nil
    }
    // An `NSPanel` with `.nonactivatingPanel`, not a plain `NSWindow`: the
    // blackout overlay accepts clicks (OC15), and a click-accepting window in
    // an accessory app would otherwise activate Candela and take key away from
    // whatever the user was in. Same shape as `ConfirmationPanel`, the repo's
    // only other click-receiving window. `.borderless` is the zero mask —
    // named for what it means, since the mask is otherwise empty.
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 1),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
    panel.title = "Candela OLED Care Overlay for Display \(displayID)"
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = false
    // Nothing here takes input — the blackout window swallows clicks and hosts
    // no controls — so it should never become key. Mouse events still arrive at
    // the window under the cursor regardless of key state.
    panel.becomesKeyOnlyIfNeeded = true
    // Not a floating panel, so this is already the default; stated because
    // `ConfirmationPanel` records that `isFloatingPanel` flips it, and an
    // overlay that vanished on deactivation would be invisible exactly when it
    // is meant to be dimming.
    panel.hidesOnDeactivate = false
    // The window is clear; the black lives in the content view's layer.
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    // Above the screen saver and above the HUD — anything that could paint over
    // the overlay would escape the dimming.
    panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    // `.fullScreenAuxiliary` keeps the overlay dimming over full-screen apps
    // instead of being dropped when a space goes full-screen.
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.setFrame(screen.frame, display: true)
    panel.contentView?.wantsLayer = true
    panel.contentView?.alphaValue = 0
    panel.contentView?.layer?.backgroundColor = .black
    self.windows[displayID] = panel
    // A live overlay supersedes the closed one this display may still be
    // watched for — `verifyPresence` answers from the live window from here on,
    // so the old entry would be a strand nothing is watching. Give it one more
    // close on the way out (a no-op if it really did go).
    if let closed = self.lastRemoved.removeValue(forKey: displayID) {
      closed.panel.orderOut(nil)
      closed.panel.close()
    }
    self.warnedMissingScreen.remove(displayID)
    Self.log.info("OLED care overlay created for display \(displayID, privacy: .public)")
    return panel
  }
}
