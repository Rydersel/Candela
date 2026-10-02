import Foundation
import KeyboardShortcuts
import Testing

/// The settings reset's shortcut step: `ShortcutManager.clearAssignmentsForReset()`,
/// called from the reset before the domain wipe. Driven through the library's
/// public API in this test process's own defaults domain. No `ShortcutManager`
/// is built here, so no name carries a handler and no Carbon hotkey is ever
/// registered. Proves the reset step removes a recorded HDR chord from the
/// library's store; it does not exercise the rest of the reset sequence.
@Suite("Settings reset clears recorded shortcuts", .serialized) @MainActor
struct ResetShortcutClearingTests {
  private static let prefix = "KeyboardShortcuts_"

  @Test func resetRemovesARecordedHDRShortcut() {
    let defaults = UserDefaults.standard
    let saved = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(Self.prefix) }
    defer {
      for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.prefix) {
        defaults.removeObject(forKey: key)
      }
      for (key, value) in saved { defaults.set(value, forKey: key) }
    }

    let chord = KeyboardShortcuts.Shortcut(.f19, modifiers: [.command, .option, .control, .shift])
    KeyboardShortcuts.setShortcut(chord, for: .toggleHDR)
    KeyboardShortcuts.setShortcut(chord, for: .brightnessUp)
    // The control: the chord is really stored before the reset step runs.
    #expect(KeyboardShortcuts.getShortcut(for: .toggleHDR) == chord)
    #expect(defaults.object(forKey: Self.prefix + "toggleHDR") != nil)

    ShortcutManager.clearAssignmentsForReset()

    #expect(KeyboardShortcuts.getShortcut(for: .toggleHDR) == nil)
    #expect(KeyboardShortcuts.getShortcut(for: .brightnessUp) == nil)
    #expect(defaults.object(forKey: Self.prefix + "toggleHDR") == nil)
  }
}
