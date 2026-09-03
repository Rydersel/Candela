import Foundation
import Testing
@testable import CandelaKit

@Suite("Provenance summary text")
struct ProvenanceSummaryTextTests {
  @Test func rendersHeaderIdentityAndEverySection() {
    let text = ProvenanceSummaryText.render(ProvenanceRecordTests.sampleRecord())
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(Array(lines.prefix(3)) == ProvenanceRecord.headerSentences)
    #expect(lines.contains("Display: DELL U2725QE"))
    #expect(lines.contains("Identity key: 10AC-A0B2-0000-0000"))
    #expect(lines.contains("Serial: 1CHB884"))
    #expect(lines.contains("Connection: DisplayPort"))
    #expect(lines.contains("Hours of use: 2 h 0 min"))
    #expect(lines.contains("Since last standby: 1 min"))
    #expect(lines.contains(ProvenanceAbsence.notEnrolled.sentence))
    #expect(lines.contains(ProvenanceAbsence.noRuns.sentence))
    #expect(!text.contains("\u{2014}"))
    // The fixed header disclaims certification in so many words, so the banned
    // vocabulary is checked against what the renderer writes under it.
    let body = lines.dropFirst(ProvenanceRecord.headerSentences.count).joined(separator: "\n")
    for banned in ["score", "grade", "certif", "warranty", "%"] {
      #expect(!body.lowercased().contains(banned), "\(banned)")
    }
  }

  @Test func noSerialRendersAsTheFixedPhrase() {
    let base = ProvenanceRecordTests.sampleRecord()
    let record = ProvenanceRecord(
      exportedAt: base.exportedAt, appBuild: base.appBuild, macOSBuild: base.macOSBuild,
      identity: ProvenanceIdentity(
        persistenceKey: "k", displayName: "MAG 341C", edid: nil,
        hardware: ProvenanceHardware(transport: nil, manufacturerID: nil, alphanumericSerial: nil,
                                     numericSerial: nil, physicalWidthCm: nil, physicalHeightCm: nil)),
      hours: base.hours, exposure: base.exposure, checkups: base.checkups)
    #expect(ProvenanceSummaryText.render(record).contains("Serial: no serial reported"))
  }

  @Test func theExportedLineNamesTheBuildWhenThereIsOne() {
    let text = ProvenanceSummaryText.render(ProvenanceRecordTests.sampleRecord())
    #expect(text.contains("Exported: 2026-05-09 by Candela 1.0 (100)"))
  }

  @Test func anOlderFileWithoutABuildDropsTheBuildFromTheExportedLine() {
    let base = ProvenanceRecordTests.sampleRecord()
    let record = ProvenanceRecord(
      exportedAt: base.exportedAt, appBuild: "", macOSBuild: "",
      identity: base.identity, hours: base.hours, exposure: base.exposure,
      checkups: base.checkups)
    let lines = ProvenanceSummaryText.render(record).split(separator: "\n").map(String.init)
    // The header names Candela too, so the line itself is the assertion.
    #expect(lines.filter { $0.hasPrefix("Exported:") } == ["Exported: 2026-05-09"])
  }

  /// Every branch the sample record leaves untaken: an EDID, a measured
  /// exposure with a histogram, and a checkups section with runs and counts.
  static func fullRecord(confidence: ProvenanceExposure.Confidence = .measured) throws
    -> ProvenanceRecord {
    var cells = [Double](repeating: 0.1, count: 240)
    // Two equal peaks: the first one is the one that gets named.
    cells[7] = 1.0
    cells[100] = 1.0
    let exportedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    return ProvenanceRecord(
      exportedAt: exportedAt, appBuild: "1.0 (100)", macOSBuild: "26.0",
      identity: ProvenanceIdentity(
        persistenceKey: "10AC-A0B2-0000-0000", displayName: "DELL U2725QE",
        edid: CheckupDisplayIdentity(
          identityKey: "10ac-a0b2-4436", vendorID: 0x10AC, modelID: 0xA0B2,
          serial: "1CHB884", manufactureWeek: 51, manufactureYear: 2025,
          nativePixelWidth: 3840, nativePixelHeight: 2160, maxRefreshHz: 120,
          supportsPQEOTF: false, supportsHDRGammaEOTF: false, productName: "DELL U2725QE"),
        hardware: ProvenanceHardware(
          transport: "DisplayPort", manufacturerID: "DEL", alphanumericSerial: "1CHB884",
          numericSerial: nil, physicalWidthCm: 60, physicalHeightCm: 34)),
      hours: .collected(ProvenanceHours(lifetimeSeconds: 7200, secondsSinceStandby: 60)),
      exposure: .collected(ProvenanceExposure(
        cells: cells, sampleCount: 40,
        firstSample: exportedAt.addingTimeInterval(-10 * 86_400), lastSample: exportedAt,
        confidence: confidence,
        wearHistogram: ProvenanceWearHistogram(
          stateOrder: ["active", "idleDim", "blackout"], levelBuckets: 2,
          seconds: [[3600, 0], [1200, 600], [0, 0]]))),
      checkups: .collected(ProvenanceCheckups(
        runs: [try CheckupReportEnvelope(report: checkupReport(startedAt: exportedAt))],
        countsByVerdict: ["observed": 2, "notObserved": 1])))
  }

