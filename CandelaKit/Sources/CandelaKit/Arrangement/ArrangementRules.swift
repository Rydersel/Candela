import CoreGraphics
import Foundation

public enum ArrangementProblem: Sendable, Equatable {
  /// Lower id first, once per pair.
  case overlap(CGDirectDisplayID, CGDirectDisplayID)
  case disconnected(CGDirectDisplayID)

  /// The two kinds are not interchangeable to a drop. A display touching
  /// nothing has an obvious repair (put it against the nearest edge) and a
  /// display on top of another does not, so `ArrangementDragPolicy` attaches
  /// the first and springs the second back under AR7.
  var isDisconnection: Bool {
    if case .disconnected = self { return true }
    return false
  }
}

/// drag-canvas §3.2. An arrangement is valid iff no pair of displays overlaps and
/// every display is reachable from every other along shared edges.
///
/// macOS cannot be made to hold an invalid arrangement — it silently moves things
/// to somewhere of its own choosing instead (§3.1) — so the UI refuses the drop
/// rather than letting the map lie about where the displays ended up (AR7).
public enum ArrangementRules {
  public static func isValid(_ arrangement: DisplayArrangement) -> Bool {
    problems(in: arrangement).isEmpty
  }

  public static func problems(in arrangement: DisplayArrangement) -> [ArrangementProblem] {
    let tiles = arrangement.tiles
    guard tiles.count > 1 else { return [] }

    // `DisplayArrangement` sorts its tiles by id, so this visits each pair once
    // with the lower id first.
    var overlaps: [ArrangementProblem] = []
    for i in tiles.indices {
      for j in (i + 1) ..< tiles.count where tiles[i].rect.overlaps(tiles[j].rect) {
        overlaps.append(.overlap(tiles[i].id, tiles[j].id))
      }
    }

    // Overlapping displays are "connected" in the graph sense while being an
    // illegal layout, so an overlap manufactures a disconnection report of its
    // own. One cause, one report.
    guard overlaps.isEmpty else { return overlaps }

    let groups = connectedGroups(tiles)
    guard groups.count > 1 else { return [] }

    // The largest group is the layout; everything else is stranded. Blaming the
    // smaller groups reddens the fewest tiles, and the tiles it reddens are the
    // ones that have to move. Groups arrive in ascending order of their lowest
    // id and only a strictly larger one displaces the incumbent, so equal-sized
    // groups are broken by the lowest display id.
    var kept = groups[0]
    for group in groups.dropFirst() where group.count > kept.count { kept = group }

    let keptIDs = Set(kept.map { tiles[$0].id })
    return tiles.map(\.id).filter { !keptIDs.contains($0) }.map(ArrangementProblem.disconnected)
  }

  /// Connected components of the edge-adjacency graph, as indices into `tiles`.
  ///
  /// A flood fill, not a pairwise check: a three-display row is one component
  /// even though its ends never touch each other.
  private static func connectedGroups(_ tiles: [ArrangementTile]) -> [[Int]] {
    var seen = Set<Int>()
    var groups: [[Int]] = []

    for start in tiles.indices where !seen.contains(start) {
      var group: [Int] = []
      var frontier = [start]
      seen.insert(start)

      while let current = frontier.popLast() {
        group.append(current)
        for next in tiles.indices
          where !seen.contains(next) && tiles[current].rect.touches(tiles[next].rect)
        {
          seen.insert(next)
          frontier.append(next)
        }
      }

      groups.append(group)
    }

    return groups
  }
}
