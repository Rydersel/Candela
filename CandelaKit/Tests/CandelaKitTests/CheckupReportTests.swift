import Foundation
import Testing
@testable import CandelaKit

@Suite("Checkup report and envelope")
struct CheckupReportTests {
  private func sample() -> CheckupReport {
    CheckupReport(
      scenario: .newMonitor,
      identity: CheckupDisplayIdentity(
        identityKey: "10ac-a0b2-4436", vendorID: 0x10AC, modelID: 0xA0B2,
        serial: "1CHB884", manufactureWeek: 51, manufactureYear: 2025,
        nativePixelWidth: 3840, nativePixelHeight: 2160, maxRefreshHz: 120,
        supportsPQEOTF: false, supportsHDRGammaEOTF: false, productName: "DELL U2725QE"),
      panelClass: .readsDDC, macOSBuild: "25A100", appBuild: "3",
      startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
      endedAt: Date(timeIntervalSinceReferenceDate: 800_000_900),
      completion: .complete,
      claims: [
        CheckupClaim(family: .identity, id: CheckupCheckID.identity, verdict: .observed("EDID parsed")),
        CheckupClaim(family: .refresh, id: "refresh.120", verdict: .refused("achieved 60 Hz")),
        CheckupClaim(family: .visualField, id: "field.black", verdict: .selfReported("no marks"), detectedAt: 4),
      ],
      plant: CheckupPlantRecord(disclosed: true, detectedAtPixels: 4, missed: false),
      showings: ["field.black": 1],
      exposureBookingID: "chk-1")
  }

  @Test func theEnvelopeValidatesAndATamperedBodyDoesNot() throws {
    let envelope = try CheckupReportEnvelope(report: sample())
    #expect(envelope.validate())
    #expect(envelope.sha256.count == 64)
    var data = try JSONEncoder().encode(envelope)
    var text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"refused\""))
    text = text.replacingOccurrences(of: "\"kind\":\"refused\"", with: "\"kind\":\"observed\"")
    data = Data(text.utf8)
    let edited = try JSONDecoder().decode(CheckupReportEnvelope.self, from: data)
    #expect(edited.validate() == false)
  }

  @Test func canonicalEncodingIsStableAcrossKeyOrder() throws {
    let a = try CheckupReportEnvelope.canonicalData(sample())
    let b = try CheckupReportEnvelope.canonicalData(sample())
    #expect(a == b)
    #expect(!String(decoding: a, as: UTF8.self).contains("\n"))
  }

  @Test func summaryCountsByVerdictAndDemonstratesSomething() {
    let report = sample()
    #expect(report.summary.observed == 1)
    #expect(report.summary.refused == 1)
    #expect(report.summary.selfReported == 1)
    #expect(report.summary.notObserved == 0)
    #expect(report.demonstratedSomething)
    #expect(report.summary.line.contains("1 observed"))
    #expect(report.summary.line.contains("control detected at 4 px"))
  }

  @Test func aReportOfOnlyAttestationsDemonstratesNothingAndSaysSo() {
    var report = sample()
    report.claims = [
      CheckupClaim(family: .capabilities, id: "capabilities.brightness", verdict: .notObserved("write-only")),
      CheckupClaim(family: .visualField, id: "field.black", verdict: .selfReported("no marks")),
    ]
    #expect(report.demonstratedSomething == false)
    #expect(report.summary.line.contains("nothing was measured"))
  }

  @Test func theHeaderSentenceIsFixed() {
    #expect(CheckupReport.headerSentence == "This report records observations made with Candela on the stated date; it does not certify the display.")
  }

  @Test func theReportCarriesNoHostnameOrUserName() throws {
    let text = String(decoding: try JSONEncoder().encode(sample()), as: UTF8.self)
    #expect(!text.lowercased().contains("hostname"))
    #expect(!text.contains(NSUserName()))
  }
}
