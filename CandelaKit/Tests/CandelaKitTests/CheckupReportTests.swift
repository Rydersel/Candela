import CryptoKit
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
    func report(showingKeysInsertedAs order: [String]) -> CheckupReport {
      var showings: [String: Int] = [:]
      for key in order { showings[key] = 1 }
      var report = sample()
      report.showings = showings
      return report
    }
    let a = try CheckupReportEnvelope.canonicalData(
      report(showingKeysInsertedAs: ["field.black", "field.red", "field.green", "field.blue"]))
    let b = try CheckupReportEnvelope.canonicalData(
      report(showingKeysInsertedAs: ["field.blue", "field.green", "field.red", "field.black"]))
    #expect(a == b)
    let text = String(decoding: a, as: UTF8.self)
    #expect(!text.contains(": "))
    #expect(!text.contains(", "))
    #expect(!text.contains("\n"))
  }

  @Test func completionEncodesToTheShippedSchemaShape() throws {
    let incompleteData = try JSONEncoder().encode(CheckupCompletion.incomplete(reason: "cable"))
    #expect(String(decoding: incompleteData, as: UTF8.self) == "{\"incomplete\":{\"reason\":\"cable\"}}")
    let completeData = try JSONEncoder().encode(CheckupCompletion.complete)
    #expect(String(decoding: completeData, as: UTF8.self) == "{\"complete\":{}}")

    let decodedIncomplete = try JSONDecoder().decode(CheckupCompletion.self, from: incompleteData)
    #expect(decodedIncomplete == .incomplete(reason: "cable"))
    let decodedComplete = try JSONDecoder().decode(CheckupCompletion.self, from: completeData)
    #expect(decodedComplete == .complete)
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

  /// The occlusion list is shipped schema: it round-trips, and a file written before
  /// the key existed still decodes with it empty.
  @Test func theOcclusionListRoundTripsAndAnOlderFileStillDecodes() throws {
    var report = sample()
    report.partiallyOccludedFields = ["field.black", "field.white"]
    let envelope = try CheckupReportEnvelope(report: report)
    #expect(envelope.validate())
    let decoded = try JSONDecoder().decode(
      CheckupReportEnvelope.self, from: try JSONEncoder().encode(envelope))
    #expect(decoded.report.partiallyOccludedFields == ["field.black", "field.white"])

    // The same file with the key removed, which is what every report written
    // before this key existed looks like.
    let data = try CheckupReportEnvelope.canonicalData(sample())
    var object = try #require(
      try JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "partiallyOccludedFields")
    let older = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let olderReport = try decoder.decode(CheckupReport.self, from: older)
    #expect(olderReport.partiallyOccludedFields.isEmpty)
    #expect(olderReport.claims.count == 3)
  }

  /// The file an older Candela would have written. Cutting the key from the
  /// canonical text rather than re-serializing keeps the other bytes exact.
  private func fileWrittenBeforeTheOcclusionList() throws -> Data {
    let canonical = String(
      decoding: try CheckupReportEnvelope.canonicalData(sample()), as: UTF8.self)
    #expect(canonical.contains("\"partiallyOccludedFields\":[],"))
    let body = canonical.replacingOccurrences(of: "\"partiallyOccludedFields\":[],", with: "")
    let digest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    return Data("{\"report\":\(body),\"schemaVersion\":1,\"sha256\":\"\(digest)\"}".utf8)
  }

  private func decodeStoredEnvelope(_ data: Data) throws -> CheckupReportEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CheckupReportEnvelope.self, from: data)
  }

  @Test func aReportSavedByThisBuildValidatesWhenItIsReadBack() throws {
    let data = try CheckupStore.encoded(try CheckupReportEnvelope(report: sample()))
    #expect(try decodeStoredEnvelope(data).validate())
  }

  /// A nil optional writes no key, so the stored body carries fewer keys than
  /// the model has.
  @Test func aReportWithNothingInItsOptionalsValidatesFromTheFile() throws {
    var report = sample()
    report.endedAt = nil
    report.plant = nil
    report.exposureBookingID = nil
    let data = try CheckupStore.encoded(try CheckupReportEnvelope(report: report))
    #expect(!String(decoding: data, as: UTF8.self).contains("endedAt"))
    #expect(try decodeStoredEnvelope(data).validate())
  }

  @Test func aBodyWrittenBeforeAKeyExistedStillValidates() throws {
    let envelope = try decodeStoredEnvelope(try fileWrittenBeforeTheOcclusionList())
    #expect(envelope.report.partiallyOccludedFields.isEmpty)
    #expect(envelope.validate())
  }

  @Test func aKeyAddedToAStoredBodyFailsValidation() throws {
    let older = String(decoding: try fileWrittenBeforeTheOcclusionList(), as: UTF8.self)
    let injected = older.replacingOccurrences(
      of: "\"plant\":",
      with: "\"partiallyOccludedFields\":[\"field.black\"],\"plant\":")
    #expect(injected != older)
    #expect(try decodeStoredEnvelope(Data(injected.utf8)).validate() == false)

    // A key no build knows, added to a body this build wrote.
    let current = String(
      decoding: try JSONEncoder().encode(try CheckupReportEnvelope(report: sample())),
      as: UTF8.self)
    let foreign = current.replacingOccurrences(of: "\"report\":{", with: "\"report\":{\"extra\":1,")
    #expect(foreign != current)
    let decoded = try JSONDecoder().decode(CheckupReportEnvelope.self, from: Data(foreign.utf8))
    #expect(decoded.validate() == false)
  }

  @Test func writingAnOlderEnvelopeAgainKeepsTheShapeItWasWrittenWith() throws {
    let envelope = try decodeStoredEnvelope(try fileWrittenBeforeTheOcclusionList())
    let written = try CheckupStore.encoded(envelope)
    #expect(!String(decoding: written, as: UTF8.self).contains("partiallyOccludedFields"))
    #expect(try decodeStoredEnvelope(written).validate())
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
