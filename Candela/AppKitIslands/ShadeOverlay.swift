//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Transplanted from the MonitorControl project (MIT), from Support/DisplayManager.swift
//  (`createShadeOnDisplay` / `getShade` / `updateShade` / `destroyShade`).

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
/// The dimming control point is the **content view's** alpha, not the window's:
/// the window stays fully opaque with a clear background and only its black
/// content layer fades in. (Fork behavior — an alpha-faded *window* gets
/// different compositor treatment and reads washed out at low dim levels.)
@MainActor
final class ShadeOverlay: ShadeRendering {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "shade")

  private var shades: [CGDirectDisplayID: NSWindow] = [:]

  // MARK: - ShadeRendering

  func setShadeAlpha(_ alpha: Double, on displayID: CGDirectDisplayID) {
    guard let shade = self.shade(for: displayID) else {
      return
    }
    shade.contentView?.alphaValue = CGFloat(min(max(alpha, 0), 1))
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
      guard let screen = Self.screen(for: displayID) else {
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
    // DIVERGENCE (fork bug): the fork creates/frames shades under the *raw*
    // display ID but sets alpha under the mirror-resolved ID, so a mirrored
    // slave grows a shade nothing ever dims. We use the raw ID for both, which
    // is self-consistent. Mirroring + shade is out of Milestone 3's test scope;
    // when it arrives, resolve the ID once, at the engine boundary.
    guard let screen = Self.screen(for: displayID) else {
      Self.log.info("No screen matches display \(displayID, privacy: .public); shade not created")
      return nil
    }
    // The initial content rect is a throwaway — the real frame is applied below.
    let shade = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 1), styleMask: [], backing: .buffered, defer: false)
    shade.title = "Candela Window Shade for Display \(displayID)"
    shade.isReleasedWhenClosed = false
    shade.isMovableByWindowBackground = false
    // The window is clear; the black lives in the content view's layer.
    shade.backgroundColor = .clear
    shade.ignoresMouseEvents = true
    // Above the screen saver and above the HUD — a shade that anything can
    // paint over would let that thing escape the dimming.
    shade.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    shade.orderFrontRegardless()
    // DIVERGENCE (deliberate): the fork uses
    // `[.stationary, .canJoinAllSpaces, .ignoresCycle]`. `.fullScreenAuxiliary`
    // is added so the shade keeps dimming over full-screen apps instead of
    // being dropped when a space goes full-screen.
    shade.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    shade.setFrame(screen.frame, display: true)
    shade.contentView?.wantsLayer = true
    shade.contentView?.alphaValue = 0
    shade.contentView?.layer?.backgroundColor = .black
    // DIVERGENCE (fork bug, cosmetic): the fork passes the *window* frame
    // (screen coordinates) as a *view* dirty rect. The view's own bounds are
    // the correct space.
    shade.contentView?.setNeedsDisplay(shade.contentView?.bounds ?? .zero)
    Self.log.info("Shade created for display \(displayID, privacy: .public)")
    return shade
  }

  private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID }
  }
}
