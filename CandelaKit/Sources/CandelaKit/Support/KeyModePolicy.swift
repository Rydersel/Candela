/// Which key machinery a `KeyMode` engages (fork: `MediaKeyTapManager.updateMediaKeyTap`
/// for the tap; `KeyboardShortcutsManager`'s handler guards for shortcuts).
public enum KeyModePolicy {
  public static func watchesMediaKeys(_ mode: KeyMode) -> Bool {
    mode == .media || mode == .both
  }

  public static func firesCustomShortcuts(_ mode: KeyMode) -> Bool {
    mode == .custom || mode == .both
  }

  /// The CGEvent tap (media interception) is what needs the AX grant;
  /// KeyboardShortcuts' Carbon hotkeys do not. Both arguments are consulted:
  /// either family wanting a tap is sufficient.
  public static func requiresAccessibility(brightness: KeyMode, volume: KeyMode) -> Bool {
    watchesMediaKeys(brightness) || watchesMediaKeys(volume)
  }
}
