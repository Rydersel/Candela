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
  /// Time from owners past `storedOwnerLimit`, kept out of `secondsByOwner` so
  /// no reader can render the fold as an app. Older decoders skip the key, so
  /// the schema version does not move for it.
  public private(set) var foldedSeconds: Double

  public static let empty = OwnerHours(secondsByOwner: [:], totalSeconds: 0)

  /// Owners surviving an encode. The store never forgets an app, so without a
  /// cap the prefs blob grows without bound.
  static let storedOwnerLimit = 50

  /// Where older builds put the fold, inside `secondsByOwner`, where readers drew
  /// it as the heaviest app. Migrated out on decode, never written again. The "/"
  /// makes it impossible as a real process name.
  static let legacyFoldedOwnerKey = "other/apps"

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

  /// Idempotent: a store at or under the limit folds nothing, so a rewrite of a
  /// rewrite does not eat one more owner.
  private static func capped(_ seconds: [String: Double]) -> (kept: [String: Double], folded: Double) {
    guard seconds.count > storedOwnerLimit else { return (seconds, 0) }
    let ranked = seconds.sorted { lhs, rhs in
      lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
    }
    var kept = [String: Double](minimumCapacity: storedOwnerLimit)
    var folded = 0.0
    for (index, entry) in ranked.enumerated() {
      if index < storedOwnerLimit {
        kept[entry.key] = entry.value
      } else {
        folded += entry.value
      }
    }
    return (kept, folded)
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
    case foldedSeconds = "foldedSeconds"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    // Not bumped for `foldedSeconds`: the version gates older decoders out, and
    // they only lose the folded total by skipping the key.
    try container.encode(OledStoreSchema.currentVersion, forKey: .schemaVersion)
    let capped = Self.capped(secondsByOwner)
    try container.encode(capped.kept, forKey: .secondsByOwner)
    try container.encode(totalSeconds, forKey: .totalSeconds)
    try container.encode(foldedSeconds + capped.folded, forKey: .foldedSeconds)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard version <= OledStoreSchema.currentVersion else {
      throw OledStoreDecodeFailure.unsupportedVersion(
        found: version, supported: OledStoreSchema.currentVersion)
    }
    var stored = try container.decode([String: Double].self, forKey: .secondsByOwner)
    // Absent until this build rewrites the store; before the field existed the
    // fold sat under the legacy key.
    let carried = try container.decodeIfPresent(Double.self, forKey: .foldedSeconds) ?? 0
    let legacy = stored.removeValue(forKey: Self.legacyFoldedOwnerKey) ?? 0
    self.secondsByOwner = stored
    self.totalSeconds = try container.decode(Double.self, forKey: .totalSeconds)
    self.foldedSeconds = carried + legacy
  }

  /// Internal, not private: replaces the memberwise init that adding
  /// `init(from:)` suppressed, and the tests reach it through `@testable`.
  init(secondsByOwner: [String: Double], totalSeconds: Double, foldedSeconds: Double = 0) {
    self.secondsByOwner = secondsByOwner
    self.totalSeconds = totalSeconds
    self.foldedSeconds = foldedSeconds
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
