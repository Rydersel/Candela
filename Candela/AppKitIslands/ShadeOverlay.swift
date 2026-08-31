//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  The per-display shade lifecycle here still follows the MonitorControl
//  project (MIT), Support/DisplayManager.swift: `getShade` is `shade(for:)`,
//  `createShadeOnDisplay` is `createShade`, `updateShade` is `setShadeAlpha`,
//  `destroyShade` is `removeShade`. The window construction those methods used
//  to inline has moved to `OverlayWindow`, where it stays MonitorControl-derived
//  and carries this same header. The three DIVERGENCE notes below are Candela's
//  fixes to fork bugs.

import AppKit
import CandelaKit
import os

/// The software-dimming shade: one black, click-through, full-screen window per
/// display, whose content-view alpha carries the dimming. Used when gamma
/// dimming is unavailable or unwanted (virtual/AirPlay displays, or a
/// gamma-interference fallback), behind `ShadeRendering` so the engine never
/// touches `NSWindow`/`NSScreen`.
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
    // DT17: `false` when no shade could be created is what stops the engine
    // memoising a dimming that never happened. The fork returns void here, so a
    // mirrored display stopped dimming with nothing propagated anywhere.
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
    // DIVERGENCE (fork bug): the fork parks every closed shade in a `shadeGrave`
    // array it never drains, leaking an NSWindow per reconfiguration cycle. We
    // close and drop it. `isReleasedWhenClosed` is false at creation, so ARC
    // owns the lifetime and we hold the only reference.
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
        // Display gone, or not back yet. Leave the frame alone rather than
        // guess it; reconfiguration decides whether this shade survives.
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
    // The ID is ALREADY RESOLVED to a drawable display by `BrightnessController`
    // (DT15), so a mirror set has ONE shade and it sits on the master, where the
    // pixels are. The fork framed shades under the raw ID but set alpha under
    // the resolved one, so a mirrored slave grew a shade nothing ever dimmed.
    guard let screen = OverlayWindow.screen(for: displayID) else {
      Self.log.info("No screen matches display \(displayID, privacy: .public); shade not created")
      return nil
    }
    let shade = NSWindow(
      contentRect: OverlayWindow.seedRect, styleMask: OverlayWindow.styleMask,
      backing: .buffered, defer: false)
    // DIVERGENCE (deliberate): the fork omits `.fullScreenAuxiliary`, so its
    // shade is dropped when a space goes full-screen. `OverlayWindow` adds it.
    OverlayWindow.configure(
      shade, title: "Candela Window Shade for Display \(displayID)", covering: screen.frame)
    // DIVERGENCE (fork bug, cosmetic): the fork passes the window frame (screen
    // coordinates) as a view dirty rect. The view's own bounds are that space.
    shade.contentView?.setNeedsDisplay(shade.contentView?.bounds ?? .zero)
    // Last, so the shade is configured and framed before it reaches the screen.
    shade.orderFrontRegardless()
    Self.log.info("Shade created for display \(displayID, privacy: .public)")
    return shade
  }
}
