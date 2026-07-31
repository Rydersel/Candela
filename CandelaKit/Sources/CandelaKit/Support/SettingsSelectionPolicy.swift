/// Whether a selected display destination is still valid.
///
/// Lives in CandelaKit rather than the view because it is the only part of the
/// settings redesign that is a pure function, and therefore the only part with
/// an automated net — the app target has no test target by design.
public enum SettingsSelectionPolicy {
  /// Returns the key to keep selected, or `nil` when the caller must fall back
  /// to a pane destination.
  ///
  /// Keys are `DisplayPrefs` persistence keys, which survive a replug; display
  /// IDs do not, and selecting by ID would drop the user out of a pane every
  /// time a monitor renegotiated its link.
  public static func resolve(selectedDisplayKey: String?, connectedKeys: [String]) -> String? {
    guard let selectedDisplayKey, connectedKeys.contains(selectedDisplayKey) else { return nil }
    return selectedDisplayKey
  }
}
