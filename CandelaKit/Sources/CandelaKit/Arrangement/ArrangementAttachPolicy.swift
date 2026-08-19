import CoreGraphics
import Foundation

public struct ArrangementAttachment: Sendable, Equatable {
  /// The dragged display's rect at the position it attached to. Same size as
  /// the input: attaching moves a display, it never resizes one.
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
/// A layout in which some display touches nothing is invalid
/// (`ArrangementRules`), and macOS cannot be made to hold one, so today such a
/// drop springs back and the user is told only that it was refused. They are not
/// shown where it could have gone. Springing back is the right answer when the
/// request is ambiguous, but a drop into open space is not ambiguous: every
/// legal layout has the display touching something, so the question is only
/// which edge, and the nearest one is the answer the gesture already implies.
///
/// The search is over whole placements rather than one axis at a time, which is
/// the difference from `ArrangementSnapper`. Deciding the axes independently is
/// right for magnetism, where both candidates come from displays already
/// nearby; it is wrong here, because with no distance limit the two axes can be
/// won by different displays and produce a placement that abuts neither.
public enum ArrangementAttachPolicy {
  /// - Parameters:
  ///   - moving: the dragged display's rect where the user let go, before
  ///     snapping. Distance is measured from here, so "nearest" means nearest to
  ///     the gesture rather than to whatever magnetism did with it.
  ///   - threshold: the same display-space snap threshold the drag uses. It does
  ///     not limit how far a display may attach: it only decides whether an
  ///     attachment that is already close to a lined-up edge tidies onto it.
  /// - Returns: `nil` when nothing can be attached to, which is a layout of one
  ///   display, or one where every position that touches something overlaps
  ///   something else.
  public static func attach(
    _ moving: DisplayRect,
    id: CGDirectDisplayID,
    in baseline: DisplayArrangement,
    threshold: Int
  ) -> ArrangementAttachment? {
    let others = baseline.tiles.filter { $0.id != id }
    guard !others.isEmpty, moving.width > 0, moving.height > 0 else { return nil }

    // Ranked once, then walked in order until one is legal, rather than ranked
    // and checked once. The nearest placement can be blocked by a third display,
    // and the answer is then the next nearest rather than a refusal: "nearest
    // LEGAL position" is the whole contract, and validity is what makes it legal.
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

  /// The cross-axis coordinate of an attachment.
  ///
  /// Two cases, because one rule reads badly at both ends. When the drop still
  /// overlaps the other display on this axis the user has expressed a position,
  /// so the answer is the nearest one a shared edge allows, tidied onto a
  /// lined-up edge if it is already within the snap threshold of one.
  ///
  /// When the drop has left that display's span entirely, they have not. Taking
  /// the nearest coordinate that still shares an edge would leave the two
  /// displays sharing a single point of it, which looks like a misfire rather
  /// than an attachment. Going flush with the end the drop is nearest gives a
  /// full shared edge and still reflects which way the display was dragged.
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

    // The drop's own coordinate is already a legal one. `DisplayRect.touches`
    // wants a shared boundary of nonzero length, which is the band
    // `other.start - length + 1 ... other.end - 1`, and the `spansOverlap`
    // guard above IS the statement that `moving.start` lies in it. A clamp onto
    // that band and a filter holding the alignment candidates inside it were
    // both written here and both provably never fired: checked exhaustively
    // over 70,824 pairs, neither changed an answer once. Anything that loosens
    // or removes the guard has to bring the band back with it, because then the
    // drop's coordinate is no longer known to touch at all.
    // Named for what it is rather than for a clamp that no longer happens.
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

  /// Squared distance from where the user let go, then terms that exist only to
  /// make the order strict and total. Squared rather than rooted: the comparison
  /// is the only thing it is used for, and integers keep it exact.
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
