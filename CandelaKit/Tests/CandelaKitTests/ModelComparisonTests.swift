import Foundation
import Testing

@testable import CandelaKit

@Suite("Modelled versus measured comparison")
struct ModelComparisonTests {

  private let start = Date(timeIntervalSince1970: 1000)

  private func grid(_ value: (Int) -> Double) -> [Double] {
    (0..<PanelGrid.cellCount).map(value)
  }

  /// A 0...1 ramp across the whole grid: every cell a distinct value, so ranks
  /// are a strict order and the hottest decile is unambiguous.
  private var rampGrid: [Double] {
    grid { Double($0) / Double(PanelGrid.cellCount - 1) }
  }

  private func booked(
    measured: [Double], modelled: [Double],
    pairs: Int = ExposureAccumulator.minimumSamplesForAnalysis
  ) -> ModelComparison {
    var comparison = ModelComparison.empty
    var now = start
    for _ in 0..<pairs {
      comparison.addPair(measured: measured, modelled: modelled, elapsed: 60, at: now)
      now = now.addingTimeInterval(60)
    }
    return comparison
  }

  // MARK: - Pair accumulation

  @Test func anEmptyComparisonHasTwoZeroedGrids() {
    #expect(ModelComparison.empty.measuredCells.count == PanelGrid.cellCount)
    #expect(ModelComparison.empty.modelledCells.count == PanelGrid.cellCount)
    #expect(ModelComparison.empty.measuredCells.allSatisfy { $0 == 0 })
    #expect(ModelComparison.empty.modelledCells.allSatisfy { $0 == 0 })
    #expect(ModelComparison.empty.pairCount == 0)
    #expect(ModelComparison.empty.firstPair == nil)
    #expect(ModelComparison.empty.lastPair == nil)
  }

  @Test func bothSidesAccumulateTimeWeightedAndRepeatedPairsAdd() {
    var comparison = ModelComparison.empty
    comparison.addPair(
      measured: grid { _ in 0.5 }, modelled: grid { _ in 0.25 }, elapsed: 60, at: start)
    #expect(abs(comparison.measuredCells[0] - 30) < 1e-9)
    #expect(abs(comparison.modelledCells[0] - 15) < 1e-9)

    comparison.addPair(
      measured: grid { _ in 0.5 }, modelled: grid { _ in 0.25 }, elapsed: 60,
      at: start.addingTimeInterval(60))
    #expect(abs(comparison.measuredCells[0] - 60) < 1e-9)
    #expect(abs(comparison.modelledCells[0] - 30) < 1e-9)
    #expect(comparison.pairCount == 2)
  }

  @Test func firstPairIsPinnedAndLastPairTracks() throws {
    var comparison = ModelComparison.empty
    comparison.addPair(
      measured: rampGrid, modelled: rampGrid, elapsed: 60, at: start)
    comparison.addPair(
      measured: rampGrid, modelled: rampGrid, elapsed: 60, at: start.addingTimeInterval(600))
    #expect(try #require(comparison.firstPair) == start)
    #expect(try #require(comparison.lastPair) == start.addingTimeInterval(600))
  }

  // MARK: - All or nothing

  /// The fairness rule of the gate: a half-booked pair permanently offsets one
  /// side against the other, and the store is persisted, so the offset never
  /// washes out. Every refusal below must leave the store byte-identical.
  @Test func aRefusedPairLeavesTheStoreExactlyAsItWas() {
    var comparison = booked(measured: rampGrid, modelled: rampGrid, pairs: 1)
    let good = comparison
    let later = start.addingTimeInterval(60)

    comparison.addPair(measured: [0.5, 0.5], modelled: rampGrid, elapsed: 60, at: later)
    #expect(comparison == good)

    comparison.addPair(measured: rampGrid, modelled: [0.5, 0.5], elapsed: 60, at: later)
    #expect(comparison == good)

    var withNaN = rampGrid
    withNaN[100] = .nan
    comparison.addPair(measured: withNaN, modelled: rampGrid, elapsed: 60, at: later)
    #expect(comparison == good)
    comparison.addPair(measured: rampGrid, modelled: withNaN, elapsed: 60, at: later)
    #expect(comparison == good)

    var negative = rampGrid
    negative[100] = -0.5
    comparison.addPair(measured: negative, modelled: rampGrid, elapsed: 60, at: later)
    #expect(comparison == good)
    comparison.addPair(measured: rampGrid, modelled: negative, elapsed: 60, at: later)
    #expect(comparison == good)
  }

