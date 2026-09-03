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

  /// Pinned, not just self-consistent: a tag that changed between builds would
  /// break the one thing it is for, correlating a display's lines across
  /// sessions.
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

  @Test func tagCarriesNeitherTheSerialNorTheKey() {
    let tag = DisplayLogging.tag(for: Self.tripleKey)
    #expect(!tag.contains(Self.serial))
    #expect(!tag.contains("MSIMAG341C"))
  }
}
