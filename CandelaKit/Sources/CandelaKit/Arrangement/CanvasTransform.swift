import Foundation

/// Canvas space: the view's local coordinate space, origin top-left, y-**down**, in
/// canvas points. Same handedness as display space, so the mapping is a uniform scale
/// plus a translation with **no flip anywhere** (AR1).
public struct CanvasSize: Sendable, Equatable {
  public var width: Double
  public var height: Double

  public init(width: Double, height: Double) {
    self.width = width
    self.height = height
  }
}

public struct CanvasPoint: Sendable, Equatable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }

  public static let zero = CanvasPoint(x: 0, y: 0)
}

public struct CanvasRect: Sendable, Equatable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var maxX: Double { x + width }
  public var maxY: Double { y + height }
  public var midX: Double { x + width / 2 }
  public var midY: Double { y + height / 2 }
}

/// The one mapping between display space and canvas space. The app target never
/// reimplements any part of it.
public struct CanvasTransform: Sendable, Equatable {
  /// Canvas points per display point. Finite and > 0, enforced by `init`.
  public let scale: Double
  public let offsetX: Double
  public let offsetY: Double

  /// `scale == 0` makes `displayPoint` evaluate `Int(±infinity)`, which traps far from
  /// the mistake, and a NaN or infinite scale poisons every coordinate it touches. A
  /// precondition rather than an `internal` access level so in-module callers are
  /// covered too.
  public init(scale: Double, offsetX: Double, offsetY: Double) {
    precondition(scale > 0 && scale.isFinite, "CanvasTransform.scale must be finite and > 0")
    self.scale = scale
    self.offsetX = offsetX
    self.offsetY = offsetY
  }

  /// `headroom` reserves slack so a tile dragged outward has somewhere to go, applied
  /// to the **scale only**. Centring uses the true bounds, so freezing the transform
  /// at drag start (AR2) changes nothing visually.
  public static func fitting(
    _ bounds: DisplayRect,
    in canvas: CanvasSize,
    margin: Double = 12,
    headroom: Double = 0.18
  ) -> CanvasTransform {
    let innerW = max(1, canvas.width - 2 * margin)
    let innerH = max(1, canvas.height - 2 * margin)
    let padded = 1 + 2 * headroom

    // No upper clamp. A `min(fit, 1.0)` cannot overflow the canvas, but it renders a
    // small arrangement postage-stamp-sized instead of filling the space the margin
    // and headroom leave. Extra terms may go inside this `min`; nothing after it.
    let fitted = min(innerW / (Double(bounds.width) * padded),
                     innerH / (Double(bounds.height) * padded))

    // An empty arrangement has zero-size bounds, dividing by zero on both axes.
    // Identity renders nothing rather than NaN and keeps the `scale > 0` guarantee the
    // round trip depends on.
    let scale = fitted.isFinite && fitted > 0 ? fitted : 1

    let cx = Double(bounds.x) + Double(bounds.width) / 2
    let cy = Double(bounds.y) + Double(bounds.height) / 2

    return CanvasTransform(
      scale: scale,
      offsetX: canvas.width / 2 - scale * cx,
      offsetY: canvas.height / 2 - scale * cy
    )
  }

  public func canvasPoint(_ point: DisplayPoint) -> CanvasPoint {
    CanvasPoint(x: Double(point.x) * scale + offsetX, y: Double(point.y) * scale + offsetY)
  }

  public func canvasRect(_ rect: DisplayRect) -> CanvasRect {
    CanvasRect(
      x: Double(rect.x) * scale + offsetX,
      y: Double(rect.y) * scale + offsetY,
      width: Double(rect.width) * scale,
      height: Double(rect.height) * scale
    )
  }

  /// Rounded to nearest, **away from zero**. Truncation biases every negative
  /// coordinate one point toward the origin, and negative coordinates are where the
  /// displays left of and above main live.
  public func displayPoint(_ point: CanvasPoint) -> DisplayPoint {
    DisplayPoint(
      x: Int(((point.x - offsetX) / scale).rounded()),
      y: Int(((point.y - offsetY) / scale).rounded())
    )
  }

  /// A length, not a position: converts **without** the centring offset.
  public func displayDistance(_ distance: Double) -> Int {
    Int((distance / scale).rounded())
  }
}
