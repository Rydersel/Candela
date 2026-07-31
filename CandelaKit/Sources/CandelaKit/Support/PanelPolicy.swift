import Foundation

/// What the panel renders, and in what order (D7). Pure — the view supplies
/// the projections, so this is testable without an app test target (D21).
public enum DisplayOrdering {
  /// The name shown for a display: the user's chosen name when they set one,
  /// the hardware name otherwise. Whitespace-only counts as unset — a field
  /// the user cleared by hand must not render as a blank section header.
  public static func title(friendlyName: String, hardwareName: String) -> String {
    let trimmed = friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? hardwareName : trimmed
  }

  /// Hidden displays removed, the rest ordered ASCENDING by title.
  ///
  /// Filtering and ordering are deliberately one call: the fork builds a
  /// filtered array and then overwrites it with its sort, so its per-display
  /// filter never reaches the menu (D2 bug 1). They cannot come apart here.
  ///
  /// Ascending, not the fork's `.orderedDescending` (D7), and
  /// `localizedStandardCompare` so "Display 2" precedes "Display 10" the way
  /// the Finder orders names. Ties keep discovery order, so a rig with two
  /// identically-named panels does not reshuffle between refreshes.
  /// Ungated: there is no sort preference, in this app or the fork.
  public static func panelOrder<T>(
    _ items: [T],
    isHidden: (T) -> Bool,
    title: (T) -> String
  ) -> [T] {
    items.enumerated()
      .filter { !isHidden($0.element) }
      .sorted { lhs, rhs in
        let comparison = title(lhs.element).localizedStandardCompare(title(rhs.element))
        if comparison == .orderedSame { return lhs.offset < rhs.offset }
        return comparison == .orderedAscending
      }
      .map(\.element)
  }
}

/// Menu-bar icon visibility (D5). The mode is a user preference, but the
/// status item's visibility is ALSO written from outside the app — ⌘-dragging
/// the icon off the bar hides it — so the two directions are separate
/// decisions and both live here.
public enum MenuIconPolicy {
  /// The order the modes are offered in. NOT `MenuIcon.allCases`: `externalOnly`
  /// was appended as raw 3 but reads third, so iterating raw order would
  /// silently reorder the popup (D5).
  public static let pickerOrder: [MenuIcon] = [.show, .sliderOnly, .externalOnly, .hide]

  /// Should the status item be in the menu bar right now?
  /// `hasVisibleSlider` is "the panel would render at least one display
  /// section" — the caller derives it from the same ordering/hide rules the
  /// panel itself uses, so the icon and the panel can never disagree.
  public static func isStatusItemVisible(
    mode: MenuIcon,
    hasExternalDisplay: Bool,
    hasVisibleSlider: Bool
  ) -> Bool {
    switch mode {
    case .show: true
    case .sliderOnly: hasVisibleSlider
    case .externalOnly: hasExternalDisplay
    case .hide: false
    }
  }

  /// What to persist when the status item's visibility changes underneath us.
  /// `nil` means "write nothing".
  ///
  /// The fork's loop guard, as a decision table: only a change the USER made
  /// (a drag-removal) is a mode change; our own programmatic hide is not, or
  /// apply → observe → persist → apply thrashes. Becoming visible is never a
  /// mode change either — the mode is what made it visible.
  public static func modeAfterVisibilityChange(
    isVisible: Bool,
    changedByUser: Bool,
    current: MenuIcon
  ) -> MenuIcon? {
    guard changedByUser, !isVisible, current != .hide else { return nil }
    return .hide
  }
}
