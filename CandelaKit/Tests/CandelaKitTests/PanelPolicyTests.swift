import Testing
@testable import CandelaKit

/// Ordering assertions below use ASCII names on purpose: `panelOrder` calls
/// `localizedStandardCompare`, which reads the process locale. ASCII input
/// orders identically under every locale these tests could run in, so the
/// suite is locale-independent without pinning a locale.
@Suite("Panel policy — display ordering, hide, menu-icon visibility (D5, D7)")
struct PanelPolicyTests {
  /// Stand-in for `AppModel.DisplayState` (the app target has no test target,
  /// D21 — the policy is generic over the projection precisely so it can be
  /// tested against a plain value type).
  private struct Entry {
    let hardwareName: String
    var friendlyName: String = ""
    var hidden: Bool = false
  }

  private func order(_ entries: [Entry]) -> [String] {
    DisplayOrdering.panelOrder(
      entries,
      isHidden: \.hidden,
      title: { DisplayOrdering.title(friendlyName: $0.friendlyName, hardwareName: $0.hardwareName) }
    )
    .map(\.hardwareName)
  }

  @Test func titleFallsBackToTheHardwareNameWhenNoFriendlyNameIsSet() {
    #expect(DisplayOrdering.title(friendlyName: "", hardwareName: "MAG 341C") == "MAG 341C")
    #expect(DisplayOrdering.title(friendlyName: "Desk", hardwareName: "MAG 341C") == "Desk")
    // A field the user emptied by hand holds whitespace, not "" — treat it as unset
    // rather than rendering a blank section header.
    #expect(DisplayOrdering.title(friendlyName: "   ", hardwareName: "MAG 341C") == "MAG 341C")
  }

  @Test func orderIsAscendingNotTheForksDescending() {
    // D7 / controller-findings: the fork's comparator returns
    // `localizedStandardCompare(...) == .orderedDescending`, listing displays Z→A.
    let entries = [Entry(hardwareName: "Studio Display"),
                   Entry(hardwareName: "ASUS PB278"),
                   Entry(hardwareName: "MAG 341C")]
    #expect(order(entries) == ["ASUS PB278", "MAG 341C", "Studio Display"])
  }

  @Test func orderSortsOnTheFriendlyNameWhenOneIsSet() {
    let entries = [Entry(hardwareName: "ASUS PB278", friendlyName: "Zebra"),
                   Entry(hardwareName: "Studio Display", friendlyName: "Alpha")]
    #expect(order(entries) == ["Studio Display", "ASUS PB278"])
  }

  @Test func orderIsNumberAwareLikeTheFinder() {
    // localizedStandardCompare, not a byte compare: "Display 2" precedes "Display 10".
    let entries = [Entry(hardwareName: "Display 10"),
                   Entry(hardwareName: "Display 2"),
                   Entry(hardwareName: "Display 1")]
    #expect(order(entries) == ["Display 1", "Display 2", "Display 10"])
  }

  @Test func hiddenDisplaysAreDroppedAndTheFilterSurvivesTheSort() {
    // Fork bug 1 (D2): MenuHandler builds a filtered array and then overwrites
    // it with `sortDisplaysByFriendlyName()`, so the filter never reaches the
    // menu. Filtering and ordering are ONE call here so they cannot separate.
    let entries = [Entry(hardwareName: "Studio Display"),
                   Entry(hardwareName: "ASUS PB278", hidden: true),
                   Entry(hardwareName: "MAG 341C")]
    #expect(order(entries) == ["MAG 341C", "Studio Display"])
  }

  @Test func equalTitlesKeepDiscoveryOrder() {
    // Two identical panels are a real rig; the panel must not reshuffle them
    // between refreshes.
    //
    // 24 entries, not 2 (review lens 4, M3): `sorted(by:)` is stable only below
    // its insertion-sort threshold, so a two-element case passes even with the
    // explicit `lhs.offset < rhs.offset` tie-break deleted. 24 crosses the
    // threshold, so deleting the tie-break fails this test.
    let entries = (0 ..< 24).map { Entry(hardwareName: "HW\($0)", friendlyName: "Same") }
    #expect(order(entries) == entries.map(\.hardwareName))
  }

