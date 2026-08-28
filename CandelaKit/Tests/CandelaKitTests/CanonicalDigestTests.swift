import Foundation
import Testing
@testable import CandelaKit

@Suite("Canonical digest")
struct CanonicalDigestTests {
  private struct Body: Encodable {
    let b: Int
    let a: String
    let when: Date
  }

  @Test func keysSortAndDatesAreISO8601() throws {
    let data = try CanonicalDigest.canonicalData(
      Body(b: 1, a: "x/y", when: Date(timeIntervalSinceReferenceDate: 0)))
    #expect(String(decoding: data, as: UTF8.self)
      == #"{"a":"x/y","b":1,"when":"2001-01-01T00:00:00Z"}"#)
  }

  @Test func digestIsStableAcrossFieldOrder() throws {
    struct Reordered: Encodable { let when: Date; let a: String; let b: Int }
    let one = try CanonicalDigest.sha256Hex(
      Body(b: 1, a: "x", when: Date(timeIntervalSinceReferenceDate: 0)))
    let two = try CanonicalDigest.sha256Hex(
      Reordered(when: Date(timeIntervalSinceReferenceDate: 0), a: "x", b: 1))
    #expect(one == two)
    #expect(one.count == 64)
  }
}
