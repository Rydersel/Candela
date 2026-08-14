import Foundation

/// Two exposure maps accumulated over the SAME instants: one from measured
/// samples, one from the permission-free model.
///
/// EM2 is the whole point of the type. A pair books on both sides or on
/// neither, so a grant outage, a skipped capture or a decode failure stops both
/// maps together and the comparison can never read the permission's absence as
/// a modelling error. Same unit as `ExposureMap`: content luminance (0...1)
/// times seconds, with no brightness term on either side (EM13).
public struct ModelComparison: Equatable, Sendable, Codable {
  /// Both always `PanelGrid.cellCount` long, in panel-physical order (EM12).
  /// `.empty` is the only way in from outside and decoding rejects any other
  /// length, so the statistics below can index without checking.
  public private(set) var measuredCells: [Double]
  public private(set) var modelledCells: [Double]
  public private(set) var pairCount: Int
  public private(set) var firstPair: Date?
  public private(set) var lastPair: Date?

  public static let empty = ModelComparison(
    measuredCells: [Double](repeating: 0, count: PanelGrid.cellCount),
    modelledCells: [Double](repeating: 0, count: PanelGrid.cellCount),
    pairCount: 0, firstPair: nil, lastPair: nil)

  /// The top tenth of the grid: the region EM10 asks the two maps to agree on.
  private static let decileCellCount = PanelGrid.cellCount / 10

  /// Books one paired instant, or refuses the pair whole.
  ///
  /// Refusing whole rather than per-side is what keeps the comparison fair: a
  /// half-booked pair offsets one map against the other by exactly one sample,
  /// the store is persisted, and nothing later can tell the offset from a real
  /// disagreement.
  public mutating func addPair(
    measured: [Double], modelled: [Double], elapsed: TimeInterval, at now: Date
  ) {
    guard elapsed.isFinite, elapsed > 0 else { return }
    guard Self.isBookable(measured), Self.isBookable(modelled) else { return }

    for cell in measuredCells.indices {
      measuredCells[cell] += measured[cell] * elapsed
      modelledCells[cell] += modelled[cell] * elapsed
    }
    pairCount += 1
    if firstPair == nil { firstPair = now }
    lastPair = now
  }

  private static func isBookable(_ grid: [Double]) -> Bool {
    grid.count == PanelGrid.cellCount && grid.allSatisfy { $0.isFinite && $0 >= 0 }
  }

  /// The four figures of EM10, or nil while the answer would not be a verdict.
  ///
  /// Nil below the sample floor, and nil when either map is flat: a correlation
  /// against a map with no spread is arithmetic on noise, and the hottest decile
  /// of a flat map is an artefact of the tie-break rather than a hot region.
  public func statistics() -> ModelComparisonStats? {
    guard pairCount >= ExposureAccumulator.minimumSamplesForAnalysis else { return nil }
    guard let pearson = Self.pearson(measuredCells, modelledCells) else { return nil }
    guard
      let spearman = Self.pearson(
        Self.averageRanks(measuredCells), Self.averageRanks(modelledCells))
    else { return nil }
    guard
      let measuredMultiple = Self.hottestMultiple(measuredCells),
      let modelledMultiple = Self.hottestMultiple(modelledCells)
    else { return nil }

    let shared = Self.hottestDecile(measuredCells)
      .intersection(Self.hottestDecile(modelledCells))
    return ModelComparisonStats(
      pearson: pearson,
      spearmanRank: spearman,
      hottestDecileOverlap: Double(shared.count) / Double(Self.decileCellCount),
      measuredHottestMultiple: measuredMultiple,
      modelledHottestMultiple: modelledMultiple)
  }