  @Test func emptyInputOrdersToEmpty() {
    #expect(order([]) == [])
    #expect(order([Entry(hardwareName: "MAG 341C", hidden: true)]) == [])
  }

  // The three ordinal tests below cover the derivation, and only that. They do
  // NOT cover the thing that trapped: a sidebar row re-rendered against a
  // display list that had already been emptied. That path is a SwiftUI `ForEach`
  // in the app target, which has no test target (D21), so nothing automated
  // reaches it. The issue's hardware verification (a Reset All with the settings
  // window open) is the only evidence the crash is gone.
  @Test func uniqueKeysGetNoOrdinal() {
    #expect(DisplayOrdering.sharedIdentityOrdinals(keys: []) == [])
    #expect(DisplayOrdering.sharedIdentityOrdinals(keys: ["mag", "dell"]) == [nil, nil])
  }

  @Test func repeatedKeysAreNumberedInListOrder() {
    // SO21: identical units reporting no serial resolve to ONE persistence key,
    // so they share a name and a destination; the ordinal is what tells their
    // rows apart.
    #expect(
      DisplayOrdering.sharedIdentityOrdinals(keys: ["twin", "dell", "twin"])
        == [1, nil, 2]
    )
    #expect(
      DisplayOrdering.sharedIdentityOrdinals(keys: ["twin", "twin", "twin"])
        == [1, 2, 3]
    )
  }

  @Test func twoSharedGroupsAreNumberedIndependently() {
    #expect(
      DisplayOrdering.sharedIdentityOrdinals(keys: ["a", "b", "a", "b", "c"])
        == [1, 1, 2, 2, nil]
    )
  }

  @Test func statusItemVisibilityTruthTable() {
    for hasExternal in [true, false] {
      for hasSlider in [true, false] {
        #expect(MenuIconPolicy.isStatusItemVisible(
          mode: .show, hasExternalDisplay: hasExternal, hasVisibleSlider: hasSlider))
        #expect(!MenuIconPolicy.isStatusItemVisible(
          mode: .hide, hasExternalDisplay: hasExternal, hasVisibleSlider: hasSlider))
        #expect(MenuIconPolicy.isStatusItemVisible(
          mode: .sliderOnly, hasExternalDisplay: hasExternal, hasVisibleSlider: hasSlider) == hasSlider)
        #expect(MenuIconPolicy.isStatusItemVisible(
          mode: .externalOnly, hasExternalDisplay: hasExternal, hasVisibleSlider: hasSlider) == hasExternal)
      }
    }
  }

  @Test func pickerOrderIsExplicitAndIsNotRawValueOrder() {
    // D5: `externalOnly` was appended as raw 3 but belongs third in the UI.
    // Iterating allCases would silently reorder the popup.
    #expect(MenuIconPolicy.pickerOrder == [.show, .sliderOnly, .externalOnly, .hide])
    #expect(MenuIconPolicy.pickerOrder != MenuIcon.allCases)
    #expect(Set(MenuIconPolicy.pickerOrder) == Set(MenuIcon.allCases))
    // Count, not just set equality (review lens 4, M11): a Set comparison alone
    // is satisfied by [.show, .show, .sliderOnly, .externalOnly, .hide], which
    // would render a duplicate popup row.
    #expect(MenuIconPolicy.pickerOrder.count == MenuIcon.allCases.count)
  }

  @Test func onlyAUserRemovalPersistsHide() {
    // D5 loop guard: our own programmatic hide must write nothing, or
    // apply → observe → persist → apply thrashes.
    #expect(MenuIconPolicy.modeAfterVisibilityChange(
      isVisible: false, changedByUser: true, current: .show) == .hide)
    #expect(MenuIconPolicy.modeAfterVisibilityChange(
      isVisible: false, changedByUser: true, current: .externalOnly) == .hide)
    #expect(MenuIconPolicy.modeAfterVisibilityChange(
      isVisible: false, changedByUser: false, current: .show) == nil)
    // Already hidden: no redundant write, no redundant propagation.
    #expect(MenuIconPolicy.modeAfterVisibilityChange(
      isVisible: false, changedByUser: true, current: .hide) == nil)
    // Becoming visible is never a mode change — the mode is what made it visible.
    #expect(MenuIconPolicy.modeAfterVisibilityChange(
      isVisible: true, changedByUser: true, current: .hide) == nil)
  }
}
