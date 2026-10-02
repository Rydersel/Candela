import CoreGraphics

/// The notch an Island draws on, in screen coordinates. Real when the display
/// has one; otherwise a drawn stand-in of the measured size.
public struct IslandNotch: Equatable, Sendable {
  public let rect: CGRect
  public let isReal: Bool

  public init(rect: CGRect, isReal: Bool) {
    self.rect = rect
    self.isReal = isReal
  }
}

/// Pure geometry for the three Island styles. Window-local rects are y up with
/// the notch flush against the panel's top edge, so the renderer only converts
/// once. Every number was agreed by eye on the rig on 2026-10-01.
public enum IslandGeometry {
  /// The built-in's notch as macOS reports it.
  public static let fallbackNotchSize = CGSize(width: 220, height: 38)
  public static let cornerRadius: CGFloat = 10
  public static let drop: CGFloat = 34
  public static let flare: CGFloat = 16
  public static let dropTraceWidth: CGFloat = 2.5
  public static let edgeTraceWidth: CGFloat = 3
  /// Room under the notch for the dropped tab, and beside it for bare text.
  static let panelExtraHeight: CGFloat = 60
  static let panelExtraWidth: CGFloat = 440

  /// The notch from the screen's auxiliary areas: the gap between them is the
  /// glass. Without them, a drawn notch centred on the FULL frame.
  ///
  /// A visible bar hides anything a window draws in the strip beside the notch,
  /// at every level up to the shielding one, so the Island cannot trace the
  /// glass then. It hangs from the bar's bottom edge instead, in the notchless
  /// form, still centred under the glass where there is one. `menuBarHeight`
  /// is nil while the bar is hidden.
  public static func notch(
    screen: CGRect, menuBarHeight: CGFloat?, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?
  ) -> IslandNotch {
    let barVisible = menuBarHeight != nil
    let top = screen.maxY - (menuBarHeight ?? 0)
    if let left = auxiliaryTopLeft, let right = auxiliaryTopRight {
      let width = screen.width - left.width - right.width
      let height = barVisible ? fallbackNotchSize.height : left.height
      return IslandNotch(
        rect: CGRect(x: screen.minX + left.width, y: top - height, width: width, height: height),
        isReal: !barVisible)
    }
    let size = fallbackNotchSize
    return IslandNotch(
      rect: CGRect(x: screen.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
      isReal: false)
  }

  /// The window: its top on the notch's top (the screen's edge, or the bar's
  /// bottom when the bar is showing), as wide as the screen for the edge styles.
  public static func panelFrame(screen: CGRect, notch: IslandNotch, fullWidth: Bool) -> CGRect {
    let height = notch.rect.height + panelExtraHeight
    let top = notch.rect.maxY
    if fullWidth {
      return CGRect(x: screen.minX, y: top - height, width: screen.width, height: height)
    }
    let width = notch.rect.width + panelExtraWidth
    return CGRect(x: notch.rect.midX - width / 2, y: top - height, width: width, height: height)
  }

  /// The notch in panel coordinates.
  public static func glass(notch: IslandNotch, panel: CGRect) -> CGRect {
    CGRect(x: notch.rect.minX - panel.minX, y: notch.rect.minY - panel.minY,
           width: notch.rect.width, height: notch.rect.height)
  }

  /// One point inside a real notch: the physical corners are rounded and
  /// anything on the exact edge peeks out below them. Without a notch: zero
  /// height on the top edge at the open width, so it only grows down.
  public static func closedTab(notch: IslandNotch, panel: CGRect) -> CGRect {
    let g = glass(notch: notch, panel: panel)
    guard notch.isReal else {
      return CGRect(x: g.minX - flare, y: g.maxY, width: g.width + flare * 2, height: 0)
    }
    return g.insetBy(dx: 1, dy: 0).offsetBy(dx: 0, dy: 1)
  }

  /// Without a notch there is no glass to hang below, so the tab is only the
  /// content row plus a little headroom under the top edge.
  public static func openTab(notch: IslandNotch, panel: CGRect) -> CGRect {
    let g = glass(notch: notch, panel: panel)
    guard notch.isReal else {
      let height = drop + 10
      return CGRect(x: g.minX - flare, y: g.maxY - height, width: g.width + flare * 2, height: height)
    }
    return CGRect(x: g.minX - flare, y: g.minY - drop, width: g.width + flare * 2, height: g.height + drop)
  }

  /// What the edge styles' side information sits either side of: the glass, or
  /// without a notch a narrow gap so name and readout read as one group.
  public static func flank(notch: IslandNotch, panel: CGRect) -> CGRect {
    let g = glass(notch: notch, panel: panel)
    guard notch.isReal else {
      let width: CGFloat = 24
      return CGRect(x: g.midX - width / 2, y: g.minY, width: width, height: g.height)
    }
    return g
  }

  /// The rect a trace of `lineWidth` follows so its inner edge touches the glass.
  public static func glassOutlineRect(closedGlass: CGRect, lineWidth: CGFloat) -> CGRect {
    CGRect(x: closedGlass.minX - lineWidth / 2, y: closedGlass.minY - lineWidth / 2,
           width: closedGlass.width + lineWidth, height: closedGlass.height + lineWidth / 2)
  }

  public enum PathSegment: Equatable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    /// Degrees, y up, as `NSBezierPath.appendArc` reads them; a `CGPath` caller converts to radians.
    case arc(center: CGPoint, radius: CGFloat, startDegrees: CGFloat, endDegrees: CGFloat, clockwise: Bool)
  }

