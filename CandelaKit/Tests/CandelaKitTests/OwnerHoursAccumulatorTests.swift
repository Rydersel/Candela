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

  /// The tuple label says `hours`; storage is seconds. This shipped briefly
  /// returning raw seconds under that label — a 3600× overstatement one
  /// `Text(...)` from the screen, and exactly the kind of number OC11 forbids
  /// the UI to imply. One full-screen hour must read as 1.0, not 3600.
  @Test func topOwnersReturnsHoursNotSeconds() {
    var acc = OwnerHoursAccumulator()
    let full = observation([String?](repeating: "Slack", count: PanelGrid.cellCount))
    acc.accumulate(full, elapsed: 3600)
    let top = acc.hours.topOwners(limit: 1)
    #expect(abs(top[0].hours - 1.0) < 0.0001)
    // …and the raw store is still seconds, so nobody "fixes" the wrong side.
    #expect(abs(acc.hours.secondsByOwner["Slack"]! - 3600) < 0.0001)
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

  /// A round trip passes under ANY rename, because it encodes and decodes with
  /// the same build. These strings are the on-disk schema (§4), and they used
  /// to be synthesised from the property names, so the rename this file's own
  /// doc comment invites (`secondsByOwner` holds seconds under a type called
  /// `OwnerHours`) would have silently stranded every stored blob.
  @Test func theEncodedKeyNamesAreTheOnDiskSchema() throws {
    var acc = OwnerHoursAccumulator()
    acc.accumulate(
      observation([String?](repeating: "Slack", count: PanelGrid.cellCount)),
      elapsed: 60)
    let data = try JSONEncoder().encode(acc.hours)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["secondsByOwner"] != nil)
    #expect(object["totalSeconds"] != nil)
    #expect(object["schemaVersion"] as? Int == OledStoreSchema.currentVersion)
  }

  @Test func decodingANewerSchemaIsRefusedRatherThanGuessedAt() throws {
    let data = try JSONEncoder().encode(OwnerHours.empty)
    var future = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    future["schemaVersion"] = OledStoreSchema.currentVersion + 1
    let futureData = try JSONSerialization.data(withJSONObject: future)
    #expect(
      throws: OledStoreDecodeFailure.unsupportedVersion(
        found: OledStoreSchema.currentVersion + 1,
        supported: OledStoreSchema.currentVersion)
    ) {
      try JSONDecoder().decode(OwnerHours.self, from: futureData)
    }
  }

  @Test func aStoreWithNoVersionFieldDecodesAsVersionOne() throws {
    var acc = OwnerHoursAccumulator()
    acc.accumulate(
      observation([String?](repeating: "Slack", count: PanelGrid.cellCount)),
      elapsed: 60)
    let data = try JSONEncoder().encode(acc.hours)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "schemaVersion")
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)

    #expect(try JSONDecoder().decode(OwnerHours.self, from: legacyData) == acc.hours)
  }
}
