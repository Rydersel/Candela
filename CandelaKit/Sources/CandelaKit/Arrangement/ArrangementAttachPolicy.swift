import CoreGraphics
import Foundation

public struct ArrangementAttachment: Sendable, Equatable {
  /// Same size as the input: attaching moves a display, it never resizes one.
  public let rect: DisplayRect
  /// The guide for the edge it came to rest against.
  public let line: SnapLine

  public init(rect: DisplayRect, line: SnapLine) {
    self.rect = rect
    self.line = line
  }
}

/// Where a display goes when it is let go somewhere it cannot legally stay.
///
/// A layout where some display touches nothing is invalid (`ArrangementRules`) and
/// macOS will not hold one. A drop into open space is not ambiguous, though, so it
/// attaches rather than springing back; only the edge is in question.
///
/// NEAR, not nearest. Each candidate's cross-axis coordinate is tidied first,
/// and only the tidied candidates are ranked by distance. A drop past the end of
/// another display therefore goes flush rather than landing at the strictly nearest
/// legal position, which would leave the two meeting over a single point.
///
/// The search is over whole placements rather than one axis at a time, which is the
/// difference from `ArrangementSnapper`: with no distance limit the two axes can be
/// won by different displays and produce a placement that abuts neither.
public enum ArrangementAttachPolicy {
  /// - Parameters:
  ///   - moving: where the user let go, before snapping. Distance is measured from
  ///     here, so the ranking is against the gesture, not against magnetism's result.
  ///   - threshold: the drag's own snap threshold. It does not limit how far a
  ///     display may attach, only whether a candidate already close to a lined-up
  ///     edge tidies onto it.
  /// - Returns: a legal abutting position near where the user let go, or `nil` once
  ///   the candidate set is exhausted. The set is four per other display, so `nil` is
  ///   narrower than "no legal abutting position exists".
  public static func attach(
    _ moving: DisplayRect,
    id: CGDirectDisplayID,
    in baseline: DisplayArrangement,
    threshold: Int
  ) -> ArrangementAttachment? {
    let others = baseline.tiles.filter { $0.id != id }
    guard !others.isEmpty, moving.width > 0, moving.height > 0 else { return nil }

    // Walked in order until one is legal: the closest placement can be blocked by a
    // third display, and the answer is then the next one out rather than a refusal.
    // Every position returned is one the layout can be left in, which is what lets
    // callers apply it unchecked.
    for candidate in candidates(moving, against: others, threshold: threshold)
      .sorted(by: { key($0, from: moving) < key($1, from: moving) })
    {
      let arrangement = baseline.moving(id, to: candidate.rect.origin)
      guard ArrangementRules.problems(in: arrangement).isEmpty else { continue }
      return ArrangementAttachment(rect: candidate.rect, line: line(for: candidate))
    }

    return nil
  }

  // MARK: - Candidates

  private struct Candidate {
    let rect: DisplayRect
    let axis: SnapAxis
    /// 0 when the moved display lands on the LOW side of the other one, 1 on
    /// the high side. Carried only to keep the ranking total.
    let side: Int
    let otherID: CGDirectDisplayID
    let otherRect: DisplayRect
    /// The coordinate the two come to share, which is where the guide is drawn.
    let position: Int
  }

  private static func candidates(
    _ moving: DisplayRect,
    against others: [ArrangementTile],
    threshold: Int
  ) -> [Candidate] {
    var result: [Candidate] = []

    for tile in others {
      for axis in [SnapAxis.x, .y] {
        let cross = axis.other
        let crossValue = crossPlacement(
          moving, on: cross, against: tile.rect, threshold: threshold
        )

        for side in 0 ... 1 {
          let edge = side == 0 ? tile.rect.start(on: axis) : tile.rect.end(on: axis)
          let origin = side == 0 ? edge - moving.length(on: axis) : edge

          result.append(
            Candidate(
              rect: moving.placing(on: axis, at: origin).placing(on: cross, at: crossValue),
              axis: axis,
              side: side,
              otherID: tile.id,
              otherRect: tile.rect,
              position: edge
            )
          )
        }
      }
    }

    return result
  }

  /// The cross-axis coordinate of an attachment, in two cases because one rule reads
  /// badly at both ends. A drop still overlapping the other display expresses a
  /// position, so it keeps it, tidied onto a lined-up edge within the threshold.
  /// A drop clear of that span expresses none, and the nearest coordinate that still
  /// shares an edge would leave the two sharing a single point of it, so it goes
  /// flush with the end it is nearest.
  private static func crossPlacement(
    _ moving: DisplayRect,
    on axis: SnapAxis,
    against other: DisplayRect,
    threshold: Int
  ) -> Int {
    let length = moving.length(on: axis)

    guard moving.spansOverlap(with: other, on: axis) else {
      return moving.start(on: axis) >= other.end(on: axis)
        ? other.end(on: axis) - length
        : other.start(on: axis)
    }

    // The drop's own coordinate is already legal, by algebra: `DisplayRect.touches`
    // wants a shared boundary of nonzero length, which is the band
    // `other.start - length + 1 ... other.end - 1`, and the `spansOverlap` guard
    // above IS the statement that `moving.start` lies in it. A clamp onto that band
    // therefore cannot fire and is not here. Loosen or remove the guard and the band
    // has to come back with it.
    let dropped = moving.start(on: axis)

    let aligned = [
      other.start(on: axis),
      other.end(on: axis) - length,
      other.start(on: axis) + ArrangementSnapper.halved(other.length(on: axis) - length),
    ]
    .filter { abs($0 - dropped) <= threshold }
    .min { (abs($0 - dropped), $0) < (abs($1 - dropped), $1) }

    return aligned ?? dropped
  }

  /// Squared distance from where the user let go, then terms that exist only to make
  /// the order total. Squared rather than rooted so integers keep it exact.
  private static func key(
    _ candidate: Candidate,
    from moving: DisplayRect
  ) -> (Int, CGDirectDisplayID, Int, Int, Int, Int) {
    let dx = candidate.rect.x - moving.x
    let dy = candidate.rect.y - moving.y
    return (
      dx * dx + dy * dy,
      candidate.otherID,
      candidate.axis == .x ? 0 : 1,
      candidate.side,
      candidate.rect.x,
      candidate.rect.y
    )
  }

  private static func line(for candidate: Candidate) -> SnapLine {
    let across = candidate.axis.other
    return SnapLine(
      axis: candidate.axis,
      position: candidate.position,
      kind: .abut,
      otherDisplayID: candidate.otherID,
      from: min(candidate.rect.start(on: across), candidate.otherRect.start(on: across)),
      to: max(candidate.rect.end(on: across), candidate.otherRect.end(on: across))
    )
  }
}
