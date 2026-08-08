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

  /// `OwnerHours`'s memberwise init is internal and `@testable` reaches it.
  /// Used where the test needs an exact per-owner second count; the tests that
  /// pin the *unit* go through `OwnerHoursAccumulator` instead, so the
  /// cell-quantized path is exercised too.
  private func ownerHours(_ seconds: [String: Double]) -> OwnerHours {
    OwnerHours(secondsByOwner: seconds, totalSeconds: seconds.values.reduce(0, +))
  }

  private func observation(_ owners: [String?]) -> WindowObservation {
    WindowObservation(
      dominantOwnerByCell: owners,
      stationarySecondsByWindowID: [:],
      stationaryByCell: [Bool](repeating: false, count: PanelGrid.cellCount),
      fullScreenOwner: nil)
  }

  // MARK: - Confidence

  @Test func insufficientDataIsReportedAsSuch() {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: .empty, telemetryEnabled: true, observationEnabled: true)
    #expect(summary.confidence == .insufficient)
    #expect(summary.hottestRelative == nil)
  }

  @Test func telemetryOffIsEstimatedNotMeasured() {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: .empty, telemetryEnabled: false, observationEnabled: true)
    #expect(summary.confidence == .estimated)
  }

  @Test func exactlyTheThresholdSampleCountIsMeasured() {
    let grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    let map = measuredMap(grid, samples: ExposureAccumulator.minimumSamplesForAnalysis)
    let summary = PanelHealthSummary.make(
      map: map, observation: nil, ownerHours: .empty, telemetryEnabled: true,
      observationEnabled: true)
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
      map: map, observation: nil, ownerHours: .empty, telemetryEnabled: false,
      observationEnabled: true)
    #expect(summary.confidence == .estimated)
    #expect(summary.hottestRelative == nil)
  }

  @Test func belowThresholdSampleCountHidesRelativeExposureEvenWithRealData() {
    var grid = [Double](repeating: 1.0, count: PanelGrid.cellCount)
    grid[0] = 4.0
    let map = measuredMap(grid, samples: ExposureAccumulator.minimumSamplesForAnalysis - 1)
    let summary = PanelHealthSummary.make(
      map: map, observation: nil, ownerHours: .empty, telemetryEnabled: true,
      observationEnabled: true)
    #expect(summary.confidence == .insufficient)
    #expect(summary.hottestRelative == nil)
  }

  // MARK: - Relative exposure

  @Test func hottestRelativeIsReportedAsAMultipleOfTheMean() throws {
    var grid = [Double](repeating: 1.0, count: PanelGrid.cellCount)
    grid[0] = 4.0
    let map = measuredMap(grid)
    let summary = PanelHealthSummary.make(
      map: map, observation: nil, ownerHours: .empty, telemetryEnabled: true,
      observationEnabled: true)
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
      map: map, observation: observation, ownerHours: .empty, telemetryEnabled: true,
      observationEnabled: true)
    #expect(summary.hottestOwner == "Xcode")
  }

  @Test func hottestOwnerIsNilWithoutAnObservation() {
    var grid = [Double](repeating: 1.0, count: PanelGrid.cellCount)
    grid[0] = 4.0
    let map = measuredMap(grid)
    let summary = PanelHealthSummary.make(
      map: map, observation: nil, ownerHours: .empty, telemetryEnabled: true,
      observationEnabled: true)
    #expect(summary.hottestOwner == nil)
  }

  /// Replaces `topOwnersByHoursIsEmptyUntilThereIsAMeasuredPerOwnerTimeSeries`,
  /// which pinned the always-empty stub that shipped before
  /// `OwnerHoursAccumulator` existed. Empty is still the answer with no
  /// measured series — it just is no longer the only answer.
  @Test func topOwnersByHoursIsEmptyWithNoMeasuredSeries() {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: .empty, telemetryEnabled: true, observationEnabled: true)
    #expect(summary.topOwnersByHours.isEmpty)
  }

  /// The unit contract, and the one number in this type a user can misread:
  /// `OwnerHours` counts panel-SECONDS attributable to an app, and this field
  /// is hours. A full-panel owner for one hour of panel time books 1.0.
  @Test func aFullPanelOwnerBooksOnePanelHourPerHour() throws {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: ownerHours(["Xcode": 3600]),
      telemetryEnabled: true, observationEnabled: true)
    let top = try #require(summary.topOwnersByHours.first)
    #expect(top.owner == "Xcode")
    #expect(abs(top.hours - 1.0) < 0.0001)
  }

  /// Panel-time, not wall-clock: an app on a quarter of the panel through the
  /// same hour books a quarter of it (OC11 — the label must not overstate).
  @Test func aQuarterPanelOwnerBooksAQuarterOfThatHour() throws {
    var owners = [String?](repeating: nil, count: PanelGrid.cellCount)
    for index in 0..<(PanelGrid.cellCount / 4) { owners[index] = "Notes" }
    var accumulator = OwnerHoursAccumulator()
    accumulator.accumulate(observation(owners), elapsed: 3600)
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: accumulator.hours,
      telemetryEnabled: true, observationEnabled: true)
    let top = try #require(summary.topOwnersByHours.first)
    #expect(top.owner == "Notes")
    #expect(abs(top.hours - 0.25) < 0.0001)
  }

  @Test func topOwnersByHoursIsDescendingAndClampedToTheLimit() {
    var seconds: [String: Double] = [:]
    for index in 0..<(PanelHealthSummary.topOwnerLimit + 3) {
      seconds["App\(index)"] = Double(index + 1) * 3600
    }
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: ownerHours(seconds),
      telemetryEnabled: true, observationEnabled: true)
    let hours = summary.topOwnersByHours.map(\.hours)
    #expect(summary.topOwnersByHours.count == PanelHealthSummary.topOwnerLimit)
    #expect(hours == hours.sorted(by: >))
    #expect(summary.topOwnersByHours.first?.owner == "App7")
  }

  /// Window observation is a separate pref from luminance telemetry and needs
  /// no permission, so per-app hours survive `.estimated` — gating them on
  /// exposure confidence would blank the one attribution the degraded mode
  /// still measures honestly.
  @Test func topOwnersByHoursSurvivesTelemetryBeingOff() {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: ownerHours(["Slack": 7200]),
      telemetryEnabled: false, observationEnabled: true)
    #expect(summary.confidence == .estimated)
    #expect(summary.topOwnersByHours.map(\.owner) == ["Slack"])
  }

  // MARK: - Cells

  @Test func normalizedCellsSpanZeroToOne() {
    var grid = [Double](repeating: 0.2, count: PanelGrid.cellCount)
    grid[5] = 1.0
    let map = measuredMap(grid)
    let summary = PanelHealthSummary.make(
      map: map, observation: nil, ownerHours: .empty, telemetryEnabled: true,
      observationEnabled: true)
    #expect(summary.cells.count == PanelGrid.cellCount)
    #expect(summary.cells.allSatisfy { $0 >= 0 && $0 <= 1 })
    #expect(summary.cells[5] == 1.0)
  }

  @Test func cellsAreAllZeroWithNoData() {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: .empty, telemetryEnabled: true, observationEnabled: true)
    #expect(summary.cells.count == PanelGrid.cellCount)
    #expect(summary.cells.allSatisfy { $0 == 0 })
  }

  // MARK: - Observation gating

  /// The coordinator keeps the last observation for the life of the process
  /// after the pref goes off, so a summary that read it anyway would let the
  /// view keep naming an app the user stopped us watching. The snapshot here is
  /// deliberately fresh and complete: the gate is the pref, not staleness,
  /// because staleness is exactly what cannot be detected from the snapshot.
  @Test func hottestOwnerIsWithheldWhenObservationIsOff() {
    var grid = [Double](repeating: 1.0, count: PanelGrid.cellCount)
    grid[0] = 4.0
    let map = measuredMap(grid)
    var owners = [String?](repeating: nil, count: PanelGrid.cellCount)
    owners[0] = "Slack"
    let observation = WindowObservation(
      dominantOwnerByCell: owners,
      stationarySecondsByWindowID: [:],
      stationaryByCell: [Bool](repeating: false, count: PanelGrid.cellCount),
      fullScreenOwner: nil)

    let watching = PanelHealthSummary.make(
      map: map, observation: observation, ownerHours: .empty,
      telemetryEnabled: true, observationEnabled: true)
    #expect(watching.hottestOwner == "Slack")

    let stopped = PanelHealthSummary.make(
      map: map, observation: observation, ownerHours: .empty,
      telemetryEnabled: true, observationEnabled: false)
    #expect(stopped.hottestOwner == nil)
    // The exposure half is unaffected: luminance telemetry is a separate pref.
    #expect(stopped.confidence == .measured)
    #expect(stopped.hottestRelative != nil)
  }

  @Test func observationEnabledIsCarriedThroughForCopyToBranchOn() {
    let on = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: .empty,
      telemetryEnabled: false, observationEnabled: true)
    let off = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: .empty,
      telemetryEnabled: false, observationEnabled: false)
    #expect(on.observationEnabled)
    #expect(!off.observationEnabled)
    #expect(on != off)
  }

  /// `sampleCount` used to be a parameter beside `map`, so a caller could pass
  /// one that disagreed and get `.measured` over an empty map. It is now read
  /// off the map and there is no second source to disagree with.
  @Test func confidenceIsReadFromTheMapNotFromABesideParameter() {
    let summary = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: .empty,
      telemetryEnabled: true, observationEnabled: true)
    #expect(summary.confidence == .insufficient)
  }

  // MARK: - Equatable

  @Test func summariesWithIdenticalInputsAreEqual() {
    let a = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: .empty, telemetryEnabled: true, observationEnabled: true)
    let b = PanelHealthSummary.make(
      map: .empty, observation: nil, ownerHours: .empty, telemetryEnabled: true, observationEnabled: true)
    #expect(a == b)
  }
}
