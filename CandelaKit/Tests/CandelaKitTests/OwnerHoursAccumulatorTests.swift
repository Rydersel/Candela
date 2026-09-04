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
  /// returning raw seconds under that label, a 3600x overstatement one `Text(...)`
  /// from the screen and the kind of number the label-accuracy rule forbids the UI to imply. One
  /// full-screen hour reads as 1.0, not 3600.
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

  /// A round trip passes under ANY rename, since it encodes and decodes with the
  /// same build. These strings are the on-disk schema, and they used to be
  /// synthesised from the property names, so renaming `secondsByOwner` would have
  /// silently stranded every stored blob.
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

  // MARK: - The encode-time owner cap

  private func sixtyOwners() -> OwnerHours {
    var seconds: [String: Double] = [:]
    for index in 0..<60 { seconds[String(format: "App%02d", index)] = Double(index + 1) }
    return OwnerHours(secondsByOwner: seconds, totalSeconds: seconds.values.reduce(0, +))
  }

  /// Without a cap the prefs blob grows for the life of the machine. Kept plus
  /// folded must still sum to the total.
  @Test func encodingKeepsTheHeaviestOwnersAndFoldsTheRest() throws {
    let hours = sixtyOwners()
    let decoded = try JSONDecoder().decode(OwnerHours.self, from: JSONEncoder().encode(hours))

    // Exactly the limit: the fold is a field of its own, not an extra owner.
    #expect(decoded.secondsByOwner.count == OwnerHours.storedOwnerLimit)
    // App00...App09 carry 1 through 10 seconds, so they are the ten dropped.
    let dropped = (1...10).reduce(0.0) { $0 + Double($1) }
    #expect(abs(decoded.foldedSeconds - dropped) < 0.0001)
    #expect(decoded.secondsByOwner["App59"] == 60)
    #expect(decoded.totalSeconds == hours.totalSeconds)
    #expect(
      abs(decoded.secondsByOwner.values.reduce(0, +) + decoded.foldedSeconds - hours.totalSeconds)
        < 0.0001
    )
  }

  /// Older stores carry the fold under an owner key, which drew as the heaviest
  /// app. Migrated out on decode, never written back.
  @Test func aLegacyFoldedBucketIsMigratedOutOfTheOwnerList() throws {
    let legacy: [String: Any] = [
      "schemaVersion": OledStoreSchema.currentVersion,
      "secondsByOwner": ["other/apps": 7200.0, "Slack": 3600.0],
      "totalSeconds": 10800.0,
    ]
    let data = try JSONSerialization.data(withJSONObject: legacy)
    let decoded = try JSONDecoder().decode(OwnerHours.self, from: data)

    #expect(decoded.secondsByOwner == ["Slack": 3600])
    #expect(decoded.foldedSeconds == 7200)
    #expect(decoded.totalSeconds == 10800)
    #expect(decoded.topOwners(limit: 5).map(\.owner) == ["Slack"])

    // And it does not come back on the next write.
    let rewritten = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(decoded)) as? [String: Any]
    let owners = try #require(rewritten?["secondsByOwner"] as? [String: Double])
    #expect(owners["other/apps"] == nil)
  }

  /// Each write re-encodes the last, so a non-idempotent fold eats one more
  /// owner per save.
  @Test func anAlreadyFoldedStoreReEncodesToItself() throws {
    let once = try JSONDecoder().decode(OwnerHours.self, from: JSONEncoder().encode(sixtyOwners()))
    let twice = try JSONDecoder().decode(OwnerHours.self, from: JSONEncoder().encode(once))
    #expect(twice == once)
  }

  /// The fold lives outside the owner map, so the list needs no filter to keep
  /// it off screen.
  @Test func theFoldedBucketNeverReachesTheOwnerList() {
    let hours = OwnerHours(
      secondsByOwner: ["Slack": 3600], totalSeconds: 10800, foldedSeconds: 7200)
    #expect(hours.topOwners(limit: 5).map(\.owner) == ["Slack"])
  }
}
