//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  The window recipe is transplanted from the MonitorControl project (MIT),
//  from Support/DisplayManager.swift (`createShadeOnDisplay`): the property
//  sequence, the 10x1 seed rect and the alpha-0 layer-backed content view are
//  upstream's. It moved here out of `ShadeOverlay` so both overlay owners share
//  one description; moving it did not make it Candela's.
//
//  Candela's own: describing the recipe as a checkable value rather than an
//  inline sequence, `isReleasedWhenClosed = false`, `.fullScreenAuxiliary`, and
//  leaving the window ordering to the caller.

import AppKit

/// The window properties a Candela full-screen overlay needs, as a plain value.
///
/// As a value, a test can assert on the flags without opening a window at
/// `CGShieldingWindowLevel()`. Changing one is a behaviour change, not a style
/// edit: the failures are a shade that stops covering full-screen apps, and a
/// shade that eats the user's clicks.
struct OverlayWindowConfig: Equatable {
  /// Above the screen saver and our own HUD: anything painting over an overlay
  /// would escape the dimming that overlay applies.
  var level: NSWindow.Level

  /// `.canJoinAllSpaces` plus `.stationary` keep ONE window covering the display
  /// across every space; `.fullScreenAuxiliary` keeps it dimming over full-screen
  /// apps; `.ignoresCycle` keeps a black window out of the window cycler.
  var collectionBehavior: NSWindow.CollectionBehavior

  /// Click-through at creation. A window that swallows clicks turns a click on
  /// live UI into a blind one; only a deliberately opaque overlay disables it.
  var ignoresMouseEvents: Bool

  /// False so ARC owns the window: each owner holds the only reference and
  /// closes it itself, and AppKit would free it out from under that reference.
  var isReleasedWhenClosed: Bool

  /// False: a background drag would carry the dimming off the pixels it covers.
  var isMovableByWindowBackground: Bool

  /// Zero, so a new window never lands on screen carrying a dim nobody asked
  /// for. The owner writes the real level once the window exists.
  var initialContentAlpha: CGFloat

  /// False: the window server computes the shadow from the NON-TRANSPARENT
  /// content shape, so a mostly-transparent detection mask gets a hairline rim
  /// around every dimmed region, recomputed lazily so stale outlines linger.
  /// Upstream's shade covered the whole screen, which hid the rim at the edge.
  var hasShadow: Bool

  static let dimming = OverlayWindowConfig(
    level: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())),
    collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle],
    ignoresMouseEvents: true,
    isReleasedWhenClosed: false,
    isMovableByWindowBackground: false,
    initialContentAlpha: 0,
    hasShadow: false)
}

/// Applies `OverlayWindowConfig` to a window, plus the geometry and arithmetic
/// every overlay owner needs.
///
/// Configuration only: `ShadeOverlay` and `OledOverlay` must never share window
/// INSTANCES, because the brightness engine clears its shades wholesale on a
/// topology change and would erase OLED care's work on an unrelated schedule.
enum OverlayWindow {
  /// `NSWindow` needs some rect at init; `configure` applies the real frame.
  static let seedRect = NSRect(x: 0, y: 0, width: 10, height: 1)

  /// No chrome. `.borderless` is the zero mask, named rather than written `[]`.
  static let styleMask: NSWindow.StyleMask = [.borderless]

  @MainActor
  static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { $0.displayID == displayID }
  }

  /// Applies the configuration and paints the window's content view black.
  ///
  /// The dimming control point is the CONTENT VIEW's alpha, never the window's.
  /// An alpha-faded window gets different compositor treatment and reads washed
  /// out at low dim levels.
  ///
  /// Ordering the window on screen is left to the caller: a shade shows as soon
  /// as it exists, a care overlay shows when it first writes a state.
  @MainActor
  static func configure(
    _ window: NSWindow, as config: OverlayWindowConfig = .dimming, title: String,
    covering frame: NSRect
  ) {
    window.title = title
    window.isReleasedWhenClosed = config.isReleasedWhenClosed
    window.isMovableByWindowBackground = config.isMovableByWindowBackground
    window.backgroundColor = .clear
    window.ignoresMouseEvents = config.ignoresMouseEvents
    window.level = config.level
    window.collectionBehavior = config.collectionBehavior
    window.hasShadow = config.hasShadow
    window.setFrame(frame, display: true)
    window.contentView?.wantsLayer = true
    window.contentView?.alphaValue = config.initialContentAlpha
    window.contentView?.layer?.backgroundColor = .black
  }

  /// Clamps a dim level to the 0...1 an `alphaValue` can carry; non-finite gives 0.
  ///
  /// A clamp alone is not enough: `min(max(NaN, 0), 1)` is NaN in Swift, and a
  /// NaN alpha compares unequal to ITSELF, defeating any caller that memoises
  /// the state it last wrote. Non-finite resolves to 0 so the fallback cannot
  /// black out a display nobody asked to dim.
  static func clampedAlpha(_ alpha: Double) -> Double {
    guard alpha.isFinite else { return 0 }
    return min(max(alpha, 0), 1)
  }
}
