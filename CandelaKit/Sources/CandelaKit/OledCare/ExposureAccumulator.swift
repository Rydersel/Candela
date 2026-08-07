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

  private enum CodingKeys: String, CodingKey {
    case cells, sampleCount, firstSample, lastSample
  }

  /// A short `cells` array would trap the first time the health view indexed
  /// it, so a corrupt store fails to decode rather than decoding into a mine.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let cells = try container.decode([Double].self, forKey: .cells)
    guard cells.count == PanelGrid.cellCount else {
      throw DecodingError.dataCorruptedError(
        forKey: .cells, in: container,
        debugDescription: "expected \(PanelGrid.cellCount) cells, found \(cells.count)")
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