  static func checkupReport(startedAt: Date) -> CheckupReport {
    CheckupReport(
      scenario: .newMonitor,
      identity: CheckupDisplayIdentity(
        identityKey: "10ac-a0b2-4436", vendorID: 0x10AC, modelID: 0xA0B2,
        serial: "1CHB884", manufactureWeek: 51, manufactureYear: 2025,
        nativePixelWidth: 3840, nativePixelHeight: 2160, maxRefreshHz: 120,
        supportsPQEOTF: false, supportsHDRGammaEOTF: false, productName: "DELL U2725QE"),
      panelClass: .readsDDC, macOSBuild: "25A100", appBuild: "3",
      startedAt: startedAt, endedAt: startedAt.addingTimeInterval(900),
      completion: .complete,
      claims: [
        CheckupClaim(family: .identity, id: CheckupCheckID.identity, verdict: .observed("EDID parsed")),
        CheckupClaim(family: .refresh, id: "refresh.120", verdict: .refused("achieved 60 Hz")),
      ],
      plant: CheckupPlantRecord(disclosed: true, detectedAtPixels: 4, missed: false),
      showings: ["field.black": 1],
      exposureBookingID: "chk-1")
  }

  @Test func aFullRecordRendersExactlyThis() throws {
    let expected = """
      \(ProvenanceRecord.headerSentences.joined(separator: "\n"))

      Display: DELL U2725QE
      Identity key: 10AC-A0B2-0000-0000
      Exported: 2026-05-09 by Candela 1.0 (100)
      Serial: 1CHB884
      Manufactured: week 51 of 2025
      Native size: 3840 x 2160 pixels
      Connection: DisplayPort
      Screen size: 60 x 34 cm

      Hours
      Hours of use: 2 h 0 min
      Since last standby: 1 min

      Exposure
      Readings: 40 (measured)
      Recorded from 2026-04-29 to 2026-05-09
      Hottest cell: 8 of 240
      Time in active: 1 h 0 min
      Time in idle dim: 30 min

      Checkups
      Runs: 1
      Not observed: 1
      Observed: 2
      2026-05-09: 1 observed, 1 refused, 0 not observed, 0 self-reported, control detected at 4 px
      """
    #expect(ProvenanceSummaryText.render(try Self.fullRecord()) == expected)
  }

  @Test func storedKeyNamesNeverReachTheText() throws {
    let text = ProvenanceSummaryText.render(try Self.fullRecord())
    for key in ["notObserved", "selfReported", "idleDim", "lockDim", "unfocusedDim"] {
      #expect(!text.contains(key), "\(key)")
    }
  }

  @Test func anUnknownVerdictKeyRendersAsItIs() throws {
    let base = try Self.fullRecord()
    let record = ProvenanceRecord(
      exportedAt: base.exportedAt, appBuild: base.appBuild, macOSBuild: base.macOSBuild,
      identity: base.identity, hours: base.hours, exposure: base.exposure,
      checkups: .collected(ProvenanceCheckups(runs: [], countsByVerdict: ["quibbled": 3])))
    let text = ProvenanceSummaryText.render(record)
    #expect(text.contains("quibbled: 3"))
    #expect(text.contains("Runs: 0"))
  }

  @Test func anEstimatedMapNamesNoHottestCellAndSaysMeasurementIsOff() throws {
    let lines = ProvenanceSummaryText.render(try Self.fullRecord(confidence: .estimated))
      .split(separator: "\n").map(String.init)
    #expect(lines.contains("Readings: 40 recorded earlier; exposure measurement is off"))
    #expect(!lines.contains { $0.hasPrefix("Hottest cell") })
    #expect(!lines.contains { $0.contains("window geometry only, no exposure readings") })
  }

  @Test func tooFewReadingsSaysSoWithoutContradictingItself() throws {
    let text = ProvenanceSummaryText.render(try Self.fullRecord(confidence: .insufficient))
    #expect(text.contains("Readings: 40 (too few to analyze)"))
    #expect(!text.contains("Hottest cell"))
  }

  @Test func anEDIDWithNoSerialFallsThroughToTheConnectionSerial() throws {
    let base = try Self.fullRecord()
    let edid = base.identity.edid!
    let record = ProvenanceRecord(
      exportedAt: base.exportedAt, appBuild: base.appBuild, macOSBuild: base.macOSBuild,
      identity: ProvenanceIdentity(
        persistenceKey: base.identity.persistenceKey, displayName: base.identity.displayName,
        edid: CheckupDisplayIdentity(
          identityKey: edid.identityKey, vendorID: edid.vendorID, modelID: edid.modelID,
          serial: nil, manufactureWeek: edid.manufactureWeek, manufactureYear: edid.manufactureYear,
          nativePixelWidth: edid.nativePixelWidth, nativePixelHeight: edid.nativePixelHeight,
          maxRefreshHz: edid.maxRefreshHz, supportsPQEOTF: edid.supportsPQEOTF,
          supportsHDRGammaEOTF: edid.supportsHDRGammaEOTF, productName: edid.productName),
        hardware: ProvenanceHardware(
          transport: nil, manufacturerID: nil, alphanumericSerial: nil, numericSerial: 4816,
          physicalWidthCm: nil, physicalHeightCm: nil)),
      hours: base.hours, exposure: base.exposure, checkups: base.checkups)
    #expect(ProvenanceSummaryText.render(record).contains("Serial: 4816"))
  }
}
