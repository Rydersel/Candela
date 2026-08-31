/// Which key machinery a `KeyMode` engages: the media-key event tap, the custom
/// shortcut handler, or both.
public enum KeyModePolicy {
  public static func watchesMediaKeys(_ mode: KeyMode) -> Bool {
    mode == .media || mode == .both
  }

  public static func firesCustomShortcuts(_ mode: KeyMode) -> Bool {
    mode == .custom || mode == .both
  }

  /// Only the CGEvent tap needs the AX grant; KeyboardShortcuts' Carbon hotkeys do
  /// not. Either family wanting a tap is enough.
  public static func requiresAccessibility(brightness: KeyMode, volume: KeyMode) -> Bool {
    watchesMediaKeys(brightness) || watchesMediaKeys(volume)
  }
}
