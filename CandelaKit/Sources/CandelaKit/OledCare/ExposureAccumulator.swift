import CoreGraphics
import Foundation

/// Cumulative light exposure per panel-native grid cell.
///
/// The unit is arbitrary (luminance times seconds) because it is only ever
/// compared against itself. It supports "3.2x this panel's average" and
/// nothing about lifespan.
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

  /// Cell value relative to the panel mean; 1.0 is average. Nil when the mean
  /// is zero, since returning 0 there would read as "cool".
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
    addEmission(panelGrid: panelGrid, elapsed: elapsed, at: now)
    sampleCount += 1
  }

  /// Light the app itself put on the panel. Moves the cells without touching
  /// `sampleCount`, which the analysis gate counts in 60 s captures.
  mutating func addEmission(panelGrid: [Double], elapsed: TimeInterval, at now: Date) {
    for cell in cells.indices {
      cells[cell] += panelGrid[cell] * elapsed
    }
    if firstSample == nil { firstSample = now }
    lastSample = now
  }

  /// Raw values spelled out rather than synthesised from the property names:
  /// these strings are shipped on-disk schema, and a synthesised key turns an
  /// ordinary rename into silent data loss.
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

  /// Two failure modes with opposite responses, hence two error types. A grid
  /// change or a newer schema is intact history and throws
  /// `OledStoreDecodeFailure`, so the caller keeps the bytes; malformed JSON
  /// throws `DecodingError` and may be discarded.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Absent means v1: those stores predate the version field, and rejecting
    // them would quarantine every existing user's history on upgrade.
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
  /// 30 minutes at the 60 s cadence. Named so "is this map worth believing yet"
  /// is one decision rather than arithmetic on an empty array.
  public static let minimumSamplesForAnalysis = 30

  public private(set) var map: ExposureMap

  public init(map: ExposureMap = .empty) {
    self.map = map
  }

  /// Accumulates one sample. `grid` is in DISPLAY orientation, and a sample is
  /// taken whole or refused whole; see `panelGrid` for what that protects.
  public mutating func accumulate(
    displayGrid grid: [Double], cols: Int, rows: Int,
    through transform: PanelSpaceTransform,
    elapsed: TimeInterval, at now: Date
  ) {
    guard let panel = panelGrid(
      from: grid, cols: cols, rows: rows, through: transform, elapsed: elapsed)
    else { return }
    map.add(panelGrid: panel, elapsed: elapsed, at: now)
  }

  /// Books light the app itself put on the panel (a checkup field). Same
  /// all-or-nothing rule as `accumulate`; leaves `sampleCount` alone.
  public mutating func bookEmission(
    displayGrid grid: [Double], cols: Int, rows: Int,
    through transform: PanelSpaceTransform,
    elapsed: TimeInterval, at now: Date
  ) {
    guard let panel = panelGrid(
      from: grid, cols: cols, rows: rows, through: transform, elapsed: elapsed)
    else { return }
    map.addEmission(panelGrid: panel, elapsed: elapsed, at: now)
  }

  /// Nil for anything the map must refuse whole: a partial grid biases a
  /// persisted map forever. `panelNativeGrid` answers a malformed grid with
  /// zeros rather than signalling, so the shape is checked first.
  private func panelGrid(
    from grid: [Double], cols: Int, rows: Int,
    through transform: PanelSpaceTransform, elapsed: TimeInterval
  ) -> [Double]? {
    guard elapsed.isFinite, elapsed > 0 else { return nil }
    guard cols > 0, rows > 0, grid.count == cols * rows else { return nil }
    guard grid.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }

    let panel = transform.panelNativeGrid(fromDisplayGrid: grid, cols: cols, rows: rows)
    guard panel.count == map.cells.count else { return nil }
    return panel
  }

  public mutating func reset() {
    map = .empty
  }

  public var hasEnoughSamplesForAnalysis: Bool {
    map.sampleCount >= Self.minimumSamplesForAnalysis
  }
}
