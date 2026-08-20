import CandelaKit
import SwiftUI

/// Accessibility identifiers for pref-writing controls. The composition
/// mirrors DisplayPrefs' on-disk key composition: app-level prefs are the
/// bare raw value, per-display prefs append the persistence key, per-command
/// prefs put the command between name and key, and virtual-display slot
/// prefs append the slot number. Not user-visible copy and not what
/// VoiceOver speaks (D25 does not bear on it); coexists with the labels.
enum PrefIdentifierComposer {
  static func compose(
    _ name: PrefName, command: DDCCommand? = nil,
    persistenceKey: String? = nil, slot: Int? = nil
  ) -> String {
    var parts = [name.rawValue]
    if let command { parts.append(command.rawValue) }
    if let persistenceKey { parts.append(persistenceKey) }
    if let slot { parts.append(String(slot)) }
    return parts.joined(separator: ".")
  }
}

extension View {
  func prefIdentifier(
    _ name: PrefName, command: DDCCommand? = nil,
    persistenceKey: String? = nil, slot: Int? = nil
  ) -> some View {
    accessibilityIdentifier(PrefIdentifierComposer.compose(
      name, command: command, persistenceKey: persistenceKey, slot: slot))
  }
}
