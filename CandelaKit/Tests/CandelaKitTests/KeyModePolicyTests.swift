import Testing
@testable import CandelaKit

@Suite("Keyboard mode policy (fork updateMediaKeyTap + guard-at-fire)")
struct KeyModePolicyTests {
  @Test func mediaKeysWatchedInMediaAndBothOnly() {
    #expect(KeyModePolicy.watchesMediaKeys(.media))
    #expect(KeyModePolicy.watchesMediaKeys(.both))
    #expect(!KeyModePolicy.watchesMediaKeys(.custom))
    #expect(!KeyModePolicy.watchesMediaKeys(.disabled))
  }

  @Test func customShortcutsFireInCustomAndBothOnly() {
    // Fork parity: hiding the recorders is presentation; the MODE is
    // enforced at dispatch (KeyboardShortcutsManager guard-at-fire).
    #expect(KeyModePolicy.firesCustomShortcuts(.custom))
    #expect(KeyModePolicy.firesCustomShortcuts(.both))
    #expect(!KeyModePolicy.firesCustomShortcuts(.media))
    #expect(!KeyModePolicy.firesCustomShortcuts(.disabled))
  }

  @Test func accessibilityRequiredOnlyWhenATapIsWanted() {
    // The three original assertions were also satisfied by
    // `!firesCustomShortcuts(brightness)`, which ignores `volume` entirely
    // (review lens 4, M6). The three added cases separate the two
    // implementations: they pin that BOTH arguments are consulted and that
    // the combination is a disjunction over `watchesMediaKeys`.
    #expect(KeyModePolicy.requiresAccessibility(brightness: .media, volume: .disabled))
    #expect(KeyModePolicy.requiresAccessibility(brightness: .disabled, volume: .both))
    #expect(KeyModePolicy.requiresAccessibility(brightness: .both, volume: .disabled))
    #expect(!KeyModePolicy.requiresAccessibility(brightness: .custom, volume: .disabled))
    #expect(!KeyModePolicy.requiresAccessibility(brightness: .custom, volume: .custom))
    #expect(!KeyModePolicy.requiresAccessibility(brightness: .disabled, volume: .disabled))
  }
}