  @Test func nonFiniteAndNonPositiveElapsedRefuseTheWholePair() {
    var comparison = ModelComparison.empty
    for elapsed in [0, -60, TimeInterval.nan, .infinity] as [TimeInterval] {
      comparison.addPair(
        measured: rampGrid, modelled: rampGrid, elapsed: elapsed, at: start)
    }
    #expect(comparison == .empty)
  }

  @Test func anOversizedGridIsRefusedAsWellAsAShortOne() {
    var comparison = ModelComparison.empty
    comparison.addPair(
      measured: rampGrid + [0.5], modelled: rampGrid, elapsed: 60, at: start)
    #expect(comparison == .empty)
  }

  // MARK: - Statistics

  @Test func statisticsAreNilBelowTheMinimumPairCount() {
    let short = booked(
      measured: rampGrid, modelled: rampGrid,
      pairs: ExposureAccumulator.minimumSamplesForAnalysis - 1)
    #expect(short.statistics() == nil)
    let enough = booked(measured: rampGrid, modelled: rampGrid)
    #expect(enough.statistics() != nil)
  }

  /// A flat map has no hottest region to agree or disagree about, so a
  /// correlation over it is arithmetic rather than a verdict.
  @Test func statisticsAreNilWhenEitherSideIsFlat() {
    let flatMeasured = booked(measured: grid { _ in 0.5 }, modelled: rampGrid)
    #expect(flatMeasured.statistics() == nil)
    let flatModelled = booked(measured: rampGrid, modelled: grid { _ in 0.5 })
    #expect(flatModelled.statistics() == nil)
    let bothZero = booked(measured: grid { _ in 0 }, modelled: grid { _ in 0 })
    #expect(bothZero.statistics() == nil)
  }

  @Test func identicalMapsCorrelatePerfectlyAndShareTheirHottestDecile() throws {
    let stats = try #require(booked(measured: rampGrid, modelled: rampGrid).statistics())
    #expect(stats.pearson == 1)
    #expect(stats.spearmanRank == 1)
    #expect(stats.hottestDecileOverlap == 1)
    #expect(abs(stats.measuredHottestMultiple - stats.modelledHottestMultiple) < 1e-12)
  }

  @Test func anInvertedMapCorrelatesNegativelyAndSharesNoHottestCell() throws {
    let inverted = grid { 1 - Double($0) / Double(PanelGrid.cellCount - 1) }
    let stats = try #require(booked(measured: rampGrid, modelled: inverted).statistics())
    // Value correlation gets a tolerance because `1 - i/239` and `i/239` round
    // separately; the rank correlation below is over exact half-integers.
    #expect(abs(stats.pearson + 1) < 1e-12)
    #expect(stats.spearmanRank == -1)
    #expect(stats.hottestDecileOverlap == 0)
  }

  /// A known permutation: adjacent cells swapped, so every cell's rank moves by
  /// exactly one and no ranks tie. Spearman is then the textbook
  /// 1 - 6*sum(d^2)/(n*(n^2-1)) with sum(d^2) = 240 and n = 240:
  /// 1 - 1440/(240*57599) = 1 - 6/57599 = 0.99989583...
  @Test func aKnownPermutationGivesTheHandComputedRankCorrelation() throws {
    let measured = rampGrid
    let swapped = grid { measured[$0 ^ 1] }
    let stats = try #require(booked(measured: measured, modelled: swapped).statistics())
    #expect(abs(stats.spearmanRank - (1 - 6.0 / 57599.0)) < 1e-12)
    #expect(stats.spearmanRank < 1)
  }

  /// Ties take the average of the ranks they span, not their index order. Here
  /// each side is two tied halves and the halves are swapped between the sides,
  /// which is a perfect inversion of the averaged ranks (-1). Breaking ties by
  /// index instead would rank the halves internally and answer about -0.49.
  @Test func tiedCellsShareAnAveragedRank() throws {
    let low = grid { $0 < PanelGrid.cellCount / 2 ? 0.25 : 0.75 }
    let high = grid { $0 < PanelGrid.cellCount / 2 ? 0.75 : 0.25 }
    let stats = try #require(booked(measured: low, modelled: high).statistics())
    #expect(stats.spearmanRank == -1)
    #expect(stats.pearson == -1)
  }

  /// Hottest multiple is the peak cell over that map's own mean, so it is scale
  /// free and each side is judged against itself.
  @Test func hottestMultiplesAreEachMapsPeakOverItsOwnMean() throws {
    let decile = PanelGrid.cellCount / 10
    // Mean 0.1, peak 1.0.
    let measured = grid { $0 < decile ? 1.0 : 0.0 }
    // Mean (24*0.5 + 216*0.25)/240 = 0.275, peak 0.5, so 20/11.
    let modelled = grid { $0 < decile ? 0.5 : 0.25 }
    let stats = try #require(booked(measured: measured, modelled: modelled).statistics())
    #expect(abs(stats.measuredHottestMultiple - 10) < 1e-9)
    #expect(abs(stats.modelledHottestMultiple - 20.0 / 11.0) < 1e-9)
    #expect(stats.hottestDecileOverlap == 1)
  }

