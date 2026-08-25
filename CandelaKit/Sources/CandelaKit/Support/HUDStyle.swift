/// How the on-screen indicator pill draws, app-level like its two position
/// keys (one choice covers every kind and every display). Raw values are
/// shipped on-disk schema: add cases, never renumber.
///
/// The geometry each case names is pinned in the Keyboard & Menu Bar redesign
/// spec (KMR-A3) so the real pill (`BrightnessHUD`) and the Menu Bar pane's
/// miniature preview draw the same thing from one definition.
public enum HUDStyle: Int, Sendable, CaseIterable {
  /// The shipped look, styled after the native macOS pill: name label over an
  /// icon-flanked continuous bar.
  case system = 0
  /// The same pill chrome with the bar as 16 discrete segments, after the
  /// classic macOS on-screen display.
  case segments = 1
  /// A smaller, name-less pill: icons and the bar only.
  case compact = 2

  /// Reading order for pickers. Matches raw order today; consumed anyway so a
  /// future case slots into the right place without reordering raws (the same
  /// contract as `MenuIconPolicy.pickerOrder` and `HUDPlacement.pickerOrder`).
  public static let pickerOrder: [HUDStyle] = [.system, .segments, .compact]
}
