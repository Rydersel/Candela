//  Candela. Credit: the overlay technique this uses (a shielding-level,
//  every-space, click-through black window whose content-view alpha carries the
//  dim) follows MonitorControl (MIT). The window recipe itself is Candela's
//  `OverlayWindow`; no code in this file is transplanted.

import AppKit
import CandelaKit
import os

/// OLED care's own overlay windows: one black, full-screen window per enrolled
/// display, whose content-view alpha carries the care dim.
///
/// The window configuration comes from `OverlayWindow`, shared with
/// `ShadeOverlay`. The WINDOWS are deliberately not shared: the brightness
/// engine owns the shades and clears them wholesale on topology changes
/// (`removeAllShades()`), on a schedule that has nothing to do with the dimming
/// state machine's. Sharing instances would let either owner erase the other's
/// work, so nothing below (storage, close paths, lifetime) is shared either.
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
  /// The number is captured at close time rather than read back from the panel,
  /// but NOT because a closed panel has forgotten it: measured on macOS 26,
  /// `windowNumber` is still the same value after `close()`. The reason is the
  /// contract rather than the observation. `NSWindow.windowNumber` is documented
  /// to return a value `<= 0` for a window with no device, and `CGWindowID(_:)`
  /// traps on a negative, so reading it back later would convert a documented
  /// return value into a crash. Capturing while the window is still on screen
  /// means the guard at the call site is the only place that has to know.
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
    /// The spatial axis (OC17, #20). Nil is exactly what shipped before it
    /// existed: one uniform alpha over the whole content view.
    ///
    /// `OverlayMask` quantizes to 1/255 on construction, which is what keeps
    /// this struct's `==` meaningful. Without that, a mask derived from live
    /// luminance would differ in the twelfth decimal every tick, every apply
    /// would be a memo miss, and the overlay would re-order ~10 times a second
    /// per display. The memo is not an optimization here: each re-order
    /// re-stacks the overlay above whatever else sits at shielding level.
    let mask: OverlayMask.Oriented?
  }

  private var lastApplied: [CGDirectDisplayID: AppliedState] = [:]

  /// Displays already warned about for a missing `NSScreen`. A care overlay is
  /// re-driven on every state tick, so an unrated warning would be a per-tick
  /// log flood for as long as the display stays gone.
  private var warnedMissingScreen: Set<CGDirectDisplayID> = []

  /// `alpha` nil removes the overlay; otherwise it is clamped to 0...1 and
  /// applied to the content view (the window itself stays opaque with a clear
  /// background; an alpha-faded *window* gets different compositor treatment
  /// and reads washed out, per `OverlayWindow`).
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
  ///
  /// `mask` is the spatial axis, already in DISPLAY orientation. Nil keeps the
  /// scalar behaviour this shipped with, so every OC12 guarantee is untouched
  /// for callers that do not use it.
  @discardableResult
  func apply(
    alpha: Double?, mask: OverlayMask.Oriented? = nil, blackout: Bool,
    on displayID: CGDirectDisplayID
  ) -> Bool {
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
    // **A uniform mask is NOT normalized away here, and that is deliberate.**
    // It used to be, on the reasoning that a uniform mask looks the same as no
    // mask and the scalar path is cheaper. It does not look the same: the
    // caller sets `alpha = 1.0` precisely BECAUSE a mask is present and carries
    // the absolute per-cell opacity, so dropping the mask leaves alpha 1.0 over
    // an empty layer and paints the panel opaque black. Every idle dim did
    // exactly that.
    //
    // The lesson generalizes past this call: `alpha`'s meaning DEPENDS on
    // whether a mask came with it, so this method cannot unilaterally discard
    // one. Collapsing a uniform mask back to a scalar is the caller's job,
    // where both values are set together (`OledCareCoordinator.render`).
    // `OverlayWindow.clampedAlpha` and not a bare clamp: a NaN alpha would make
    // `AppliedState` compare unequal to ITSELF, so the change-only-write guard
    // below would miss every time and `apply` would write to the window server
    // on every tick, silently. Unreachable from the current callers, which
    // sanitise at `OledDimConfig` construction; guarded anyway because the
    // failure is invisible, since a per-tick write looks exactly like a working
    // overlay.
    let state = AppliedState(
      alpha: OverlayWindow.clampedAlpha(alpha), blackout: blackout, mask: mask)
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
    Self.writeMask(state.mask, to: window)
    window.orderFrontRegardless()
  }

  /// Renders the spatial axis as the layer's contents.
  ///
  /// The mask becomes a tiny grayscale image (24×10, or 10×24 on a rotated
  /// panel) and the layer magnifies it with a LINEAR filter. That is what
  /// satisfies OC17's "smoothly interpolated gradient, never per-cell blocks":
  /// at 3440×1440 a cell is ~143 px, and a step function at that scale is a
  /// visible tile pattern, which would be a self-inflicted version of the
  /// problem the feature exists to solve. Drawing 240 rectangles would produce
  /// exactly that pattern; handing the GPU an image and letting it interpolate
  /// costs nothing and produces the falloff for free.
  ///
  /// Nil CLEARS the contents rather than leaving them: a display that had a
  /// mask and no longer does must go back to a uniform dim, not keep a stale
  /// gradient nothing will update.
  private static func writeMask(_ mask: OverlayMask.Oriented?, to window: NSPanel) {
    guard let layer = window.contentView?.layer else { return }
    guard let mask else {
      layer.contents = nil
      layer.backgroundColor = .black
      return
    }
    guard let image = maskImage(mask) else {
      // Fall back to the uniform dim rather than to nothing: a failed image is
      // a reason to lose the spatial detail, never a reason to stop dimming a
      // panel the user asked to have dimmed.
      layer.contents = nil
      layer.backgroundColor = .black
      return
    }
    // The image carries the black AND its per-cell alpha, so the flat
    // background must go: leaving it would floor every cell at full black and
    // the mask would have no visible effect at all.
    layer.backgroundColor = NSColor.clear.cgColor
    layer.magnificationFilter = .linear
    layer.minificationFilter = .linear
    layer.contentsGravity = .resize
    layer.contents = image
  }

  /// Black pixels whose ALPHA is the mask. Premultiplied, because the mask is
  /// the alpha channel and the colour is a constant zero.
  private static func maskImage(_ mask: OverlayMask.Oriented) -> CGImage? {
    let (cells, cols, rows) = (mask.cells, mask.cols, mask.rows)
    guard cols > 0, rows > 0, cells.count == cols * rows else { return nil }

    var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
    for index in cells.indices {
      let alpha = UInt8(clamping: Int((cells[index] * 255).rounded()))
      // BGRA premultiplied: colour channels are alpha * 0 = 0, so only the
      // alpha byte carries anything.
      pixels[index * 4 + 3] = alpha
    }

    let space = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
      .union(.byteOrder32Little)
    guard let context = CGContext(
      data: &pixels, width: cols, height: rows, bitsPerComponent: 8,
      bytesPerRow: cols * 4, space: space, bitmapInfo: info.rawValue)
    else { return nil }
    return context.makeImage()
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

  /// Deliberately uncalled (W3a ruling): the reconfiguration response is
  /// removeAll + re-render, never a repin — display IDs REASSIGN across a dock
  /// cycle with every panel still present, so repinning alone can pin an
  /// overlay to the WRONG panel. Kept for a future geometry-only path (spec §8
  /// names mode/rotation changes); never call it as the reconfiguration
  /// response.
  func repinFrames() {
    for (displayID, window) in self.windows {
      guard let screen = OverlayWindow.screen(for: displayID) else {
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
      // Same reason `remove(for:)` screens the number: `windowNumber` is <= 0
      // for a window with no device, and `CGWindowID(_:)` TRAPS on a negative
      // Int. A window that never reached the screen is not on screen.
      guard window.windowNumber > 0 else { return false }
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
    guard let screen = OverlayWindow.screen(for: displayID) else {
      return nil
    }
    // An `NSPanel` with `.nonactivatingPanel`, not a plain `NSWindow`: the
    // blackout overlay accepts clicks (OC15), and a click-accepting window in
    // an accessory app would otherwise activate Candela and take key away from
    // whatever the user was in. Same shape as `ConfirmationPanel`, the repo's
    // only other click-receiving window.
    let panel = NSPanel(contentRect: OverlayWindow.seedRect,
                        styleMask: OverlayWindow.styleMask.union(.nonactivatingPanel),
                        backing: .buffered,
                        defer: false)
    // Nothing here takes input (the blackout window swallows clicks and hosts
    // no controls), so it should never become key. Mouse events still arrive at
    // the window under the cursor regardless of key state.
    panel.becomesKeyOnlyIfNeeded = true
    // Not a floating panel, so this is already the default; stated because
    // `ConfirmationPanel` records that `isFloatingPanel` flips it, and an
    // overlay that vanished on deactivation would be invisible exactly when it
    // is meant to be dimming.
    panel.hidesOnDeactivate = false
    // Ordering front is `write`'s job here, not creation's: the overlay reaches
    // the screen when it first carries a state.
    OverlayWindow.configure(
      panel, title: "Candela OLED Care Overlay for Display \(displayID)",
      covering: screen.frame)
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
