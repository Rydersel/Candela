import CoreGraphics

/// Shared step rule: a half step lights the nearer unit.
public enum IndicatorSteps {
  public static func filled(_ value: Double, of count: Int) -> Int {
    let clamped = min(max(value, 0), 1)
    return Int((clamped * Double(count)).rounded())
  }
}

/// The box macOS drew from OS X through Sonoma, measured from the system's own
/// window on 2026-10-01. Window-local points, y up.
public enum ClassicBox {
  public static let size = CGSize(width: 200, height: 200)
  public static let cornerRadius: CGFloat = 16
  public static let trackRect = CGRect(x: 20, y: 20, width: 161, height: 8)
  public static let chicletCount = 16
  public static let chicletSize = CGSize(width: 9, height: 6)
  public static let chicletPitch: CGFloat = 10
  /// The glyph PDF's page, 170 square, centred 100 from the top. The drawing
  /// inside the page sits above its centre, which is why the page centre is
  /// lower than the glyph reads.
  public static let glyphRect = CGRect(x: 15, y: 15, width: 170, height: 170)

  public static func chicletRect(_ index: Int) -> CGRect {
    CGRect(
      x: trackRect.minX + 1 + CGFloat(index) * chicletPitch,
      y: trackRect.minY + 1,
      width: chicletSize.width, height: chicletSize.height
    )
  }
}

/// The small square macOS 15 drew.
public enum SequoiaBox {
  public static let size = CGSize(width: 92, height: 92)
  public static let cornerRadius: CGFloat = 20
  public static let glyphPointSize: CGFloat = 34
  /// The glyph centres in the part above the bar.
  public static let glyphRect = CGRect(x: 24, y: 36, width: 44, height: 40)
  public static let barRect = CGRect(x: 20, y: 16, width: 52, height: 3)

  public static func fillRect(value: Double) -> CGRect {
    let clamped = CGFloat(min(max(value, 0), 1))
    return CGRect(x: barRect.minX, y: barRect.minY,
                  width: max(barRect.height, barRect.width * clamped), height: barRect.height)
  }
}

public enum VerticalPill {
  public static let size = CGSize(width: 56, height: 180)
  public static let cornerRadius: CGFloat = 28
  public static let glyphPointSize: CGFloat = 18
  /// Glyph box centred 18 above the bottom.
  public static let glyphRect = CGRect(x: 16, y: 18, width: 24, height: 22)

  public static func fillHeight(value: Double) -> CGFloat {
    size.height * CGFloat(min(max(value, 0), 1))
  }
}

public enum RingDial {
  public static let size = CGSize(width: 120, height: 120)
  public static let cornerRadius: CGFloat = 28
  public static let radius: CGFloat = 40
  public static let lineWidth: CGFloat = 6
  public static let dotRadius: CGFloat = 49
  public static let dotCount = 16
  public static let dotDiameter: CGFloat = 2
  public static let glyphPointSize: CGFloat = 26
  public static let glyphRect = CGRect(x: 43, y: 45, width: 34, height: 30)
  public static let center = CGPoint(x: 60, y: 60)
  /// Twelve o'clock in a y-up frame.
  public static let startDegrees: CGFloat = 90

  /// The arc's end angle, sweeping clockwise (decreasing degrees) from twelve.
  public static func sweepEndDegrees(value: Double) -> CGFloat {
    startDegrees - 360 * CGFloat(min(max(value, 0), 1))
  }

  public static func dotCenter(_ index: Int) -> CGPoint {
    let degrees = startDegrees - CGFloat(index) * (360 / CGFloat(dotCount))
    let radians = degrees * .pi / 180
    return CGPoint(x: center.x + dotRadius * cos(radians), y: center.y + dotRadius * sin(radians))
  }
}
