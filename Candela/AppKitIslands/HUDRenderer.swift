import AppKit
import CandelaKit

/// What one show asks a renderer to draw.
struct HUDContent {
  let kind: HUDType
  /// 0...1, already normalised by the caller.
  let value: CGFloat
  /// The display's name with any suffix already appended.
  let title: String
}

/// How a renderer leaves the screen when its 1.5 s are up.
enum HUDDismissal {
  /// The window's alpha fades over this long; the renderer drew nothing special.
  case fade(TimeInterval)
  /// The renderer animated its own exit and the window may order out after this long.
  case selfAnimated(TimeInterval)
}

/// One style family's drawing inside the HUD window. The window, its level and
/// collection behaviour, the fade timer and the per-display map stay in
/// `BrightnessHUD`; a renderer owns the content view and the frame rule.
@MainActor
protocol HUDRenderer: AnyObject {
  var style: HUDStyle { get }
  /// The window's frame on `screen` for this style, in global coordinates.
  func frame(on screen: NSScreen, position: HUDPosition) -> CGRect
  /// The view installed as the panel's content view, sized to `frame`.
  var contentView: NSView { get }
  /// A show arriving during a self-animated exit must reverse that exit itself:
  /// the window orders out only after the returned duration, and the generation
  /// guard cancels that order-out, so nothing else brings the content back.
  func show(_ content: HUDContent, reduceMotion: Bool)
  func hide(reduceMotion: Bool) -> HUDDismissal
}
