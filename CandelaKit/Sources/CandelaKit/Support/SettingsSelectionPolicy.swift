/// Where the settings sidebar should land after a display arrives or departs.
/// Three outcomes on purpose: a caller told only "keep or not" could never
/// distinguish "another display survives" from "none does".
public enum SettingsSelectionResolution: Equatable, Sendable {
  /// The selected display is still connected — do not move.
  case keep(String)
  /// The selected display left, but another survives — stay in display settings.
  case fallbackToSibling(String)
  /// No display remains; the caller falls back to a pane.
  case fallbackToPane
}

/// Whether a selected display destination is still valid.
///
/// Lives in CandelaKit rather than the view because it is the only part of the
/// settings redesign that is a pure function, and therefore the only part with
/// an automated net — the app target has no test target by design.
public enum SettingsSelectionPolicy {
  /// Resolves where the selection belongs, or `nil` when no display was
  /// selected at all (a pane is showing) and the caller must do nothing.
  ///
  /// Keys are `DisplayPrefs` persistence keys, which survive a replug; display
  /// IDs do not, and selecting by ID would drop the user out of a pane every
  /// time a monitor renegotiated its link.
  ///
  /// The sibling is `connectedKeys.first`, so the caller owes this function
  /// **sidebar order** — built-in first, then externals in model order. Passing
  /// any other order still resolves, but lands somewhere other than the top
  /// surviving row.
  public static func resolveDestination(
    selectedDisplayKey: String?, connectedKeys: [String]
  ) -> SettingsSelectionResolution? {
    guard let selectedDisplayKey else { return nil }
    if connectedKeys.contains(selectedDisplayKey) { return .keep(selectedDisplayKey) }
    if let sibling = connectedKeys.first { return .fallbackToSibling(sibling) }
    return .fallbackToPane
  }

  /// The key to re-select when a remembered display returns while the window is
  /// open (SO9).
  ///
  /// `nil` unless the remembered display is among the arrivals AND the user is
  /// not already on a display destination — a returning monitor must never yank
  /// them off one they chose in the meantime.
  public static func restoration(
    lastDisplayKey: String?, arrivedKeys: [String], currentIsDisplay: Bool
  ) -> String? {
    guard let lastDisplayKey, !currentIsDisplay, arrivedKeys.contains(lastDisplayKey) else { return nil }
    return lastDisplayKey
  }
}
