import CoreGraphics
import Foundation

/// Which coordinate a snap constrains.
public enum SnapAxis: Sendable, Equatable, Hashable {
  /// Constrains `x`, so the guide drawn for it is a **vertical** line.
  case x
  /// Constrains `y`, so the guide drawn for it is a **horizontal** line.
  case y

  var other: SnapAxis { self == .x ? .y : .x }
}

/// Ordered: `abut` sorts before `align`, which is the tie-break in §3.4.
public enum SnapKind: Sendable, Equatable, Hashable, Comparable {
  /// Edge-to-edge contact. Abutting is what makes a layout legal at all, so it beats
  /// aligning whenever both are the same distance away.
  case abut
  /// Edges or centres line up without touching. Legal only if something else already
  /// connects the two.
  case align
}

/// One guide to draw. `position` is the display-space coordinate the snap makes the
/// two rects share; `from`/`to` are its extent along the OTHER axis, the union of the
/// two rects, so the line spans exactly what it relates.
public struct SnapLine: Sendable, Equatable {
  public let axis: SnapAxis
  public let position: Int
  public let kind: SnapKind
  public let otherDisplayID: CGDirectDisplayID
  public let from: Int
  public let to: Int

  public init(
    axis: SnapAxis,
    position: Int,
    kind: SnapKind,
    otherDisplayID: CGDirectDisplayID,
    from: Int,
    to: Int
  ) {
    self.axis = axis
    self.position = position
    self.kind = kind
    self.otherDisplayID = otherDisplayID
    self.from = from
    self.to = to
  }
}

public struct SnapResult: Sendable, Equatable {
  /// Same size as the input: snapping moves a display, it never resizes one.
  public let rect: DisplayRect
  /// At most one line per axis, X before Y.
  public let lines: [SnapLine]

  public init(rect: DisplayRect, lines: [SnapLine]) {
    self.rect = rect
    self.lines = lines
  }
}

/// drag-canvas §3.4.
///
/// The two axes are decided **independently**, from candidates read at the pre-snap
/// position. That keeps the rule non-circular: an X snap must not change which Y
/// candidates exist, or the answer would depend on which axis ran first.
///
/// Candidates are ranked by `(distance, kind, other display id, target, guide
/// position)`, a strict total order over tiles with distinct ids. Nothing here reads
/// the order `tiles` arrives in; a snap decided by array order is not reproducible in
/// a bug report.
///
/// A snap that *produces* an overlap is not undone here, because undoing it silently
/// is the auto-correction the spring-back rule avoids. `ArrangementDragPolicy`
/// reports it through the
/// proposal's `problems`.
public enum ArrangementSnapper {
  /// - Parameter threshold: in **display** points. `ArrangementDragPolicy` owns the
  ///   conversion from the authored canvas points (§3.3). A threshold of 0 admits only
  ///   an exact hit; a negative one admits nothing.
  public static func snap(
    _ moving: DisplayRect,
    id: CGDirectDisplayID,
    against tiles: [ArrangementTile],
    threshold: Int
  ) -> SnapResult {
    let others = tiles.filter { $0.id != id }
    let x = winner(on: .x, moving: moving, against: others, threshold: threshold)
    let y = winner(on: .y, moving: moving, against: others, threshold: threshold)

    let snapped = DisplayRect(
      x: x?.target ?? moving.x,
      y: y?.target ?? moving.y,
      width: moving.width,
      height: moving.height
    )

    return SnapResult(
      rect: snapped,
      lines: [x, y].compactMap { $0 }.map { line(for: $0, snapped: snapped) }
    )
  }

  // MARK: - Candidates

  private struct Candidate {
    let axis: SnapAxis
    /// The value the moved rect's origin takes on this axis if this candidate wins.
    let target: Int
    let kind: SnapKind
    let otherID: CGDirectDisplayID
    let otherRect: DisplayRect
    /// Where the guide is drawn: the coordinate the two rects come to share.
    let position: Int
  }