  /// Nil when either side has no spread, which is the caller's "no verdict"
  /// signal rather than a divide-by-zero to guard downstream.
  private static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
    guard x.count == y.count, !x.isEmpty else { return nil }
    let n = Double(x.count)
    let meanX = x.reduce(0, +) / n
    let meanY = y.reduce(0, +) / n
    var covariance = 0.0
    var varianceX = 0.0
    var varianceY = 0.0
    for index in x.indices {
      let dx = x[index] - meanX
      let dy = y[index] - meanY
      covariance += dx * dy
      varianceX += dx * dx
      varianceY += dy * dy
    }
    guard varianceX > 0, varianceY > 0 else { return nil }
    // A perfect correlation can round a hair outside the range; clamping keeps
    // the readout from showing 1.0000000000000002.
    return min(1, max(-1, covariance / (varianceX * varianceY).squareRoot()))
  }

  /// Ranks 0 upward, with tied values sharing the average of the ranks they
  /// span. Index order breaks ties only for the sort's stability, never for the
  /// rank itself: two cells that accumulated identical exposure agree with the
  /// other map equally well, and letting their grid position decide would invent
  /// a correlation out of the numbering.
  private static func averageRanks(_ values: [Double]) -> [Double] {
    let ascending = values.indices.sorted { lhs, rhs in
      values[lhs] == values[rhs] ? lhs < rhs : values[lhs] < values[rhs]
    }
    var ranks = [Double](repeating: 0, count: values.count)
    var start = 0
    while start < ascending.count {
      var end = start
      while end + 1 < ascending.count, values[ascending[end + 1]] == values[ascending[start]] {
        end += 1
      }
      let average = Double(start + end) / 2
      for position in start...end { ranks[ascending[position]] = average }
      start = end + 1
    }
    return ranks
  }

  /// Lowest index wins a tie, so the same map answers the same way every render.
  private static func hottestDecile(_ values: [Double]) -> Set<Int> {
    let descending = values.indices.sorted { lhs, rhs in
      values[lhs] == values[rhs] ? lhs < rhs : values[lhs] > values[rhs]
    }
    return Set(descending.prefix(decileCellCount))
  }

  /// Peak over the map's own mean, so each side is judged against itself and the
  /// two multiples stay comparable regardless of the unit's arbitrary scale.
  private static func hottestMultiple(_ values: [Double]) -> Double? {
    guard let peak = values.max() else { return nil }
    let mean = values.reduce(0, +) / Double(values.count)
    guard mean > 0 else { return nil }
    return peak / mean
  }

  /// Spelled out rather than synthesised for the same reason as `ExposureMap`:
  /// these strings are shipped on-disk schema (§4), and a synthesised key turns
  /// an ordinary rename into silent data loss.
  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schemaVersion"
    case measuredCells = "measuredCells"
    case modelledCells = "modelledCells"
    case pairCount = "pairCount"
    case firstPair = "firstPair"
    case lastPair = "lastPair"
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(OledStoreSchema.currentVersion, forKey: .schemaVersion)
    try container.encode(measuredCells, forKey: .measuredCells)
    try container.encode(modelledCells, forKey: .modelledCells)
    try container.encode(pairCount, forKey: .pairCount)
    try container.encodeIfPresent(firstPair, forKey: .firstPair)
    try container.encodeIfPresent(lastPair, forKey: .lastPair)
  }

  /// The `ExposureMap` taxonomy exactly, so the coordinator's quarantine path
  /// applies to this store unchanged: `OledStoreDecodeFailure` means intact
  /// history this build cannot interpret (keep the bytes, write nothing), while
  /// a `DecodingError` means junk that may be discarded.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Absent means v1, the same forward-migration rule the exposure map follows.
    let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard version <= OledStoreSchema.currentVersion else {
      throw OledStoreDecodeFailure.unsupportedVersion(
        found: version, supported: OledStoreSchema.currentVersion)
    }
    let measured = try container.decode([Double].self, forKey: .measuredCells)
    guard measured.count == PanelGrid.cellCount else {
      throw OledStoreDecodeFailure.gridChanged(
        found: measured.count, expected: PanelGrid.cellCount)
    }
    // Both sides are checked: a short modelled array would trap the first time
    // the readout indexed it, exactly as a short measured one would.
    let modelled = try container.decode([Double].self, forKey: .modelledCells)
    guard modelled.count == PanelGrid.cellCount else {
      throw OledStoreDecodeFailure.gridChanged(
        found: modelled.count, expected: PanelGrid.cellCount)
    }
    self.measuredCells = measured
    self.modelledCells = modelled
    self.pairCount = try container.decode(Int.self, forKey: .pairCount)
    self.firstPair = try container.decodeIfPresent(Date.self, forKey: .firstPair)
    self.lastPair = try container.decodeIfPresent(Date.self, forKey: .lastPair)
  }

  private init(
    measuredCells: [Double], modelledCells: [Double], pairCount: Int,
    firstPair: Date?, lastPair: Date?
  ) {
    self.measuredCells = measuredCells
    self.modelledCells = modelledCells
    self.pairCount = pairCount
    self.firstPair = firstPair
    self.lastPair = lastPair
  }
}

/// The fixed statistics of EM10. Fixed in advance so the gate is judged on
/// numbers chosen before the result was known.
public struct ModelComparisonStats: Equatable, Sendable {
  /// Linear agreement over the 240 accumulated cell pairs.
  public var pearson: Double
  /// Order agreement, which survives a model that is right about where the heat
  /// is and wrong about how much.
  public var spearmanRank: Double
  /// Share of each map's 24 hottest cells that the other also calls hottest.
  public var hottestDecileOverlap: Double
  /// Peak cell as a multiple of that map's own mean.
  public var measuredHottestMultiple: Double
  public var modelledHottestMultiple: Double
}
