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
  /// Edge-to-edge contact. Abutting is what makes a layout legal at all
  /// (`ArrangementRules` requires a shared edge of nonzero length), so it beats
  /// aligning whenever both are the same distance away.
  case abut
  /// Edges or centres line up without touching. Cosmetic, and legal only if
  /// something else already connects the two.
  case align
}

/// One guide to draw. `position` is the display-space coordinate the snap makes
/// the two rects share; `from`/`to` are its extent along the OTHER axis — the
/// union of the two rects, so the line spans exactly what it relates.
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
  /// The moved rect with each axis's winning snap applied. Same size as the
  /// input — snapping moves a display, it never resizes one.
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
/// The two axes are decided **independently**, from candidates read at the
/// pre-snap position. That is what keeps the rule non-circular: an X snap must
/// not change which Y candidates exist, or the answer would depend on which axis
/// was evaluated first.
///
/// The result is a function of the candidate set alone, never of the order the
/// tiles arrive in: every candidate carries a total-order key
/// `(distance, kind, other display id, target)` and the winner is its minimum.
/// A snap decided by array order is not reproducible in a bug report.
///
/// A snap that *produces* an overlap is not undone here. `ArrangementRules`
/// reports it, the tile renders red, and the drop is refused (AR7) — undoing it
/// silently would be the auto-correction AR7 exists to avoid.
public enum ArrangementSnapper {
  /// - Parameter threshold: in **display** points. The authored threshold is in
  ///   canvas points and is converted through the drag's frozen transform
  ///   (§3.3) — `ArrangementDragPolicy` owns that conversion. A threshold below
  ///   1 admits only an exact hit.
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
    /// Where the guide is drawn — the coordinate the two rects come to share.
    let position: Int
  }

  private static func winner(
    on axis: SnapAxis,
    moving: DisplayRect,
    against others: [ArrangementTile],
    threshold: Int
  ) -> Candidate? {
    let origin = origin(moving, axis)
    return others
      .flatMap { candidates(on: axis, moving: moving, other: $0) }
      .filter { abs($0.target - origin) <= threshold }
      // `min(by:)` keeps the FIRST minimal element, and the key below ties only
      // between candidates of one tile — `otherID` separates every other pair —
      // so the winner does not depend on the order `others` arrives in.
      .min { key($0, from: origin) < key($1, from: origin) }
  }

  private static func candidates(
    on axis: SnapAxis,
    moving: DisplayRect,
    other tile: ArrangementTile
  ) -> [Candidate] {
    let source = tile.rect
    let movingExtent = extent(moving, axis)
    let sourceOrigin = origin(source, axis)
    let sourceMax = maxEdge(source, axis)

    func candidate(_ target: Int, _ kind: SnapKind, at position: Int) -> Candidate {
      Candidate(
        axis: axis, target: target, kind: kind,
        otherID: tile.id, otherRect: source, position: position
      )
    }

    var result: [Candidate] = []

    // The crossing precondition, read at the PRE-SNAP position. Without it a
    // tile dragged far above another still feels a magnet from it: the two
    // cannot abut on X at all unless their Y spans overlap, so offering the
    // candidate would snap them into a layout that shares no edge.
    let crosses = DisplayRect.spansOverlap(
      origin(moving, axis.other), maxEdge(moving, axis.other),
      origin(source, axis.other), maxEdge(source, axis.other)
    )
    if crosses {
      result.append(candidate(sourceMax, .abut, at: sourceMax))
      result.append(candidate(sourceOrigin - movingExtent, .abut, at: sourceOrigin))
    }

    result.append(candidate(sourceOrigin, .align, at: sourceOrigin))
    result.append(candidate(sourceMax - movingExtent, .align, at: sourceMax))
    result.append(candidate(
      sourceOrigin + halved(extent(source, axis) - movingExtent),
      .align,
      // The guide is drawn through the OTHER display's centre. The moved tile's
      // own centre can land one point off it, because both this target and a
      // centre are halved integers; at canvas scale (≈12 display points to the
      // canvas point) that is well under a pixel, and picking the stable rect to
      // draw through keeps the guide from jittering as the tile approaches.
      at: sourceOrigin + halved(extent(source, axis))
    ))

    return result
  }

  /// Floor division by two.
  ///
  /// Centre alignment on an **odd** difference cannot land on the exact centre,
  /// so it lands one point below it — deliberate, and pinned by
  /// `centreAlignmentOnAnOddDifferenceRoundsDownByOnePoint`.
  ///
  /// Swift's `/` truncates toward zero, which would round *down* when the other
  /// display is wider and *up* when the moved one is. The bias would then depend
  /// on which of two displays the user happened to grab, and dragging A onto B
  /// would not undo dragging B onto A. Flooring makes the one-point offset a
  /// single stated rule in both directions.
  private static func halved(_ value: Int) -> Int {
    value >= 0 ? value / 2 : (value - 1) / 2
  }

  private static func key(
    _ candidate: Candidate,
    from origin: Int
  ) -> (Int, SnapKind, CGDirectDisplayID, Int) {
    (abs(candidate.target - origin), candidate.kind, candidate.otherID, candidate.target)
  }

  // MARK: - Lines

  private static func line(for candidate: Candidate, snapped: DisplayRect) -> SnapLine {
    // The extent is taken along the other axis from the SNAPPED rect, so the
    // guide spans where the tile actually is rather than where it was grabbed.
    let across = candidate.axis.other
    let from = min(origin(snapped, across), origin(candidate.otherRect, across))
    let to = max(maxEdge(snapped, across), maxEdge(candidate.otherRect, across))

    return SnapLine(
      axis: candidate.axis,
      position: candidate.position,
      kind: candidate.kind,
      otherDisplayID: candidate.otherID,
      from: from,
      to: to
    )
  }

  // MARK: - Axis projection

  private static func origin(_ rect: DisplayRect, _ axis: SnapAxis) -> Int {
    axis == .x ? rect.x : rect.y
  }

  private static func extent(_ rect: DisplayRect, _ axis: SnapAxis) -> Int {
    axis == .x ? rect.width : rect.height
  }

  private static func maxEdge(_ rect: DisplayRect, _ axis: SnapAxis) -> Int {
    axis == .x ? rect.maxX : rect.maxY
  }
}