  /// Flush with the top edge: square top corners, rounded bottom ones.
  public static func tabPath(_ r: CGRect) -> [PathSegment] {
    let cr = min(cornerRadius, r.height / 2)
    return [
      .move(CGPoint(x: r.minX, y: r.maxY)),
      .line(CGPoint(x: r.maxX, y: r.maxY)),
      .line(CGPoint(x: r.maxX, y: r.minY + cr)),
      .arc(center: CGPoint(x: r.maxX - cr, y: r.minY + cr), radius: cr, startDegrees: 0, endDegrees: -90, clockwise: true),
      .line(CGPoint(x: r.minX + cr, y: r.minY)),
      .arc(center: CGPoint(x: r.minX + cr, y: r.minY + cr), radius: cr, startDegrees: -90, endDegrees: -180, clockwise: true),
    ]
  }

  /// Around a tab from its top-left corner: down, along the bottom, up to the
  /// top-right corner. Open, so a stroke can draw itself along it.
  public static func outline(around r: CGRect) -> [PathSegment] {
    [.move(CGPoint(x: r.minX, y: r.maxY))] + sides(r) + [.line(CGPoint(x: r.maxX, y: r.maxY))]
  }

  public static func straightEdge(panelWidth: CGFloat, top: CGFloat) -> [PathSegment] {
    [.move(CGPoint(x: 0, y: top)), .line(CGPoint(x: panelWidth, y: top))]
  }

  /// The whole top edge, corner to corner, dipping around the glass.
  public static func edgeOutline(panelWidth: CGFloat, top: CGFloat, around r: CGRect) -> [PathSegment] {
    [.move(CGPoint(x: 0, y: top)), .line(CGPoint(x: r.minX, y: top))]
      + sides(r)
      + [.line(CGPoint(x: r.maxX, y: top)), .line(CGPoint(x: panelWidth, y: top))]
  }

  private static func sides(_ r: CGRect) -> [PathSegment] {
    let cr = cornerRadius
    return [
      .line(CGPoint(x: r.minX, y: r.minY + cr)),
      .arc(center: CGPoint(x: r.minX + cr, y: r.minY + cr), radius: cr, startDegrees: 180, endDegrees: 270, clockwise: false),
      .line(CGPoint(x: r.maxX - cr, y: r.minY)),
      .arc(center: CGPoint(x: r.maxX - cr, y: r.minY + cr), radius: cr, startDegrees: 270, endDegrees: 360, clockwise: false),
    ]
  }
}
