import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

@Suite("Exposure accumulation")
struct ExposureAccumulatorTests {

  private let uprightTransform = PanelSpaceTransform(
    displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)

  private func hotTopRowGrid() -> [Double] {
    var grid = [Double](repeating: 0.1, count: PanelGrid.cellCount)
    for col in 0..<PanelGrid.cols { grid[col] = 1.0 }
    return grid
  }

  // MARK: - Accumulation

  /// The sanity check for the whole model: a menu-bar-hot sequence that does not
  /// produce a hottest top row means the analysis is wrong.
  @Test func menuBarHotSequenceProducesHottestTopRow() throws {
    var acc = ExposureAccumulator()
    var now = Date(timeIntervalSince1970: 0)
    for _ in 0..<60 {
      acc.accumulate(
        displayGrid: hotTopRowGrid(), cols: PanelGrid.cols, rows: PanelGrid.rows,
        through: uprightTransform, elapsed: 60, at: now)
      now = now.addingTimeInterval(60)
    }
    let hottest = try #require(acc.map.hottestCell)
    #expect(hottest < PanelGrid.cols)
  }

  @Test func exposureScalesWithElapsedTime() {
    var short = ExposureAccumulator()
    var long = ExposureAccumulator()
    let now = Date(timeIntervalSince1970: 0)
    let grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    short.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: now)
    long.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 120, at: now)
    #expect(long.map.cells[0] > short.map.cells[0])
  }

  @Test func repeatedSamplesAddRatherThanReplace() {
    var acc = ExposureAccumulator()
    let grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    let now = Date(timeIntervalSince1970: 0)
    acc.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: now)
    let afterOne = acc.map.cells[0]
    acc.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: now.addingTimeInterval(60))
    #expect(abs(acc.map.cells[0] - afterOne * 2) < 1e-9)
    #expect(acc.map.sampleCount == 2)
  }

  /// The rotation property, asserted against the SAME transform type
  /// PanelSpaceTransformTests pins. Accumulate upright, rotate, accumulate
  /// again, and the physical cell must keep growing rather than jumping.
  @Test func accumulationIsStableAcrossARotationChange() {
    var acc = ExposureAccumulator()
    let upright = PanelSpaceTransform(
      displaySize: CGSize(width: 3840, height: 2160), rotation: .standard)
    let rotated = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .twoSeventy)
    var uprightGrid = [Double](repeating: 0, count: PanelGrid.cellCount)
    uprightGrid[0] = 1.0  // panel-native top-left is hot

    acc.accumulate(
      displayGrid: uprightGrid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: upright, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    let afterUpright = acc.map.hottestCell

    // Same physical corner, now arriving through a rotated display. Under 270°
    // the panel's top-left arrives at the DISPLAY's bottom-left, and this grid
    // is 10 wide × 24 tall, so that is index 23*10.
    var rotatedGrid = [Double](repeating: 0, count: PanelGrid.cellCount)
    rotatedGrid[(PanelGrid.cols - 1) * PanelGrid.rows] = 1.0
    acc.accumulate(
      displayGrid: rotatedGrid, cols: PanelGrid.rows, rows: PanelGrid.cols,
      through: rotated, elapsed: 60, at: Date(timeIntervalSince1970: 60))

    #expect(afterUpright == 0)
    #expect(acc.map.hottestCell == afterUpright)
    // The load-bearing assertion. `hottestCell` above cannot fail: under the
    // inverted convention the second sample lands in the last cell, giving an exact
    // tie that `hottestCell` resolves to index 0 either way. Panel-physical space
    // means both samples land in the SAME cell and it keeps growing, 120 against 60.
    #expect(abs(acc.map.cells[0] - 120) < 1e-9)
    #expect(abs(acc.map.cells[PanelGrid.cellCount - 1]) < 1e-9)
  }

  // MARK: - Relative exposure

  @Test func relativeExposureIsNilOnAnEmptyMap() {
    let acc = ExposureAccumulator()
    #expect(acc.map.relativeExposure(atCell: 0) == nil)
    #expect(acc.map.hottestCell == nil)
  }

  @Test func relativeExposureReportsMultiplesOfTheMean() throws {
    var acc = ExposureAccumulator()
    var grid = [Double](repeating: 1.0, count: PanelGrid.cellCount)
    grid[0] = 2.0
    acc.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    let relative = try #require(acc.map.relativeExposure(atCell: 0))
    #expect(relative > 1.5 && relative < 2.5)
  }

  /// The health view indexes this grid, and the map can arrive from disk, so a cell
  /// outside it answers "no reading" rather than trapping.
  @Test func relativeExposureIsNilOutsideTheGrid() {
    var acc = ExposureAccumulator()
    acc.accumulate(
      displayGrid: hotTopRowGrid(), cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    #expect(acc.map.relativeExposure(atCell: -1) == nil)
    #expect(acc.map.relativeExposure(atCell: PanelGrid.cellCount) == nil)
  }

  // MARK: - Sample bookkeeping

  @Test func belowThresholdSampleCountIsNotAnalysable() {
    var acc = ExposureAccumulator()
    let grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    for _ in 0..<(ExposureAccumulator.minimumSamplesForAnalysis - 1) {
      acc.accumulate(
        displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
        through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    }
    #expect(acc.hasEnoughSamplesForAnalysis == false)
    acc.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    #expect(acc.hasEnoughSamplesForAnalysis == true)
  }

  /// 30 samples at the 60 s cadence is the half-hour OC17 and OC19 both spend
  /// before they will speak. Changing it changes when the UI stops hedging.
  @Test func theAnalysisThresholdIsThirtySamples() {
    #expect(ExposureAccumulator.minimumSamplesForAnalysis == 30)
  }

  @Test func firstSampleIsPinnedAndLastSampleTracks() throws {
    var acc = ExposureAccumulator()
    let grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    let start = Date(timeIntervalSince1970: 1000)
    acc.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: start)
    acc.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: start.addingTimeInterval(600))
    #expect(try #require(acc.map.firstSample) == start)
    #expect(try #require(acc.map.lastSample) == start.addingTimeInterval(600))
  }

  @Test func resetClearsEverything() {
    var acc = ExposureAccumulator()
    acc.accumulate(
      displayGrid: hotTopRowGrid(), cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    acc.reset()
    #expect(acc.map.sampleCount == 0)
    #expect(acc.map.cells.allSatisfy { $0 == 0 })
    #expect(acc.map.firstSample == nil)
    #expect(acc.map.lastSample == nil)
    #expect(acc.map == .empty)
  }

  // MARK: - Booked emission

  /// `sampleCount` counts 60 s readings and the OLED Care page renders it as
  /// "N of 30 readings", so a booking must not touch it.
  @Test func aBookedShowingMovesTheCellsAndNotTheSampleCount() throws {
    var acc = ExposureAccumulator()
    let grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    let start = Date(timeIntervalSince1970: 1000)
    acc.bookEmission(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 8, at: start)
    #expect(acc.map.cells.allSatisfy { $0 > 0 })
    #expect(acc.map.sampleCount == 0)
    #expect(acc.hasEnoughSamplesForAnalysis == false)
    #expect(try #require(acc.map.firstSample) == start)
    #expect(try #require(acc.map.lastSample) == start)
  }

  @Test func accumulatingStillCountsAReadingBesideABooking() {
    var acc = ExposureAccumulator()
    let grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    let start = Date(timeIntervalSince1970: 0)
    acc.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: start)
    #expect(acc.map.sampleCount == 1)
    acc.bookEmission(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 8, at: start.addingTimeInterval(60))
    #expect(acc.map.sampleCount == 1)
    acc.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: start.addingTimeInterval(120))
    #expect(acc.map.sampleCount == 2)
  }

  @Test func aBookingWithAMalformedGridIsRefusedWhole() {
    var acc = ExposureAccumulator()
    acc.bookEmission(
      displayGrid: [0.5, 0.5, 0.5], cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 8, at: Date(timeIntervalSince1970: 0))
    #expect(acc.map == .empty)
  }

  // MARK: - Malformed input

  @Test func mismatchedGridDimensionsDoNotTrap() {
    var acc = ExposureAccumulator()
    // Fewer values than cols*rows claims — a truncated capture.
    acc.accumulate(
      displayGrid: [0.5, 0.5, 0.5], cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    #expect(acc.map.sampleCount == 0)  // rejected, not half-applied
    #expect(acc.map.cells.allSatisfy { $0 == 0 })
    #expect(acc.map.firstSample == nil)
  }

  /// A half-applied sample biases the map permanently, so a good sample after a
  /// bad one must land on an untouched map rather than on a partial one.
  @Test func aRejectedSampleLeavesTheMapExactlyAsItWas() {
    var acc = ExposureAccumulator()
    let grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    acc.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    let good = acc.map
    acc.accumulate(
      displayGrid: [], cols: 0, rows: 0,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 60))
    #expect(acc.map == good)
  }

  /// The `PanelHoursTracker` lesson, one type over: a NaN or infinity poisons
  /// the totals irrecoverably, and this map is persisted, so every later
  /// comparison against it reads false forever.
  @Test func nonFiniteAndNonPositiveElapsedAreRejected() {
    var acc = ExposureAccumulator()
    let grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    let now = Date(timeIntervalSince1970: 0)
    for elapsed in [0, -60, TimeInterval.nan, .infinity] as [TimeInterval] {
      acc.accumulate(
        displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
        through: uprightTransform, elapsed: elapsed, at: now)
    }
    #expect(acc.map.sampleCount == 0)
    #expect(acc.map.cells.allSatisfy { $0 == 0 })
  }

  @Test func aGridCarryingANonFiniteValueIsRejectedWholesale() {
    var acc = ExposureAccumulator()
    var grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    grid[100] = .nan
    acc.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    #expect(acc.map.sampleCount == 0)
    #expect(acc.map.cells.allSatisfy { $0 == 0 })
  }

  @Test func aGridCarryingANegativeLuminanceIsRejectedWholesale() {
    var acc = ExposureAccumulator()
    var grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    grid[100] = -1.0
    acc.accumulate(
      displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    #expect(acc.map.sampleCount == 0)
  }

  // MARK: - Persistence

  @Test func roundTripsThroughCodable() throws {
    var acc = ExposureAccumulator()
    acc.accumulate(
      displayGrid: hotTopRowGrid(), cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    let data = try JSONEncoder().encode(acc.map)
    let decoded = try JSONDecoder().decode(ExposureMap.self, from: data)
    #expect(decoded == acc.map)
  }

  /// A truncated or hand-edited store must not decode into a map that traps when the
  /// health view indexes it. `OledStoreDecodeFailure`, not `DecodingError`: the
  /// coordinator discards the first and quarantines the second, so downgrading this
  /// restores the silent-overwrite path.
  @Test func decodingAWrongSizedMapReportsAGridChange() throws {
    let data = try JSONEncoder().encode(ExposureMap.empty)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    var corrupt = object
    corrupt["cells"] = [0.5, 0.5, 0.5]
    let corruptData = try JSONSerialization.data(withJSONObject: corrupt)
    #expect(throws: OledStoreDecodeFailure.gridChanged(found: 3, expected: PanelGrid.cellCount)) {
      try JSONDecoder().decode(ExposureMap.self, from: corruptData)
    }
  }

  /// Written by a build from the future. The bytes may be perfectly good
  /// history, so this must be distinguishable from junk rather than decoded
  /// on a best-effort basis.
  @Test func decodingANewerSchemaIsRefusedRatherThanGuessedAt() throws {
    let data = try JSONEncoder().encode(ExposureMap.empty)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any])
    var future = object
    future["schemaVersion"] = OledStoreSchema.currentVersion + 1
    let futureData = try JSONSerialization.data(withJSONObject: future)
    #expect(
      throws: OledStoreDecodeFailure.unsupportedVersion(
        found: OledStoreSchema.currentVersion + 1,
        supported: OledStoreSchema.currentVersion)
    ) {
      try JSONDecoder().decode(ExposureMap.self, from: futureData)
    }
  }

  /// Stores written before the version field existed are valid v1 data.
  /// Quarantining them would strand every existing user's history on upgrade,
  /// which is the failure this whole mechanism exists to prevent.
  @Test func aStoreWithNoVersionFieldDecodesAsVersionOne() throws {
    var seed = ExposureAccumulator()
    seed.accumulate(
      displayGrid: hotTopRowGrid(), cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    let data = try JSONEncoder().encode(seed.map)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "schemaVersion")
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)

    let decoded = try JSONDecoder().decode(ExposureMap.self, from: legacyData)
    #expect(decoded == seed.map)
  }

  /// The encoded key names are the on-disk schema (§4). Pinned as literals so a
  /// property rename cannot quietly change the wire format, which under the
  /// quarantine rules would strand every stored map.
  @Test func theEncodedKeyNamesAreTheOnDiskSchema() throws {
    let data = try JSONEncoder().encode(ExposureMap.empty)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["cells"] != nil)
    #expect(object["sampleCount"] != nil)
    #expect(object["schemaVersion"] as? Int == OledStoreSchema.currentVersion)
  }

  @Test func anEmptyMapHasTwoHundredAndFortyZeroedCells() {
    #expect(ExposureMap.empty.cells.count == PanelGrid.cellCount)
    #expect(ExposureMap.empty.cells.allSatisfy { $0 == 0 })
    #expect(ExposureMap.empty.sampleCount == 0)
  }

  @Test func anAccumulatorCanResumeFromAStoredMap() {
    var seed = ExposureAccumulator()
    seed.accumulate(
      displayGrid: hotTopRowGrid(), cols: PanelGrid.cols, rows: PanelGrid.rows,
      through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    let resumed = ExposureAccumulator(map: seed.map)
    #expect(resumed.map == seed.map)
  }
}
