import Foundation
import Testing
@testable import CandelaKit

@Suite("Provenance assembler")
struct ProvenanceAssemblerTests {
  private let identity = ProvenanceIdentity(
    persistenceKey: "pk", displayName: "MAG 341C", edid: nil, hardware: nil)
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func map(samples: Int, cellPeakAt index: Int) -> ExposureMap {
    map(samples: samples, cellPeaksAt: [index])
  }

  private func map(samples: Int, cellPeaksAt indices: [Int]) -> ExposureMap {
    var m = ExposureMap.empty
    var grid = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    for index in indices { grid[index] = 1.0 }
    for _ in 0..<samples { m.add(panelGrid: grid, elapsed: 60, at: now) }
    return m
  }

  private func run(observed: Int, startedAt: Date? = nil) throws -> CheckupReportEnvelope {
    var claims: [CheckupClaim] = []
    for i in 0..<observed {
      claims.append(CheckupClaim(family: .identity, id: "id.\(i)", verdict: .observed("seen")))
    }
    claims.append(CheckupClaim(family: .refresh, id: "refresh", verdict: .refused("no")))
    let report = CheckupReport(
      scenario: .newMonitor,
      identity: CheckupDisplayIdentity(
        identityKey: "pk", vendorID: 0x3669, modelID: 1, serial: nil,
        manufactureWeek: 29, manufactureYear: 2023, nativePixelWidth: 3440, nativePixelHeight: 1440,
        maxRefreshHz: 175, supportsPQEOTF: true, supportsHDRGammaEOTF: true, productName: "MAG 341C"),
      panelClass: .writeOnlyDDC, macOSBuild: "26", appBuild: "1",
      startedAt: startedAt ?? now.addingTimeInterval(Double(-observed) * 1000),
      endedAt: now, completion: .complete,
      claims: claims, plant: nil, showings: [:], exposureBookingID: nil)
    return try CheckupReportEnvelope(report: report)
  }

  @Test func hoursAreWholeSeconds() {
    let r = ProvenanceAssembler.assemble(
      identity: identity,
      hours: .collected(.init(lifetimeSeconds: 7200.9, secondsSinceStandby: 59.4)),
      exposure: .notCollected(.notEnrolled), checkups: [],
      appBuild: "1", macOSBuild: "26", now: now)
    #expect(r.hours.value == ProvenanceHours(lifetimeSeconds: 7200, secondsSinceStandby: 59))
    #expect(r.exportedAt == now)
    #expect(r.appBuild == "1")
    #expect(r.macOSBuild == "26")
    #expect(r.identity == identity)
  }

  @Test func exposureCellsAreNormalizedToThePeakAndHistogramSecondsAreWhole() throws {
    let histogram = WearHistogram(
      stateNames: WearSignalTracker.stateNames, levelBuckets: 10,
      seconds: (0..<6).map { row in (0..<10).map { row == 0 && $0 == 9 ? 100.7 : 0 } })
    let r = ProvenanceAssembler.assemble(
      identity: identity, hours: .notCollected(.trackingOff),
      exposure: .collected(.init(map: map(samples: 40, cellPeakAt: 7), confidence: .measured,
                                 histogram: histogram)),
      checkups: [], appBuild: "1", macOSBuild: "26", now: now)
    let e = try #require(r.exposure.value)
    #expect(e.cells.count == 240)
    #expect(e.cells[7] == 1.0)
    #expect(e.cells[0] == 0.5)
    #expect(e.sampleCount == 40)
    #expect(e.confidence == .measured)
    #expect(e.wearHistogram?.seconds[0][9] == 100)
    #expect(e.wearHistogram?.stateOrder == WearSignalTracker.stateNames)
    #expect(e.firstSample == now)
    #expect(e.lastSample == now)
  }

