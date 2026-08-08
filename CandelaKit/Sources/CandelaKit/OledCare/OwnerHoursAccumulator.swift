import Foundation

/// Cumulative panel-seconds attributable to each app.
///
/// **Not wall-clock time the app was open.** Each attributed cell contributes
/// `elapsed / PanelGrid.cellCount` — a full-screen app for 60 s books 60 s, an
/// app covering a quarter of the panel for 60 s books 15 s. The number is
/// "panel-seconds this app has occupied", the same accounting shape as
/// `ExposureMap`, and honest in a UI: "Slack: 340 hours" must not be read as
/// "Slack was open 340 hours."
public struct OwnerHours: Equatable, Sendable, Codable {
  public private(set) var secondsByOwner: [String: Double]
  public private(set) var totalSeconds: Double

  public static let empty = OwnerHours(secondsByOwner: [:], totalSeconds: 0)

  /// Descending by seconds, ties broken by owner name so the view does not
  /// reshuffle between frames with equal-weight renders.
  /// Returns **hours**, as the label says. Storage is seconds; the conversion
  /// belongs here rather than at each call site — it shipped briefly returning
  /// raw seconds under this `hours` label, which is a 3600× overstatement one
  /// `Text(...)` away from the screen.
  public func topOwners(limit: Int) -> [(owner: String, hours: Double)] {
    secondsByOwner
      .sorted { lhs, rhs in
        lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
      }
      .prefix(max(0, limit))
      .map { (owner: $0.key, hours: $0.value / 3600) }
  }

  fileprivate mutating func add(_ secondsAdded: [String: Double], totalAdded: Double) {
    for (owner, seconds) in secondsAdded {
      secondsByOwner[owner, default: 0] += seconds
    }
    totalSeconds += totalAdded
  }
}

/// Folds periodic `WindowObservation`s into a per-owner time series.
public struct OwnerHoursAccumulator: Sendable {
  public private(set) var hours: OwnerHours

  public init(hours: OwnerHours = .empty) {
    self.hours = hours
  }

  /// Accumulates one observation. Taken whole or refused whole, matching
  /// `ExposureAccumulator`: this is persisted, so a half-applied sample would
  /// bias the map forever rather than washing out.
  public mutating func accumulate(_ observation: WindowObservation, elapsed: TimeInterval) {
    guard elapsed.isFinite, elapsed > 0 else { return }
    guard observation.dominantOwnerByCell.count == PanelGrid.cellCount else { return }

    let perCell = elapsed / Double(PanelGrid.cellCount)
    var secondsAdded: [String: Double] = [:]
    var totalAdded = 0.0
    for owner in observation.dominantOwnerByCell {
      guard let owner else { continue }
      secondsAdded[owner, default: 0] += perCell
      totalAdded += perCell
    }
    hours.add(secondsAdded, totalAdded: totalAdded)
  }

  public mutating func reset() {
    hours = .empty
  }
}
