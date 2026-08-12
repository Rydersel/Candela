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
  /// the menu bar and the Dock. The split is deliberate: the horizontal anchors
  /// come from the visible frame so a Dock on the left or the right never sits
  /// under the pill, while the height comes from the full frame, because an
  /// auto-hidden menu bar leaves `visibleFrame` reaching the top of the screen
  /// and the pill would then sit exactly where the bar reveals itself.
  /// `topInset` is the caller's menu-bar allowance, which it measures per
  /// screen.
  ///
  /// The result is clamped into the visible frame horizontally and the full
  /// frame vertically, so a pill larger than the space it is going into lands
  /// at the edge rather than off it.
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
      x: clamp(x.rounded(), length: size.width, lower: visibleFrame.minX, upper: visibleFrame.maxX),
      y: clamp(y.rounded(), length: size.height, lower: frame.minY, upper: frame.maxY)
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
