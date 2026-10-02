import Foundation
import KeyboardShortcuts
import Testing

/// Builds no `ShortcutManager`, so no Carbon hotkey is ever registered. Covers
/// only the reset's shortcut step, not the rest of the reset sequence.
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
