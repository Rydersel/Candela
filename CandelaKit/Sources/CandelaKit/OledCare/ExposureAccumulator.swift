import CoreGraphics
import Foundation

/// Cumulative light exposure per panel-native grid cell.
///
/// The unit is arbitrary — luminance (0...1) times seconds — because it is only
/// ever compared against itself. OC11: this supports "3.2× this panel's
/// average", which is measured, and nothing about lifespan, which is not.
public struct ExposureMap: Equatable, Sendable, Codable {
  /// Always `PanelGrid.cellCount` long: `.empty` is the only way in from
  /// outside the module and decoding rejects any other length.
  public private(set) var cells: [Double]
  public private(set) var sampleCount: Int
  public private(set) var firstSample: Date?
  public private(set) var lastSample: Date?

  public static let empty = ExposureMap(
    cells: [Double](repeating: 0, count: PanelGrid.cellCount),
    sampleCount: 0, firstSample: nil, lastSample: nil)

  public var mean: Double {
    guard !cells.isEmpty else { return 0 }
    return cells.reduce(0, +) / Double(cells.count)
  }

  /// Cell value relative to the panel mean. 1.0 == average. Nil when the mean
  /// is zero (nothing accumulated yet) — there is no such thing as "3.2×
  /// nothing", and returning 0 there would read as "cool".
  public func relativeExposure(atCell cell: Int) -> Double? {
    guard cells.indices.contains(cell) else { return nil }
    let mean = mean
    guard mean > 0 else { return nil }
    return cells[cell] / mean
  }

  /// First index of the maximum, so a tie answers the same way every render.
  public var hottestCell: Int? {
    var hottest: Int?
    var peak = 0.0
    for (index, value) in cells.enumerated() where value > peak {
      peak = value
      hottest = index
    }
    return hottest
  }

  /// Caller has already validated the grid; this only records it.
  mutating func add(panelGrid: [Double], elapsed: TimeInterval, at now: Date) {
    for cell in cells.indices {
      cells[cell] += panelGrid[cell] * elapsed
    }
    sampleCount += 1
    if firstSample == nil { firstSample = now }
    lastSample = now
  }

  /// Raw values are spelled out rather than synthesised from the property
  /// names: these strings are shipped on-disk schema (§4), and a synthesised
  /// key turns an ordinary rename into a silent data loss.
  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schemaVersion"
    case cells = "cells"
    case sampleCount = "sampleCount"
    case firstSample = "firstSample"
    case lastSample = "lastSample"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(OledStoreSchema.currentVersion, forKey: .schemaVersion)
    try container.encode(cells, forKey: .cells)
    try container.encode(sampleCount, forKey: .sampleCount)
    try container.encodeIfPresent(firstSample, forKey: .firstSample)
    try container.encodeIfPresent(lastSample, forKey: .lastSample)
  }

  /// Two failure modes with opposite correct responses, which is why they throw
  /// different error types. A short `cells` array would trap the first time the
  /// health view indexed it, so neither decodes into a mine; but a grid change
  /// or a newer schema is intact history and throws
  /// `OledStoreDecodeFailure` so the caller keeps the bytes, while malformed
  /// JSON throws `DecodingError` and may be discarded.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Absent means v1: stores written before the version field existed are
    // valid v1 data, and treating them as unreadable would quarantine every
    // existing user's history on upgrade.
    let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard version <= OledStoreSchema.currentVersion else {
      throw OledStoreDecodeFailure.unsupportedVersion(
        found: version, supported: OledStoreSchema.currentVersion)
    }
    let cells = try container.decode([Double].self, forKey: .cells)
    guard cells.count == PanelGrid.cellCount else {
      throw OledStoreDecodeFailure.gridChanged(
        found: cells.count, expected: PanelGrid.cellCount)
    }
    self.cells = cells
    self.sampleCount = try container.decode(Int.self, forKey: .sampleCount)
    self.firstSample = try container.decodeIfPresent(Date.self, forKey: .firstSample)
    self.lastSample = try container.decodeIfPresent(Date.self, forKey: .lastSample)
  }

  private init(cells: [Double], sampleCount: Int, firstSample: Date?, lastSample: Date?) {
    self.cells = cells
    self.sampleCount = sampleCount
    self.firstSample = firstSample
    self.lastSample = lastSample
  }
}

/// Folds periodic luminance samples into an `ExposureMap`.
public struct ExposureAccumulator: Sendable {
  /// 30 minutes at the 60 s cadence. Named because OC17 and OC19 both need "is
  /// this map worth believing yet" to be a decision, not arithmetic on an
  /// empty array.
  public static let minimumSamplesForAnalysis = 30

  public private(set) var map: ExposureMap

  public init(map: ExposureMap = .empty) {
    self.map = map
  }

  /// Accumulates one sample. `grid` is in DISPLAY orientation.
  ///
  /// A sample is taken whole or refused whole: a partially applied one biases
  /// the map permanently, and the map is persisted, so the bias never washes
  /// out. `PanelSpaceTransform.panelNativeGrid` answers a malformed grid with
  /// zeros rather than signalling, so the shape is checked here.
  public mutating func accumulate(
    displayGrid grid: [Double], cols: Int, rows: Int,
    through transform: PanelSpaceTransform,
    elapsed: TimeInterval, at now: Date
  ) {
    guard elapsed.isFinite, elapsed > 0 else { return }
    guard cols > 0, rows > 0, grid.count == cols * rows else { return }
    guard grid.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }

    let panel = transform.panelNativeGrid(fromDisplayGrid: grid, cols: cols, rows: rows)
    guard panel.count == map.cells.count else { return }
    map.add(panelGrid: panel, elapsed: elapsed, at: now)
  }

  public mutating func reset() {
    map = .empty
  }

  public var hasEnoughSamplesForAnalysis: Bool {
    map.sampleCount >= Self.minimumSamplesForAnalysis
  }
}
