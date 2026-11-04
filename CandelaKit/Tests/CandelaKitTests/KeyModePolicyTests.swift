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
    // The first three cases alone also pass an implementation that ignores
    // `volume`. The rest pin that both arguments are consulted, as a disjunction.
    #expect(KeyModePolicy.requiresAccessibility(brightness: .media, volume: .disabled))
    #expect(KeyModePolicy.requiresAccessibility(brightness: .disabled, volume: .both))
    #expect(KeyModePolicy.requiresAccessibility(brightness: .both, volume: .disabled))
    #expect(!KeyModePolicy.requiresAccessibility(brightness: .custom, volume: .disabled))
    #expect(!KeyModePolicy.requiresAccessibility(brightness: .custom, volume: .custom))
    #expect(!KeyModePolicy.requiresAccessibility(brightness: .disabled, volume: .disabled))
  }

  @Test func keysAreOffOnlyWhenBothFamiliesAreDisabled() {
    #expect(KeyModePolicy.keysOff(brightness: .disabled, volume: .disabled))
    // Custom shortcuts are keys too: an all-custom setup is on without any grant.
    #expect(!KeyModePolicy.keysOff(brightness: .custom, volume: .custom))
    // Either family alone keeps the keys on, so both arguments are consulted.
    #expect(!KeyModePolicy.keysOff(brightness: .media, volume: .disabled))
    #expect(!KeyModePolicy.keysOff(brightness: .disabled, volume: .both))
    #expect(!KeyModePolicy.keysOff(brightness: .disabled, volume: .custom))
  }
}
