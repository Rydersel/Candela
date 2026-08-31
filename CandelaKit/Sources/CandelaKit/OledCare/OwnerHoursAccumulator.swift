import Foundation

/// Cumulative panel-seconds attributable to each app.
///
/// **Not wall-clock time the app was open.** Each attributed cell contributes
/// `elapsed / PanelGrid.cellCount`, so a full-screen app for 60 s books 60 s and
/// one covering a quarter of the panel books 15 s. "Slack: 340 hours" must not
/// be read as "Slack was open 340 hours."
public struct OwnerHours: Equatable, Sendable, Codable {
  public private(set) var secondsByOwner: [String: Double]
  public private(set) var totalSeconds: Double

  public static let empty = OwnerHours(secondsByOwner: [:], totalSeconds: 0)

  /// Descending by seconds, ties broken by owner name so the view does not
  /// reshuffle between equal-weight renders.
  ///
  /// Returns **hours**; storage is seconds. It shipped briefly returning raw
  /// seconds under this label, a 3600× overstatement one `Text(...)` from the
  /// screen.
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

  /// Spelled out rather than synthesised. These strings are shipped on-disk
  /// schema and were once the property names themselves, so renaming
  /// `secondsByOwner` deleted every user's history without a diagnostic.
  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schemaVersion"
    case secondsByOwner = "secondsByOwner"
    case totalSeconds = "totalSeconds"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(OledStoreSchema.currentVersion, forKey: .schemaVersion)
    try container.encode(secondsByOwner, forKey: .secondsByOwner)
    try container.encode(totalSeconds, forKey: .totalSeconds)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard version <= OledStoreSchema.currentVersion else {
      throw OledStoreDecodeFailure.unsupportedVersion(
        found: version, supported: OledStoreSchema.currentVersion)
    }
    self.secondsByOwner = try container.decode([String: Double].self, forKey: .secondsByOwner)
    self.totalSeconds = try container.decode(Double.self, forKey: .totalSeconds)
  }

  /// Internal, not private: replaces the memberwise init that adding
  /// `init(from:)` suppressed, and the tests reach it through `@testable`.
  init(secondsByOwner: [String: Double], totalSeconds: Double) {
    self.secondsByOwner = secondsByOwner
    self.totalSeconds = totalSeconds
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
