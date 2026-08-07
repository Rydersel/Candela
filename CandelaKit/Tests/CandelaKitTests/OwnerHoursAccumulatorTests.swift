import Foundation
import Testing

@testable import CandelaKit

@Suite("Owner hours accumulation")
struct OwnerHoursAccumulatorTests {

  private func observation(_ owners: [String?]) -> WindowObservation {
    WindowObservation(
      dominantOwnerByCell: owners,
      stationarySecondsByWindowID: [:],
      stationaryByCell: [Bool](repeating: false, count: PanelGrid.cellCount),
      fullScreenOwner: nil)
  }

  @Test func aFullScreenOwnerBooksTheWholeElapsedTime() {
    var acc = OwnerHoursAccumulator()
    acc.accumulate(
      observation([String?](repeating: "Slack", count: PanelGrid.cellCount)),
      elapsed: 60)
    #expect(abs(acc.hours.secondsByOwner["Slack"]! - 60) < 0.001)
  }

  @Test func aQuarterPanelOwnerBooksAQuarterOfIt() {
    var acc = OwnerHoursAccumulator()
    var owners = [String?](repeating: nil, count: PanelGrid.cellCount)
    for i in 0..<(PanelGrid.cellCount / 4) { owners[i] = "Notes" }
    acc.accumulate(observation(owners), elapsed: 60)
    #expect(abs(acc.hours.secondsByOwner["Notes"]! - 15) < 0.001)
  }

  @Test func uncoveredCellsBookNothingToAnyone() {
    var acc = OwnerHoursAccumulator()
    acc.accumulate(
      observation([String?](repeating: nil, count: PanelGrid.cellCount)),
      elapsed: 60)
    #expect(acc.hours.secondsByOwner.isEmpty)
    #expect(acc.hours.totalSeconds == 0)
  }

  @Test func accumulationIsCumulativeAcrossObservations() {
    var acc = OwnerHoursAccumulator()
    let full = observation([String?](repeating: "Xcode", count: PanelGrid.cellCount))
    acc.accumulate(full, elapsed: 60)
    acc.accumulate(full, elapsed: 60)
    #expect(abs(acc.hours.secondsByOwner["Xcode"]! - 120) < 0.001)
  }

  /// Same all-or-nothing contract as ExposureAccumulator: a bad elapsed must
  /// not half-apply, because this is persisted and one NaN poisons it forever.
  @Test func aNonFiniteOrNonPositiveElapsedIsRejectedWholesale() {
    var acc = OwnerHoursAccumulator()
    let full = observation([String?](repeating: "Slack", count: PanelGrid.cellCount))
    acc.accumulate(full, elapsed: 60)
    let before = acc.hours
    acc.accumulate(full, elapsed: .nan)
    acc.accumulate(full, elapsed: 0)
    acc.accumulate(full, elapsed: -5)
    #expect(acc.hours == before)
  }

  @Test func aWrongSizedObservationIsRejectedWholesale() {
    var acc = OwnerHoursAccumulator()
    let short = WindowObservation(
      dominantOwnerByCell: ["Slack"],
      stationarySecondsByWindowID: [:],
      stationaryByCell: [false],
      fullScreenOwner: nil)
    acc.accumulate(short, elapsed: 60)
    #expect(acc.hours == .empty)
  }

  @Test func topOwnersIsDescendingAndTieBrokenByName() {
    var acc = OwnerHoursAccumulator()
    var owners = [String?](repeating: nil, count: PanelGrid.cellCount)
    for i in 0..<120 { owners[i] = "Zed" }
    for i in 120..<180 { owners[i] = "Alpha" }
    for i in 180..<240 { owners[i] = "Beta" }
    acc.accumulate(observation(owners), elapsed: 60)
    let top = acc.hours.topOwners(limit: 3)
    #expect(top.map(\.owner) == ["Zed", "Alpha", "Beta"])
  }

  @Test func topOwnersClampsToTheAvailableCount() {
    var acc = OwnerHoursAccumulator()
    acc.accumulate(
      observation([String?](repeating: "Slack", count: PanelGrid.cellCount)),
      elapsed: 60)
    #expect(acc.hours.topOwners(limit: 10).count == 1)
  }

  @Test func resetClearsEverything() {
    var acc = OwnerHoursAccumulator()
    acc.accumulate(
      observation([String?](repeating: "Slack", count: PanelGrid.cellCount)),
      elapsed: 60)
    acc.reset()
    #expect(acc.hours == .empty)
  }

  @Test func roundTripsThroughCodable() throws {
    var acc = OwnerHoursAccumulator()
    acc.accumulate(
      observation([String?](repeating: "Slack", count: PanelGrid.cellCount)),
      elapsed: 60)
    let data = try JSONEncoder().encode(acc.hours)
    #expect(try JSONDecoder().decode(OwnerHours.self, from: data) == acc.hours)
  }
}
