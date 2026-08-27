import Foundation
import Testing
@testable import CandelaKit

@Suite("Provenance envelope")
struct ProvenanceEnvelopeTests {
  private func envelope() throws -> ProvenanceEnvelope {
    try ProvenanceEnvelope(record: ProvenanceRecordTests.sampleRecord())
  }

  @Test func validatesFreshAndAfterAFileRoundTrip() throws {
    let e = try envelope()
    #expect(e.validate())
    let data = try ProvenanceEnvelope.encoded(e)
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("p.json")
    try data.write(to: url)
    let back = try ProvenanceEnvelope.load(url: url)
    #expect(back == e)
    #expect(back.validate())
  }

  @Test func aFlippedByteInTheRecordFails() throws {
    var data = try ProvenanceEnvelope.encoded(try envelope())
    let range = data.range(of: Data("7200".utf8))!
    data.replaceSubrange(range, with: Data("7201".utf8))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let tampered = try decoder.decode(ProvenanceEnvelope.self, from: data)
    #expect(!tampered.validate())
  }

  @Test func anUnknownBodyKeyFails() throws {
    let data = try ProvenanceEnvelope.encoded(try envelope())
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var record = object["record"] as! [String: Any]
    record["ownerNote"] = "hand added"
    object["record"] = record
    let edited = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let e = try decoder.decode(ProvenanceEnvelope.self, from: edited)
    #expect(!e.validate())
  }

  /// The file an older Candela would have written, from before `macOSBuild`
  /// existed: the digest covers only the keys that file carried.
  private func fileWrittenBeforeMacOSBuild() throws -> Data {
    let keys = ProvenanceRecord.knownBodyKeys.subtracting(["macOSBuild"])
    let body = ProvenanceEnvelope.Body(record: ProvenanceRecordTests.sampleRecord(), keys: keys)
    let sha = try CanonicalDigest.sha256Hex(body)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let recordObject = try JSONSerialization.jsonObject(with: try encoder.encode(body))
    let fileObject: [String: Any] = ["schemaVersion": 1, "record": recordObject, "sha256": sha]
    return try JSONSerialization.data(withJSONObject: fileObject)
  }

  private func decodeStoredEnvelope(_ data: Data) throws -> ProvenanceEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ProvenanceEnvelope.self, from: data)
  }

  @Test func aFileWrittenWithoutALaterKeyStillValidates() throws {
    let e = try decodeStoredEnvelope(try fileWrittenBeforeMacOSBuild())
    #expect(e.record.macOSBuild == "")
    #expect(e.validate())
  }

  @Test func writingAnOlderFileAgainKeepsTheShapeItWasWrittenWith() throws {
    let written = try ProvenanceEnvelope.encoded(
      try decodeStoredEnvelope(try fileWrittenBeforeMacOSBuild()))
    #expect(!String(decoding: written, as: UTF8.self).contains("macOSBuild"))
    #expect(try decodeStoredEnvelope(written).validate())
  }

  @Test func aKnownKeyAddedToAnOlderBodyFails() throws {
    var object = try #require(
      try JSONSerialization.jsonObject(with: try fileWrittenBeforeMacOSBuild()) as? [String: Any])
    var record = try #require(object["record"] as? [String: Any])
    record["macOSBuild"] = "x"
    object["record"] = record
    let edited = try JSONSerialization.data(withJSONObject: object)
    // The key is one Candela writes, so the subset guard lets it through; the
    // digest over the keys the file actually carried is what catches it.
    #expect(try decodeStoredEnvelope(edited).validate() == false)
  }

  /// A run lifted back out of an exported record still validates as a checkup file.
  /// Nesting must not re-encode it, which would move its bytes and break its digest.
  @Test func aRunLiftedOutOfAnExportedRecordIsStillAValidCheckupFile() throws {
    let base = ProvenanceRecordTests.sampleRecord()
    let run = try CheckupReportEnvelope(
      report: ProvenanceSummaryTextTests.checkupReport(
        startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000)))
    let record = ProvenanceRecord(
      exportedAt: base.exportedAt, appBuild: base.appBuild, macOSBuild: base.macOSBuild,
      identity: base.identity, hours: base.hours, exposure: base.exposure,
      checkups: .collected(ProvenanceCheckups(runs: [run], countsByVerdict: ["observed": 1])))

    let outer = try decodeStoredEnvelope(
      try ProvenanceEnvelope.encoded(try ProvenanceEnvelope(record: record)))
    #expect(outer.validate())
    let lifted = try #require(outer.record.checkups.value?.runs.first)
    #expect(lifted.validate())

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("run.json")
    try CheckupStore.encoded(lifted).write(to: url)
    #expect(try CheckupStore(directory: dir).load(url: url).validate())
  }

  @Test func exportFileNameCarriesModelAndDay() throws {
    let e = try envelope()
    #expect(ProvenanceEnvelope.exportFileName(for: e.record)
      == "Candela Provenance DELL U2725QE 2026-05-09.candela-provenance.json")
  }
}
