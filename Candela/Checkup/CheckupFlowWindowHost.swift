import CoreGraphics

/// Where the checkup flow window goes as a field goes up on the target (CK16:
/// the field covers the target, so the controls belong on another display).
///
/// Pure over frames so the rule is testable without screens. The rule is
/// "leave only if you must": a window the person is already looking at stays,
/// and one on the target goes to the nearest other screen rather than to the
/// first one AppKit lists, which read as a random jump.
enum CheckupFlowWindowHost {
  struct Screen: Equatable {
    var id: CGDirectDisplayID
    var frame: CGRect
  }

  /// Nil means stay: no other screen, or already off the target.
  static func host(for window: CGRect, target: CGDirectDisplayID, screens: [Screen]) -> Screen? {
    let center = CGPoint(x: window.midX, y: window.midY)
    // The screen under the window's centre is the one it is "on"; a window
    // straddling an edge counts as being on the one holding most of it.
    let current = screens.first { $0.frame.contains(center) }
      ?? screens.max { $0.frame.intersection(window).area < $1.frame.intersection(window).area }
    if let current, current.id != target { return nil }
    let others = screens.filter { $0.id != target }
    return others.min {
      distance(from: center, to: $0.frame) < distance(from: center, to: $1.frame)
    }
  }

  private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return (dx * dx + dy * dy).squareRoot()
  }
}

private extension CGRect {
  var area: CGFloat { isNull ? 0 : width * height }
}
