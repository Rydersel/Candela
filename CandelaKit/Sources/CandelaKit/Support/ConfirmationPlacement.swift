import CoreGraphics
import Foundation

/// Where a keep-or-revert window goes when it is not the only one asking.
///
/// Every reconfiguration surface owns its own confirmation window and each one
/// centred on the display it was asking about, so two questions resolving to the
/// same display landed on exactly the same point. A refused mirroring change
/// once drew the words the reconfiguration gate requires straight over a live
/// arrangement countdown.
///
/// The incumbent keeps its place and the newcomer moves. That is not a judgement
/// about which question matters more, which would need the cross-surface
/// knowledge that is deliberately kept out of the islands: the newcomer is
/// placed CLEAR of what is already on screen, so both are readable whichever
/// arrived first.
public enum ConfirmationPlacement {
  /// Between two windows. Enough to read as separate windows rather than one
  /// mis-drawn one.
  public static let gap: CGFloat = 12
  /// Used only when nothing fits clear, where the goal drops from "both
  /// readable" to "visibly two windows".
  private static let cascade: CGFloat = 28

  /// The origin for a window of `size`, in AppKit's y-up coordinates.
  ///
  /// Centred when nothing else is up. Otherwise the closest position to that
  /// centre that fits entirely on screen and touches none of `occupied`: below,
  /// above, left, right, in that order, so the result is stable rather than
  /// dependent on how the candidates happen to tie.
  ///
  /// Falls back to a step off the centre when the screen has no room for two
  /// windows at all. The pair overlaps, but the one underneath is visibly there,
  /// which an exact stack never was.
  public static func origin(
    size: CGSize, in visibleFrame: CGRect, avoiding occupied: [CGRect]
  ) -> CGPoint {
    let centred = CGPoint(
      x: visibleFrame.midX - size.width / 2,
      y: visibleFrame.midY - size.height / 2
    )
    let live = occupied.filter { !$0.isEmpty }
    guard !live.isEmpty else { return centred }

    // The union, not each rect: a newcomer placed below ONE incumbent could
    // still land on another, and the fallback below is the only thing that may
    // overlap anything.
    let union = live.dropFirst().reduce(live[0]) { $0.union($1) }
    let candidates = [
      centred,
      CGPoint(x: centred.x, y: union.minY - gap - size.height),
      CGPoint(x: centred.x, y: union.maxY + gap),
      CGPoint(x: union.minX - gap - size.width, y: centred.y),
      CGPoint(x: union.maxX + gap, y: centred.y),
    ]
    let clear = candidates.filter { origin in
      let rect = CGRect(origin: origin, size: size)
      return visibleFrame.contains(rect) && !live.contains { $0.intersects(rect) }
    }
    // `min(by:)` keeps the first of equal elements, so the candidate order
    // above breaks ties and the centred position wins outright when it is free.
    if let best = clear.min(by: { distance($0, centred) < distance($1, centred) }) {
      return best
    }
    return clamp(
      CGPoint(x: centred.x + cascade, y: centred.y - cascade), size: size, in: visibleFrame
    )
  }

  private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
  }

  /// Keeps a window on screen. The inner `max` matters for a window taller or
  /// wider than the space it is going into: without it the upper bound falls
  /// below the lower one and the clamp reports a position off the top or left.
  private static func clamp(_ origin: CGPoint, size: CGSize, in frame: CGRect) -> CGPoint {
    CGPoint(
      x: min(max(origin.x, frame.minX), max(frame.minX, frame.maxX - size.width)),
      y: min(max(origin.y, frame.minY), max(frame.minY, frame.maxY - size.height))
    )
  }
}
