import CoreGraphics

/// Where a HUD pill sits on the display it is drawn on.
///
/// Raw values are shipped on-disk schema: `topRight` is 0 because it is what the
/// app placed the pill at before there was a preference, so an absent or
/// unreadable stored value resolves to exactly the old behaviour. Raw order is
/// therefore not reading order, and pickers list `HUDPlacement.pickerOrder`
/// rather than `allCases` (same rule as `MenuIcon`).
public enum HUDPosition: Int, Sendable, CaseIterable {
  case topRight = 0
  case topLeft = 1
  case topCenter = 2
}

/// The pill's origin on one display: screen geometry in, a point out.
///
/// Pure and in the Kit, like `HUDGrouping` and for the same reason: the AppKit
/// island holds no judgement (DT16), and there is no app test target (D21), so
/// anything living in the app cannot be pinned by a test. Rotation is the case
/// that needs pinning most. `CGDisplayBounds` swaps width and height when a
/// display is rotated, and the Dell in this setup is mounted at 270°, so a pill
/// placed against the manufactured landscape geometry lands off the side of the
/// screen while every log line reports success.
public enum HUDPlacement {
  /// Reading order, left to right. Never `HUDPosition.allCases`: raw 0 is the
  /// RIGHT-hand position.
  public static let pickerOrder: [HUDPosition] = [.topLeft, .topCenter, .topRight]

  /// The pill's origin in AppKit's y-up global coordinates.
  ///
  /// `frame` is the display's full frame and `visibleFrame` the same frame less
  /// the menu bar and the Dock; `topInset` is the caller's menu-bar allowance,
  /// measured per screen.
  ///
  /// The height comes from the FULL frame. With the menu bar auto-hidden,
  /// `visibleFrame` reaches the top of the screen and the pill would sit exactly
  /// where the bar reveals itself, so `topInset` reserves that strip whether the
  /// bar is showing or not.
  ///
  /// The horizontal anchors come from the VISIBLE frame, the centred one
  /// included. Nothing forces that: the panel is ordered at `.screenSaver`
  /// level, so it would happily draw on top of a pinned side Dock, and
  /// anchoring to the visible frame is a choice to sit clear of one instead. It
  /// has a visible cost, which is the honest reason to record it here: while a
  /// side Dock is pinned, "Top center" sits half that Dock's width off the true
  /// centre of the display. Centring on `frame.midX` is the other defensible
  /// answer and is one line away.
  ///
  /// The courtesy is also NOT symmetrical with the menu bar's. An auto-hidden
  /// side Dock leaves `visibleFrame` spanning the full width, so nothing
  /// reserves the strip it reveals into and a revealed Dock comes up under the
  /// pill: the top edge is protected unconditionally, the side edges only while
  /// the Dock is pinned.
  ///
  /// The result is clamped into the visible frame horizontally and the full
  /// frame vertically, so a pill larger than the space it is going into lands at
  /// the edge rather than off it, and rounded AFTER that clamp, so the whole
  /// point the caller places the window at is always a point the clamp allowed.
  public static func origin(
    _ position: HUDPosition,
    size: CGSize,
    frame: CGRect,
    visibleFrame: CGRect,
    topInset: CGFloat,
    margin: CGFloat
  ) -> CGPoint {
    let x: CGFloat = switch position {
    case .topLeft: visibleFrame.minX + margin
    case .topCenter: visibleFrame.midX - size.width / 2
    case .topRight: visibleFrame.maxX - size.width - margin
    }
    let y = frame.maxY - topInset - size.height - margin
    // Whole points: a centred pill on an odd-width screen otherwise starts on a
    // half point and its text renders soft.
    return CGPoint(
      x: clamp(x, length: size.width, lower: visibleFrame.minX, upper: visibleFrame.maxX).rounded(),
      y: clamp(y, length: size.height, lower: frame.minY, upper: frame.maxY).rounded()
    )
  }

  /// The inner `max` matters for a pill larger than its screen: without it the
  /// upper bound falls below the lower one and the clamp reports a position off
  /// the top or left (the same trap `ConfirmationPlacement.clamp` documents).
  private static func clamp(
    _ value: CGFloat, length: CGFloat, lower: CGFloat, upper: CGFloat
  ) -> CGFloat {
    min(max(value, lower), max(lower, upper - length))
  }
}
