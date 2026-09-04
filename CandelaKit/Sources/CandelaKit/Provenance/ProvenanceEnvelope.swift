import Foundation

/// The hash covers the canonical record, so a hand edit anywhere fails `validate()`.
/// Only the digest recipe is shared with the checkup envelope, so that shipped format
/// cannot move when this one does.
public struct ProvenanceEnvelope: Codable, Equatable, Sendable {
  public static let schemaVersion = 1
  public let schemaVersion: Int
  public let record: ProvenanceRecord
  public let sha256: String
  /// Keys the source file carried, or every known key when built in memory.
  let bodyKeys: Set<String>

  enum CodingKeys: String, CodingKey { case schemaVersion, record, sha256 }

  /// Reads the keys a stored body has, including any this build does not know.
  private struct BodyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  struct Body: Encodable {
    let record: ProvenanceRecord
    let keys: Set<String>
    func encode(to encoder: Encoder) throws { try record.encode(to: encoder, keys: keys) }
  }

  public init(record: ProvenanceRecord) throws {
    self.schemaVersion = Self.schemaVersion
    self.record = record
    self.bodyKeys = ProvenanceRecord.knownBodyKeys
    self.sha256 = try CanonicalDigest.sha256Hex(Body(record: record, keys: bodyKeys))
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    record = try c.decode(ProvenanceRecord.self, forKey: .record)
    sha256 = try c.decode(String.self, forKey: .sha256)
    bodyKeys = Set(try c.nestedContainer(keyedBy: BodyKey.self, forKey: .record)
      .allKeys.map(\.stringValue))
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encode(Body(record: record, keys: bodyKeys), forKey: .record)
    try c.encode(sha256, forKey: .sha256)
  }

  /// `bodyKeys` records where the value came from, not what it says, so it is
  /// left out here.
  public static func == (lhs: ProvenanceEnvelope, rhs: ProvenanceEnvelope) -> Bool {
    lhs.schemaVersion == rhs.schemaVersion && lhs.record == rhs.record && lhs.sha256 == rhs.sha256
  }

  public func validate() -> Bool {
    // Decoding ignores an unknown key, but Candela never wrote one, so a body
    // carrying one was edited.
    guard bodyKeys.isSubset(of: ProvenanceRecord.knownBodyKeys) else { return false }
    return (try? CanonicalDigest.sha256Hex(Body(record: record, keys: bodyKeys))) == sha256
  }

  /// One encoder for every written copy, so an export is byte-identical to any
  /// other and `validate()` agrees on either.
  public static func encoded(_ envelope: ProvenanceEnvelope) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(envelope)
  }

  public static func load(url: URL) throws -> ProvenanceEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: url))
  }

  /// Named for the panel, not the user's typed label. Same sanitizer as a
  /// checkup export: a slash in an EDID name would reach the save panel as a path.
  public static func exportFileName(for record: ProvenanceRecord) -> String {
    let model = [record.identity.edid?.productName, record.identity.displayName]
      .compactMap { $0 }
      .first { !$0.isEmpty } ?? "Display"
    return "Candela Provenance \(CheckupStore.safeFileName(model)) "
      + "\(CheckupStore.day(record.exportedAt)).candela-provenance.json"
  }
}
