import CryptoKit
import Foundation

/// The one recipe every hashed artifact uses: sorted keys, no whitespace,
/// ISO 8601 dates, slashes unescaped. Two artifacts with two recipes would let
/// a file validate under one tool and fail under the other.
enum CanonicalDigest {
  static func canonicalData<T: Encodable>(_ body: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(body)
  }

  static func sha256Hex<T: Encodable>(_ body: T) throws -> String {
    SHA256.hash(data: try canonicalData(body))
      .map { String(format: "%02x", $0) }.joined()
  }
}
