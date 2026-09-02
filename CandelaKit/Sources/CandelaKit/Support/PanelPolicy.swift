import Foundation

/// What the panel renders, and in what order. Pure, so it stays testable with
/// no app test target: the view supplies the projections.
public enum DisplayOrdering {
  /// The user's chosen name when they set one, the hardware name otherwise.
  /// Whitespace-only counts as unset: a hand-cleared field must not render as a
  /// blank section header.
  public static func title(friendlyName: String, hardwareName: String) -> String {
    let trimmed = friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? hardwareName : trimmed
  }

  /// Hidden displays removed, the rest ordered ASCENDING by title.
  ///
  /// Filtering and ordering are one call on purpose: split apart, the sort can
  /// overwrite the filtered array and the filter never reaches the menu.
  /// `localizedStandardCompare` puts "Display 2" before "Display 10". Ties keep
  /// discovery order, so two identically-named panels do not reshuffle between
  /// refreshes.
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

  /// Two attached units that report no serial resolve to ONE persistence key,
  /// so they share every pref and one name. A 1-based ordinal by list order is the
  /// only live fact telling their rows apart; `nil` means the key is unique.
  ///
  /// Answers for every key in one pass rather than offering a per-row "which number
  /// is this" that takes a position. A caller holding a position holds a second,
  /// older description of the list: the sidebar did that and crashed, indexing past
  /// the end after a settings reset emptied the display list.
  public static func sharedIdentityOrdinals(keys: [String]) -> [Int?] {
    var occurrences: [String: Int] = [:]
    for key in keys { occurrences[key, default: 0] += 1 }
    var numbered: [String: Int] = [:]
    return keys.map { key in
      guard occurrences[key, default: 0] > 1 else { return nil }
      let ordinal = numbered[key, default: 0] + 1
      numbered[key] = ordinal
      return ordinal
    }
  }
}

/// Menu-bar icon visibility. The mode is a user preference, but the status
/// item's visibility is ALSO written from outside the app (⌘-dragging the icon off
/// the bar hides it), so the two directions are separate decisions.
public enum MenuIconPolicy {
  /// The order the modes are offered in. NOT `MenuIcon.allCases`: `externalOnly` was
  /// appended as raw 3 but reads third, so raw order would reorder the popup.
  public static let pickerOrder: [MenuIcon] = [.show, .sliderOnly, .externalOnly, .hide]

  /// `hasVisibleSlider` means the panel would render at least one display section.
  /// The caller derives it from the same ordering and hide rules the panel uses, so
  /// the icon and the panel cannot disagree.
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

  /// What to persist when the status item's visibility changes underneath us; `nil`
  /// writes nothing.
  ///
  /// A loop guard: only a user drag-removal is a mode change. Counting our own
  /// programmatic hide as one thrashes apply, observe, persist, apply. Becoming
  /// visible is never a mode change either, since the mode is what made it visible.
  public static func modeAfterVisibilityChange(
    isVisible: Bool,
    changedByUser: Bool,
    current: MenuIcon
  ) -> MenuIcon? {
    guard changedByUser, !isVisible, current != .hide else { return nil }
    return .hide
  }
}