  /// Half the hottest decile shared, which is the shape a partly-right model
  /// produces and the one the gate actually has to read.
  @Test func partialDecileAgreementIsReportedAsAFraction() throws {
    let decile = PanelGrid.cellCount / 10
    let measured = grid { $0 < decile ? 1.0 : Double($0) / 10_000 }
    let modelled = grid { $0 >= decile / 2 && $0 < decile + decile / 2 ? 1.0 : Double($0) / 10_000 }
    let stats = try #require(booked(measured: measured, modelled: modelled).statistics())
    #expect(abs(stats.hottestDecileOverlap - 0.5) < 1e-12)
  }

  // MARK: - Persistence

  @Test func roundTripsThroughCodable() throws {
    let comparison = booked(measured: rampGrid, modelled: grid { _ in 0.25 }, pairs: 3)
    let data = try JSONEncoder().encode(comparison)
    let decoded = try JSONDecoder().decode(ModelComparison.self, from: data)
    #expect(decoded == comparison)
  }

  /// The encoded key names are shipped on-disk schema: a property rename that
  /// changed them would quarantine every stored comparison.
  @Test func theEncodedKeyNamesAreTheOnDiskSchema() throws {
    let data = try JSONEncoder().encode(ModelComparison.empty)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["measuredCells"] != nil)
    #expect(object["modelledCells"] != nil)
    #expect(object["pairCount"] != nil)
    #expect(object["schemaVersion"] as? Int == OledStoreSchema.currentVersion)
  }

  @Test func aStoreWithNoVersionFieldDecodesAsVersionOne() throws {
    let comparison = booked(measured: rampGrid, modelled: rampGrid, pairs: 2)
    let data = try JSONEncoder().encode(comparison)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "schemaVersion")
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)
    #expect(try JSONDecoder().decode(ModelComparison.self, from: legacyData) == comparison)
  }

  /// The `ExposureMap` taxonomy, reused unchanged so the coordinator's
  /// quarantine path covers this store without a second branch.
  @Test func decodingANewerSchemaIsRefusedRatherThanGuessedAt() throws {
    let data = try JSONEncoder().encode(ModelComparison.empty)
    var future = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    future["schemaVersion"] = OledStoreSchema.currentVersion + 1
    let futureData = try JSONSerialization.data(withJSONObject: future)
    #expect(
      throws: OledStoreDecodeFailure.unsupportedVersion(
        found: OledStoreSchema.currentVersion + 1,
        supported: OledStoreSchema.currentVersion)
    ) {
      try JSONDecoder().decode(ModelComparison.self, from: futureData)
    }
  }

  @Test func decodingAWrongSizedMeasuredMapReportsAGridChange() throws {
    let data = try JSONEncoder().encode(ModelComparison.empty)
    var corrupt = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    corrupt["measuredCells"] = [0.5, 0.5, 0.5]
    let corruptData = try JSONSerialization.data(withJSONObject: corrupt)
    #expect(throws: OledStoreDecodeFailure.gridChanged(found: 3, expected: PanelGrid.cellCount)) {
      try JSONDecoder().decode(ModelComparison.self, from: corruptData)
    }
  }

  /// Both sides are length-checked. Validating only the measured array would let
  /// a short modelled array through and trap the first time the readout indexed
  /// it.
  @Test func decodingAWrongSizedModelledMapReportsAGridChange() throws {
    let data = try JSONEncoder().encode(ModelComparison.empty)
    var corrupt = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    corrupt["modelledCells"] = [0.5, 0.5, 0.5]
    let corruptData = try JSONSerialization.data(withJSONObject: corrupt)
    #expect(throws: OledStoreDecodeFailure.gridChanged(found: 3, expected: PanelGrid.cellCount)) {
      try JSONDecoder().decode(ModelComparison.self, from: corruptData)
    }
  }

  /// Junk is discardable and quarantined bytes are not, so malformed JSON must
  /// stay a plain `DecodingError`.
  @Test func malformedJSONThrowsAPlainDecodingError() {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ModelComparison.self, from: Data("not json at all".utf8))
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ModelComparison.self, from: Data(#"{"schemaVersion":1}"#.utf8))
    }
  }
}
