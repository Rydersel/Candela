import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

@Suite("Panel health summary")
struct PanelHealthSummaryTests {

  private let uprightTransform = PanelSpaceTransform(
    displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)

  /// Accumulates `samples` copies of `grid` through the pass-through 24×10
  /// upright transform. `ExposureMap` has no public memberwise init, so this
  /// is the only door in — the same one every one of Task 3's tests uses.
  private func measuredMap(
    _ grid: [Double], samples: Int = ExposureAccumulator.minimumSamplesForAnalysis
  ) -> ExposureMap {
    var acc = ExposureAccumulator()
    for _ in 0..<samples {
      acc.accumulate(
        displayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows,
        through: uprightTransform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
    }
    return acc.map
  }

  // MARK: - Confidence

  @Test func insufficientDataIsReportedAsSuch() {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, telemetryEnabled: true, sampleCount: 3)
    #expect(summary.confidence == .insufficient)
    #expect(summary.hottestRelative == nil)
  }

  @Test func telemetryOffIsEstimatedNotMeasured() {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, telemetryEnabled: false, sampleCount: 0)
    #expect(summary.confidence == .estimated)
  }

  @Test func exactlyTheThresholdSampleCountIsMeasured() {
    let grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    let map = measuredMap(grid, samples: ExposureAccumulator.minimumSamplesForAnalysis)
    let summary = PanelHealthSummary.make(
      map: map, observation: nil, telemetryEnabled: true, sampleCount: map.sampleCount)
    #expect(summary.confidence == .measured)
  }

  /// A leftover map from when telemetry was on must not read as `.measured`
  /// once telemetry is off — `.estimated` means window geometry only, with no
  /// exposure number to speak from, whatever the map happens to be carrying.
  @Test func aStaleMapIsNotShownAsMeasuredOnceTelemetryIsOff() {
    var grid = [Double](repeating: 1.0, count: PanelGrid.cellCount)
    grid[0] = 4.0
    let map = measuredMap(grid)
    let summary = PanelHealthSummary.make(
      map: map, observation: nil, telemetryEnabled: false, sampleCount: map.sampleCount)
    #expect(summary.confidence == .estimated)
    #expect(summary.hottestRelative == nil)
  }

  @Test func belowThresholdSampleCountHidesRelativeExposureEvenWithRealData() {
    var grid = [Double](repeating: 1.0, count: PanelGrid.cellCount)
    grid[0] = 4.0
    let map = measuredMap(grid, samples: ExposureAccumulator.minimumSamplesForAnalysis - 1)
    let summary = PanelHealthSummary.make(
      map: map, observation: nil, telemetryEnabled: true, sampleCount: map.sampleCount)
    #expect(summary.confidence == .insufficient)
    #expect(summary.hottestRelative == nil)
  }

  // MARK: - Relative exposure

  @Test func hottestRelativeIsReportedAsAMultipleOfTheMean() throws {
    var grid = [Double](repeating: 1.0, count: PanelGrid.cellCount)
    grid[0] = 4.0
    let map = measuredMap(grid)
    let summary = PanelHealthSummary.make(
      map: map, observation: nil, telemetryEnabled: true, sampleCount: map.sampleCount)
    #expect(summary.confidence == .measured)
    let relative = try #require(summary.hottestRelative)
    #expect(relative > 3.0 && relative < 4.5)
  }

  // MARK: - Attribution

  @Test func hottestOwnerIsReadFromTheObservationAtTheHottestCell() throws {
    var grid = [Double](repeating: 1.0, count: PanelGrid.cellCount)
    grid[0] = 4.0
    let map = measuredMap(grid)
    var owners = [String?](repeating: nil, count: PanelGrid.cellCount)
    owners[0] = "Xcode"
    let observation = WindowObservation(
      dominantOwnerByCell: owners,
      stationarySecondsByWindowID: [:],
      stationaryByCell: [Bool](repeating: false, count: PanelGrid.cellCount),
      fullScreenOwner: nil)
    let summary = PanelHealthSummary.make(
      map: map, observation: observation, telemetryEnabled: true, sampleCount: map.sampleCount)
    #expect(summary.hottestOwner == "Xcode")
  }

  @Test func hottestOwnerIsNilWithoutAnObservation() {
    var grid = [Double](repeating: 1.0, count: PanelGrid.cellCount)
    grid[0] = 4.0
    let map = measuredMap(grid)
    let summary = PanelHealthSummary.make(
      map: map, observation: nil, telemetryEnabled: true, sampleCount: map.sampleCount)
    #expect(summary.hottestOwner == nil)
  }

  /// No per-owner time series exists yet anywhere in the codebase — neither
  /// `ExposureMap` (per-cell) nor a single `WindowObservation` (one instant)
  /// carries measured per-app hours. Pinned empty rather than left to invent
  /// a number, per OC11.
  @Test func topOwnersByHoursIsEmptyUntilThereIsAMeasuredPerOwnerTimeSeries() {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, telemetryEnabled: true, sampleCount: 0)
    #expect(summary.topOwnersByHours.isEmpty)
  }

  // MARK: - Cells

  @Test func normalizedCellsSpanZeroToOne() {
    var grid = [Double](repeating: 0.2, count: PanelGrid.cellCount)
    grid[5] = 1.0
    let map = measuredMap(grid)
    let summary = PanelHealthSummary.make(
      map: map, observation: nil, telemetryEnabled: true, sampleCount: map.sampleCount)
    #expect(summary.cells.count == PanelGrid.cellCount)
    #expect(summary.cells.allSatisfy { $0 >= 0 && $0 <= 1 })
    #expect(summary.cells[5] == 1.0)
  }

  @Test func cellsAreAllZeroWithNoData() {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, telemetryEnabled: true, sampleCount: 0)
    #expect(summary.cells.count == PanelGrid.cellCount)
    #expect(summary.cells.allSatisfy { $0 == 0 })
  }

  // MARK: - Equatable

  @Test func summariesWithIdenticalInputsAreEqual() {
    let a = PanelHealthSummary.make(
      map: .empty, observation: nil, telemetryEnabled: true, sampleCount: 0)
    let b = PanelHealthSummary.make(
      map: .empty, observation: nil, telemetryEnabled: true, sampleCount: 0)
    #expect(a == b)
  }
}