  /// The renderer's 1-based cell number and `ExposureMap.hottestCell` must name the
  /// same cell. A plateau is where two independent scans drift apart.
  @Test func theRenderedHottestCellNamesTheCellTheMapNames() throws {
    let m = map(samples: 40, cellPeaksAt: [7, 100])
    let r = ProvenanceAssembler.assemble(
      identity: identity, hours: .notCollected(.trackingOff),
      exposure: .collected(.init(map: m, confidence: .measured, histogram: nil)),
      checkups: [], appBuild: "1", macOSBuild: "26", now: now)
    let hottest = try #require(m.hottestCell)
    #expect(r.exposure.value?.cells[hottest] == 1.0)
    #expect(ProvenanceSummaryText.render(r)
      .contains("Hottest cell: \(hottest + 1) of \(PanelGrid.cellCount)"))
  }

  @Test func tooFewSamplesAndAnEmptyHistogramBecomeANamedAbsence() {
    let r = ProvenanceAssembler.assemble(
      identity: identity, hours: .notCollected(.trackingOff),
      exposure: .collected(.init(map: map(samples: 3, cellPeakAt: 0), confidence: .insufficient,
                                 histogram: nil)),
      checkups: [], appBuild: "1", macOSBuild: "26", now: now)
    #expect(r.exposure.absence == .belowMinimumSamples)
  }

  @Test func tooFewSamplesWithAHistogramStaysCollected() {
    let histogram = WearHistogram(
      stateNames: WearSignalTracker.stateNames, levelBuckets: 10,
      seconds: (0..<6).map { row in (0..<10).map { row == 0 && $0 == 0 ? 5 : 0 } })
    let r = ProvenanceAssembler.assemble(
      identity: identity, hours: .notCollected(.trackingOff),
      exposure: .collected(.init(map: .empty, confidence: .insufficient, histogram: histogram)),
      checkups: [], appBuild: "1", macOSBuild: "26", now: now)
    #expect(r.exposure.value?.confidence == .insufficient)
    #expect(r.exposure.value?.wearHistogram != nil)
    #expect(r.exposure.value?.cells == ExposureMap.empty.cells)
  }

  @Test func checkupsAreOldestFirstWithCountsByVerdict() throws {
    let newer = try run(observed: 1)
    let older = try run(observed: 3)
    let r = ProvenanceAssembler.assemble(
      identity: identity, hours: .notCollected(.trackingOff), exposure: .notCollected(.notEnrolled),
      checkups: [newer, older], appBuild: "1", macOSBuild: "26", now: now)
    let c = try #require(r.checkups.value)
    #expect(c.runs.map(\.report.startedAt) == [older.report.startedAt, newer.report.startedAt])
    #expect(c.countsByVerdict == ["observed": 4, "refused": 2])
    #expect(c.runs.allSatisfy { $0.validate() })
  }

  @Test func noRunsIsANamedAbsence() {
    let r = ProvenanceAssembler.assemble(
      identity: identity, hours: .notCollected(.trackingOff), exposure: .notCollected(.notEnrolled),
      checkups: [], appBuild: "1", macOSBuild: "26", now: now)
    #expect(r.checkups.absence == .noRuns)
  }

  @Test func runsSharingAStartInstantStillSortTotally() throws {
    let a = try run(observed: 1, startedAt: now)
    let b = try run(observed: 2, startedAt: now)
    func order(_ runs: [CheckupReportEnvelope]) -> [String] {
      ProvenanceAssembler.assemble(
        identity: identity, hours: .notCollected(.trackingOff),
        exposure: .notCollected(.notEnrolled), checkups: runs,
        appBuild: "1", macOSBuild: "26", now: now
      ).checkups.value?.runs.map(\.sha256) ?? []
    }
    #expect(order([a, b]) == order([b, a]))
    #expect(order([a, b]) == [a, b].map(\.sha256).sorted())
  }

  @Test func theFileCarriesNothingAboutThePerson() throws {
    let r = ProvenanceAssembler.assemble(
      identity: identity, hours: .collected(.init(lifetimeSeconds: 1, secondsSinceStandby: 1)),
      exposure: .collected(.init(map: map(samples: 40, cellPeakAt: 1), confidence: .measured,
                                 histogram: nil)),
      checkups: [try run(observed: 1)], appBuild: "1", macOSBuild: "26", now: now)
    let json = String(decoding: try ProvenanceEnvelope.encoded(try ProvenanceEnvelope(record: r)),
                      as: UTF8.self)
    for forbidden in ["secondsByOwner", "ownerHours", "topOwners", "hostName", "IOService",
                      "ioDisplayLocation", "dominantOwner", "modelComparison"] {
      #expect(!json.contains(forbidden), "found \(forbidden)")
    }
  }

  /// Positive control for the check above: an absence assertion against a key
  /// nothing ever writes would pass forever.
  @Test func theForbiddenOwnerKeyIsTheOneTheOwnerTableWrites() throws {
    let json = String(
      decoding: try CanonicalDigest.canonicalData(
        OwnerHours(secondsByOwner: ["com.example.editor": 60], totalSeconds: 60)),
      as: UTF8.self)
    #expect(json.contains("secondsByOwner"))
    #expect(json.contains("com.example.editor"))
  }
}
