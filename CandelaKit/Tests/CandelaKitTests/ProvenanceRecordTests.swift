import Foundation
import Testing
@testable import CandelaKit

@Suite("Provenance record")
struct ProvenanceRecordTests {
  static func sampleRecord() -> ProvenanceRecord {
    ProvenanceRecord(
      exportedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
      appBuild: "1.0 (100)", macOSBuild: "26.0",
      identity: ProvenanceIdentity(
        persistenceKey: "10AC-A0B2-0000-0000", displayName: "DELL U2725QE",
        edid: nil,
        hardware: ProvenanceHardware(
          transport: "DisplayPort", manufacturerID: "DEL", alphanumericSerial: "1CHB884",
          numericSerial: nil, physicalWidthCm: 60, physicalHeightCm: 34)),
      hours: .collected(ProvenanceHours(lifetimeSeconds: 7200, secondsSinceStandby: 60)),
      exposure: .notCollected(.notEnrolled),
      checkups: .notCollected(.noRuns))
  }

  @Test func headerIsTheFixedSentencesInOrder() {
    let r = Self.sampleRecord()
    #expect(r.header == ProvenanceRecord.headerSentences)
    #expect(ProvenanceRecord.headerSentences.count == 3)
    #expect(ProvenanceRecord.headerSentences.allSatisfy { !$0.contains("\u{2014}") })
  }

  @Test func sectionsEncodeAsValueOrNamedAbsence() throws {
    let data = try CanonicalDigest.canonicalData(Self.sampleRecord())
    let json = String(decoding: data, as: UTF8.self)
    #expect(json.contains(#""exposure":{"notCollected":"notEnrolled"}"#))
    #expect(json.contains(#""hours":{"lifetimeSeconds":7200,"secondsSinceStandby":60}"#))
    #expect(json.contains(#""checkups":{"notCollected":"noRuns"}"#))
  }

  @Test func roundTripsThroughJSON() throws {
    let r = Self.sampleRecord()
    let data = try CanonicalDigest.canonicalData(r)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let back = try decoder.decode(ProvenanceRecord.self, from: data)
    #expect(back == r)
  }

  @Test func everyAbsenceHasASentence() {
    for reason in ProvenanceAbsence.allCases {
      #expect(!reason.sentence.isEmpty)
      #expect(!reason.sentence.contains("\u{2014}"))
    }
  }

  @Test func knownBodyKeysMatchTheCodingKeys() {
    #expect(ProvenanceRecord.knownBodyKeys == [
      "header", "exportedAt", "appBuild", "macOSBuild", "identity", "hours", "exposure", "checkups",
    ])
  }

  @Test func aBodyWithoutTheHeaderDecodesWithTheDefault() throws {
    var data = try CanonicalDigest.canonicalData(Self.sampleRecord())
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    object.removeValue(forKey: "header")
    data = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let back = try decoder.decode(ProvenanceRecord.self, from: data)
    #expect(back.header == ProvenanceRecord.headerSentences)
  }

  @Test func aBodyWithoutTheBuildsDecodesWithTheDefaults() throws {
    var data = try CanonicalDigest.canonicalData(Self.sampleRecord())
    var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    object.removeValue(forKey: "appBuild")
    object.removeValue(forKey: "macOSBuild")
    data = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let back = try decoder.decode(ProvenanceRecord.self, from: data)
    #expect(back.appBuild.isEmpty)
    #expect(back.macOSBuild.isEmpty)
  }

  /// Stands in for the envelope's body until that type exists: the digest is
  /// taken over exactly this encode, so a key gated by the wrong flag would
  /// hash a body nobody can reproduce.
  private struct SubsetBody: Encodable {
    let record: ProvenanceRecord
    let keys: Set<String>
    func encode(to encoder: Encoder) throws { try record.encode(to: encoder, keys: keys) }
  }

  @Test func encodingASubsetWritesExactlyThoseKeys() throws {
    let body = SubsetBody(record: Self.sampleRecord(), keys: ["exportedAt", "identity"])
    let data = try CanonicalDigest.canonicalData(body)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(Set(object.keys) == ["exportedAt", "identity"])
    #expect((object["identity"] as? [String: Any])?["persistenceKey"] as? String
      == "10AC-A0B2-0000-0000")
  }

  @Test func everyKnownKeyIsWrittenUnderItsOwnName() throws {
    let body = SubsetBody(record: Self.sampleRecord(), keys: ProvenanceRecord.knownBodyKeys)
    let data = try CanonicalDigest.canonicalData(body)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(Set(object.keys) == ProvenanceRecord.knownBodyKeys)
    #expect(object["appBuild"] as? String == "1.0 (100)")
    #expect(object["macOSBuild"] as? String == "26.0")
    #expect((object["hours"] as? [String: Any])?["lifetimeSeconds"] as? Int == 7200)
  }

  @Test func droppingOneKeyDropsOnlyThatKey() throws {
    var keys = ProvenanceRecord.knownBodyKeys
    keys.remove("checkups")
    let data = try CanonicalDigest.canonicalData(
      SubsetBody(record: Self.sampleRecord(), keys: keys))
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(Set(object.keys) == keys)
  }
}
