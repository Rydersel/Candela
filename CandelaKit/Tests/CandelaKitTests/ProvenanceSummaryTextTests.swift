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
    #expect(lines.contains("Panel-on time: 2 h 0 min"))
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
}
