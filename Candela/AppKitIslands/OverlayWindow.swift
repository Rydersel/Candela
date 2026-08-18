//  Candela. The full-screen overlay window recipe, described once as a value
//  and applied by a thin function, so both overlay owners agree on it and so
//  the description can be checked without an NSWindow.
//
//  Credit: the property set below is the standard macOS recipe for a
//  click-through, shielding-level overlay, and Candela first learned it from
//  MonitorControl (MIT). The values are functionally dictated; their
//  organisation here is Candela's own.

import AppKit

/// The window properties a Candela full-screen overlay needs, as a plain value.
///
/// Kept separate from any `NSWindow` because the windows this describes live at
/// `CGShieldingWindowLevel()` over the whole of a user's display, which is the
/// least convenient place to discover a wrong flag. As a value it can be read,
/// compared and asserted on in a test that never opens a window.
///
/// The values are not a matter of taste. A click-through, always-on-top,
/// every-space overlay that keeps covering a display through a full-screen
/// transition has essentially one correct set on macOS, and `dimming` is it.
/// Treat a change to any of them as a behaviour change, never a style edit: the
/// failures are a shade that stops covering full-screen apps, and a shade that
/// eats the user's clicks.
struct OverlayWindowConfig: Equatable {
  /// Above the screen saver and above our own HUD. Anything that could paint
  /// over an overlay would escape the dimming that overlay is applying.
  var level: NSWindow.Level

  /// `.canJoinAllSpaces` plus `.stationary` keep ONE window covering the
  /// display across every space rather than one window per space;
  /// `.fullScreenAuxiliary` keeps it dimming over full-screen apps instead of
  /// being dropped when a space goes full-screen; `.ignoresCycle` keeps a black
  /// full-screen window out of the window cycler, where it is only ever noise.
  var collectionBehavior: NSWindow.CollectionBehavior

  /// Click-through at creation. A window that swallows clicks turns a click on
  /// live UI into a blind one, so only a deliberately opaque overlay disables
  /// this, and it does so per applied state rather than once per window.
  var ignoresMouseEvents: Bool

  /// False, so ARC owns the window and AppKit does not. Both overlay owners
  /// hold the only reference and close it themselves; a released-when-closed
  /// window would be freed out from under that reference.
  var isReleasedWhenClosed: Bool

  /// False: an overlay is scenery pinned to one display's frame, and a
  /// background drag would carry the dimming off the pixels it exists to cover.
  var isMovableByWindowBackground: Bool

  /// What the content view's alpha starts at. Zero, so no window is ever on
  /// screen carrying a dim nobody asked for; the owner writes the real level
  /// once the window exists.
  var initialContentAlpha: CGFloat

  static let dimming = OverlayWindowConfig(
    level: NSWindow.Level(rawValue: Int(CGShieldingWindowLevel())),
    collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle],
    ignoresMouseEvents: true,
    isReleasedWhenClosed: false,
    isMovableByWindowBackground: false,
    initialContentAlpha: 0)
}

/// Applies `OverlayWindowConfig` to a window, plus the small pieces of geometry
/// and arithmetic every overlay owner needs.
///
/// Configuration only, deliberately. Ownership, storage and lifetime stay with
/// each overlay class: `ShadeOverlay` and `OledOverlay` must never share window
/// INSTANCES, because the brightness engine clears its shades wholesale on a
/// topology change and would erase OLED care's work on a schedule that has
/// nothing to do with the care state machine's.
enum OverlayWindow {
  /// The throwaway content rect an overlay is born with. `NSWindow` needs some
  /// rect at init; the real frame is a screen's and `configure` applies it.
  static let seedRect = NSRect(x: 0, y: 0, width: 10, height: 1)

  /// The style mask for every overlay window: no chrome at all. `.borderless`
  /// is the zero mask, named for what it means rather than written as `[]`.
  static let styleMask: NSWindow.StyleMask = [.borderless]

  @MainActor
  static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { $0.displayID == displayID }
  }

  /// Applies the configuration and paints the window's content view black.
  ///
  /// The dimming control point is the CONTENT VIEW's alpha, never the window's:
  /// the window stays fully opaque with a clear background and only its black
  /// content layer fades. An alpha-faded window gets different compositor
  /// treatment and reads washed out at low dim levels.
  ///
  /// Ordering the window on screen is deliberately NOT done here. The two
  /// owners differ on when that should happen (a shade shows as soon as it
  /// exists; a care overlay shows when it first writes a state), and ordering
  /// front is the one step in the sequence with a visible consequence.
  @MainActor
  static func configure(
    _ window: NSWindow, as config: OverlayWindowConfig = .dimming, title: String,
    covering frame: NSRect
  ) {
    window.title = title
    window.isReleasedWhenClosed = config.isReleasedWhenClosed
    window.isMovableByWindowBackground = config.isMovableByWindowBackground
    // The window is clear; the black lives in the content view's layer.
    window.backgroundColor = .clear
    window.ignoresMouseEvents = config.ignoresMouseEvents
    window.level = config.level
    window.collectionBehavior = config.collectionBehavior
    window.setFrame(frame, display: true)
    window.contentView?.wantsLayer = true
    window.contentView?.alphaValue = config.initialContentAlpha
    window.contentView?.layer?.backgroundColor = .black
  }

  /// Clamps a dim level to the 0...1 an `alphaValue` can carry, resolving a
  /// non-finite value to 0.
  ///
  /// A clamp alone is not enough: `min(max(NaN, 0), 1)` is NaN in Swift, since
  /// every comparison against NaN is false and both functions fall through to
  /// the original value. A NaN alpha then compares unequal to ITSELF, which
  /// quietly defeats any caller that memoises the state it last wrote.
  ///
  /// Non-finite resolves to 0, the transparent end. An overlay is the mechanism
  /// that can darken a panel, so its one unforced choice belongs on the side
  /// that cannot black out a display nobody asked to dim.
  static func clampedAlpha(_ alpha: Double) -> Double {
    guard alpha.isFinite else { return 0 }
    return min(max(alpha, 0), 1)
  }
}
