/// How the on-screen indicator pill draws, app-level like its two position keys.
/// Raw values are shipped on-disk schema: add cases, never renumber.
///
/// The geometry each case names is pinned in KMR-A3 so the real pill and the Menu
/// Bar pane's preview draw the same thing from one definition.
public enum HUDStyle: Int, Sendable, CaseIterable {
  /// The shipped look, styled after the native macOS pill: name label over an
  /// icon-flanked continuous bar.
  case system = 0
  /// The same pill chrome with the bar as 16 discrete segments, after the
  /// classic macOS on-screen display.
  case segments = 1
  /// A smaller, name-less pill: icons and the bar only.
  case compact = 2

  /// Reading order for pickers. Matches raw order today, consumed anyway so a
  /// future case can slot in without renumbering raws.
  public static let pickerOrder: [HUDStyle] = [.system, .segments, .compact]
}
