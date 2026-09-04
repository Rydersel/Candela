import Foundation
import Testing
@testable import CandelaKit

@Suite("Display logging tags")
struct DisplayLoggingTests {
  /// The serial-bearing fallback shape `DisplayDiscovery.persistenceKey` builds
  /// when the EDID carries no UUID.
  private static let serial = "ABC123456789"
  private static let tripleKey = "MSIMAG341C-MSI-\(serial)"
  private static let uuidKey = "4C2E9A11-0000-0000-0000-000000000001"

  @Test func tagIsEightHexCharacters() {
    let tag = DisplayLogging.tag(for: Self.tripleKey)
    #expect(tag.count == 8)
    #expect(tag.allSatisfy { $0.isHexDigit && !$0.isUppercase })
  }

  /// Pinned: a tag that changed between builds could not correlate a display
  /// across sessions.
  @Test func tagIsPinnedToTheKeyBytes() {
    #expect(DisplayLogging.tag(for: Self.tripleKey) == "cee121a0")
    #expect(DisplayLogging.tag(for: Self.uuidKey) == "8b0f6bee")
    #expect(DisplayLogging.tag(for: "") == "e3b0c442")
  }

  @Test func sameKeyGivesTheSameTag() {
    #expect(DisplayLogging.tag(for: Self.tripleKey) == DisplayLogging.tag(for: Self.tripleKey))
  }

  @Test func differentKeysGiveDifferentTags() {
    #expect(DisplayLogging.tag(for: Self.tripleKey) != DisplayLogging.tag(for: Self.uuidKey))
    // One character apart, so a truncating or prefix-only scheme fails here.
    #expect(DisplayLogging.tag(for: "MSIMAG341C-MSI-ABC123456788")
      != DisplayLogging.tag(for: Self.tripleKey))
  }

  /// An 8-char tag cannot contain a 12-char serial however it is built, so the
  /// short key is what makes a truncating leak fail here.
  @Test func tagCarriesNeitherTheSerialNorTheKey() {
    #expect(!DisplayLogging.tag(for: Self.tripleKey).contains(Self.serial))
    #expect(!DisplayLogging.tag(for: Self.tripleKey).contains("MSIMAG341C"))

    // Lowercase, so a case mismatch cannot make these pass.
    let short = "ab"
    let tag = DisplayLogging.tag(for: short)
    for length in 1...short.count {
      #expect(tag != String(short.prefix(length)))
      #expect(!tag.hasPrefix(String(short.prefix(length))))
    }
  }
}