  private static func winner(
    on axis: SnapAxis,
    moving: DisplayRect,
    against others: [ArrangementTile],
    threshold: Int
  ) -> Candidate? {
    let origin = moving.start(on: axis)
    return others
      .flatMap { candidates(on: axis, moving: moving, other: $0) }
      .filter { abs($0.target - origin) <= threshold }
      .min { key($0, from: origin) < key($1, from: origin) }
  }

  private static func candidates(
    on axis: SnapAxis,
    moving: DisplayRect,
    other tile: ArrangementTile
  ) -> [Candidate] {
    let source = tile.rect
    let movingExtent = moving.length(on: axis)
    let sourceOrigin = source.start(on: axis)
    let sourceMax = source.end(on: axis)

    func candidate(_ target: Int, _ kind: SnapKind, at position: Int) -> Candidate {
      Candidate(
        axis: axis, target: target, kind: kind,
        otherID: tile.id, otherRect: source, position: position
      )
    }

    // Generated align-first, the REVERSE of the preference, so the ranking key is the
    // only thing that can make an abut win a tie. Abuts first and dropping `kind` from
    // the key would leave behaviour unchanged, with no test able to see it.
    var result: [Candidate] = [
      candidate(sourceOrigin, .align, at: sourceOrigin),
      candidate(sourceMax - movingExtent, .align, at: sourceMax),
      candidate(
        sourceOrigin + halved(source.length(on: axis) - movingExtent),
        .align,
        // Drawn through the OTHER display's centre. The moved tile's own centre can
        // land one point off, since both are halved integers, and drawing through the
        // rect that is not moving keeps the guide from jittering.
        at: sourceOrigin + halved(source.length(on: axis))
      ),
    ]

    // The crossing precondition, read at the PRE-SNAP position. Two rects cannot abut
    // on X unless their Y spans overlap, so without this a tile dragged far above
    // another still feels a magnet and snaps into a layout sharing no edge.
    let crosses = moving.spansOverlap(with: source, on: axis.other)
    if crosses {
      result.append(candidate(sourceMax, .abut, at: sourceMax))
      result.append(candidate(sourceOrigin - movingExtent, .abut, at: sourceOrigin))
    }

    return result
  }

  /// Floor division by two.
  ///
  /// Centre alignment on an **odd** difference lands one point below the exact
  /// centre, deliberately.
  ///
  /// Swift's `/` truncates toward zero, which rounds *down* when the other display is
  /// wider and *up* when the moved one is. The bias would depend on which display the
  /// user grabbed, so dragging A onto B would not undo dragging B onto A.
  ///
  /// Internal rather than private so `ArrangementDockPolicy` centres a keyboard dock
  /// the same way. Two copies would land an arrow press and a drag one point apart on
  /// every odd difference.
  static func halved(_ value: Int) -> Int {
    value >= 0 ? value / 2 : (value - 1) / 2
  }

  /// `position` is last so the ranking is a strict total order rather than leaving
  /// `min(by:)`'s first-minimal-wins to decide. Reachable: two displays of the same
  /// width offer leading- and trailing-edge aligns with the same target, and this
  /// makes the leading edge the one the guide names.
  ///
  /// `target` is §3.4's and decides nothing today, since two candidates of one display
  /// share a kind and a distance only where the centre-align candidate already wins at
  /// distance zero. It stays so the order is total for whatever is added next.
  private static func key(
    _ candidate: Candidate,
    from origin: Int
  ) -> (Int, SnapKind, CGDirectDisplayID, Int, Int) {
    (
      abs(candidate.target - origin), candidate.kind, candidate.otherID,
      candidate.target, candidate.position
    )
  }

  // MARK: - Lines

  private static func line(for candidate: Candidate, snapped: DisplayRect) -> SnapLine {
    // Taken from the SNAPPED rect, so the guide spans where the tile is rather than
    // where it was grabbed.
    let across = candidate.axis.other
    let from = min(snapped.start(on: across), candidate.otherRect.start(on: across))
    let to = max(snapped.end(on: across), candidate.otherRect.end(on: across))

    return SnapLine(
      axis: candidate.axis,
      position: candidate.position,
      kind: candidate.kind,
      otherDisplayID: candidate.otherID,
      from: from,
      to: to
    )
  }
}
