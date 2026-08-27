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

  @Test func aFileWrittenWithoutALaterKeyStillValidates() throws {
    // Simulates a file from before `macOSBuild` existed: digest without it,
    // then decode. The digest must cover only the keys the file carried.
    let record = ProvenanceRecordTests.sampleRecord()
    let keys = ProvenanceRecord.knownBodyKeys.subtracting(["macOSBuild"])
    let body = ProvenanceEnvelope.Body(record: record, keys: keys)
    let sha = try CanonicalDigest.sha256Hex(body)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let recordData = try encoder.encode(body)
    let recordObject = try JSONSerialization.jsonObject(with: recordData)
    let fileObject: [String: Any] = ["schemaVersion": 1, "record": recordObject, "sha256": sha]
    let data = try JSONSerialization.data(withJSONObject: fileObject)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let e = try decoder.decode(ProvenanceEnvelope.self, from: data)
    #expect(e.record.macOSBuild == "")
    #expect(e.validate())
  }

  @Test func exportFileNameCarriesModelAndDay() throws {
    let e = try envelope()
    #expect(ProvenanceEnvelope.exportFileName(for: e.record)
      == "Candela Provenance DELL U2725QE 2026-05-09.candela-provenance.json")
  }
}
