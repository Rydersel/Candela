//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  The per-display shade lifecycle here still follows the MonitorControl
//  project (MIT), Support/DisplayManager.swift: `getShade` is `shade(for:)`,
//  `createShadeOnDisplay` is `createShade`, `updateShade` is `setShadeAlpha`,
//  `destroyShade` is `removeShade`. The window construction those methods used
//  to inline is no longer here: it is Candela's `OverlayWindow`, and the three
//  DIVERGENCE notes below are Candela's fixes to fork bugs.

import AppKit
import CandelaKit
import os

/// The software-dimming shade: one black, click-through, full-screen window per
/// display, whose alpha carries the dimming.
///
/// Used when gamma dimming is unavailable or unwanted (virtual/AirPlay displays,
/// or after a gamma-interference fallback). AppKit island behind
/// `ShadeRendering` so the engine never touches `NSWindow`/`NSScreen`.
///
/// The dimming control point is the **content view's** alpha, not the window's;
/// `OverlayWindow` carries the recipe and the reason.
///
/// These windows are this class's alone. OLED care runs its own overlays over
/// the same displays and the two must never share instances: `removeAllShades`
/// fires on a topology change, which would erase care's work.
@MainActor
final class ShadeOverlay: ShadeRendering {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "shade")

  private var shades: [CGDirectDisplayID: NSWindow] = [:]

  // MARK: - ShadeRendering

  @discardableResult
  func setShadeAlpha(_ alpha: Double, on displayID: CGDirectDisplayID) -> Bool {
    // DT17: `false` is the honest answer when no shade could be created, and it
    // is what stops the engine memoising a dimming that never happened. The
    // fork — and Candela until now — returned void here, so a mirrored display
    // stopped dimming entirely with nothing propagated anywhere.
    guard let shade = self.shade(for: displayID) else {
      return false
    }
    shade.contentView?.alphaValue = CGFloat(OverlayWindow.clampedAlpha(alpha))
    return true
  }

  func removeShade(for displayID: CGDirectDisplayID) {
    guard let shade = self.shades.removeValue(forKey: displayID) else {
      return
    }
    // DIVERGENCE (fork bug): the fork parks every closed shade in a
    // `shadeGrave` array that is never drained — an unbounded NSWindow leak
    // across reconfiguration cycles. We close and drop the window. Closing a
    // borderless, non-released-when-closed window we still hold the only
    // reference to is safe; `isReleasedWhenClosed` is explicitly false at
    // creation so ARC (not AppKit) owns the lifetime.
    shade.close()
    Self.log.info("Shade removed for display \(displayID, privacy: .public)")
  }

  func removeAllShades() {
    // DIVERGENCE (fork bug): the fork iterates `shades.keys` while its loop body
    // mutates `shades` (a lazy view over the dictionary). We snapshot the keys.
    for displayID in Array(self.shades.keys) {
      self.removeShade(for: displayID)
    }
  }

  func repinFrames() {
    for (displayID, shade) in self.shades {
      guard let screen = OverlayWindow.screen(for: displayID) else {
        // The display is gone (or not yet back). Leave the window alone rather
        // than guessing a frame; whoever owns reconfiguration decides whether
        // this shade should survive at all.
        continue
      }
      shade.setFrame(screen.frame, display: true)
    }
  }

  // MARK: - Windows

  /// Returns the display's shade, creating it on first use. Nil only when no
  /// `NSScreen` currently matches the display (offline/unmatched).
  private func shade(for displayID: CGDirectDisplayID) -> NSWindow? {
    if let existing = self.shades[displayID] {
      return existing
    }
    guard let shade = self.createShade(on: displayID) else {
      return nil
    }
    self.shades[displayID] = shade
    return shade
  }

  private func createShade(on displayID: CGDirectDisplayID) -> NSWindow? {
    // The ID arriving here is ALREADY RESOLVED to a drawable display by
    // `BrightnessController` (DT15), so a mirror set has ONE shade and it is on
    // the master — which is where the pixels are. (The fork created and framed
    // shades under the raw ID but set alpha under the mirror-resolved one, so a
    // mirrored slave grew a shade nothing ever dimmed.) A lookup that still
    // fails is a genuine failure and is reported, not swallowed.
    guard let screen = OverlayWindow.screen(for: displayID) else {
      Self.log.info("No screen matches display \(displayID, privacy: .public); shade not created")
      return nil
    }
    let shade = NSWindow(
      contentRect: OverlayWindow.seedRect, styleMask: OverlayWindow.styleMask,
      backing: .buffered, defer: false)
    // DIVERGENCE (deliberate): the fork's collection behaviour is
    // `[.stationary, .canJoinAllSpaces, .ignoresCycle]`. `OverlayWindow`
    // adds `.fullScreenAuxiliary` so the shade keeps dimming over full-screen
    // apps instead of being dropped when a space goes full-screen.
    OverlayWindow.configure(
      shade, title: "Candela Window Shade for Display \(displayID)", covering: screen.frame)
    // DIVERGENCE (fork bug, cosmetic): the fork passes the *window* frame
    // (screen coordinates) as a *view* dirty rect. The view's own bounds are
    // the correct space.
    shade.contentView?.setNeedsDisplay(shade.contentView?.bounds ?? .zero)
    // Last, not first: the shade is fully configured and already sitting on the
    // display's frame by the time it reaches the screen.
    shade.orderFrontRegardless()
    Self.log.info("Shade created for display \(displayID, privacy: .public)")
    return shade
  }
}
