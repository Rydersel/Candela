import CoreGraphics

/// Where a HUD pill sits on the display it is drawn on.
///
/// Raw values are shipped on-disk schema. `topRight` is 0 because that is where the
/// pill sat before the preference existed, so an unreadable stored value resolves to
/// the old behaviour. Raw order is not reading order: pickers use `pickerOrder`.
public enum HUDPosition: Int, Sendable, CaseIterable {
  case topRight = 0
  case topLeft = 1
  case topCenter = 2
}

/// The pill's origin on one display: screen geometry in, a point out.
///
/// Pure and in the Kit like `HUDGrouping`, because rotation needs
/// pinning most: `CGDisplayBounds` swaps width and height on a rotated display, so a
/// pill placed against the manufactured landscape geometry lands off the side of the
/// screen while every log line reports success.
public enum HUDPlacement {
  /// Reading order, left to right. Never `HUDPosition.allCases`: raw 0 is the
  /// RIGHT-hand position.
  public static let pickerOrder: [HUDPosition] = [.topLeft, .topCenter, .topRight]

  /// The pill's origin in AppKit's y-up global coordinates. `topInset` is the
  /// caller's menu-bar allowance, measured per screen.
  ///
  /// The height comes from the FULL frame: with the menu bar auto-hidden,
  /// `visibleFrame` reaches the top of the screen and the pill would sit exactly
  /// where the bar reveals itself, so `topInset` reserves that strip either way.
  ///
  /// The horizontal anchors come from the VISIBLE frame, centre included. That is a
  /// choice, not a constraint: the panel draws at `.screenSaver` level and would
  /// happily cover a pinned side Dock. The cost is that "Top center" sits half a
  /// pinned Dock's width off true centre. The courtesy is not symmetrical with the
  /// menu bar's, since an auto-hidden side Dock leaves `visibleFrame` full width and
  /// a revealed Dock comes up under the pill.
  ///
  /// Clamped into the visible frame horizontally and the full frame vertically, then
  /// rounded, so the caller always gets a point the clamp allowed.
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
    let clampedX = ScreenClamp.clamped(
      x, length: size.width, lower: visibleFrame.minX, upper: visibleFrame.maxX
    )
    let clampedY = ScreenClamp.clamped(y, length: size.height, lower: frame.minY, upper: frame.maxY)
    return CGPoint(x: clampedX.rounded(), y: clampedY.rounded())
  }
}
