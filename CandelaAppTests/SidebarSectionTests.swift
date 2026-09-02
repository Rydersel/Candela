import Testing

// The sidebar's section structure, which is the ONE source of render
// order: the sidebar draws from it, and ⌘1-⌘9 index the same flattened list
// through `SettingsRegistry.panes`. Pinned here because the order is a product
// decision that a screenshot cannot defend and a compiler cannot check:
// `PaneID.allCases` says nothing about order.
@Suite("Sidebar sections")
@MainActor
struct SidebarSectionTests {
  @Test func theFlattenedOrderIsTheSpecifiedOrder() {
    #expect(
      SettingsRegistry.paneOrder == [
        .general,
        .health, .protection, .oledCare, .checkup,
        .menuBar, .keyboard, .arrangement, .virtualDisplays,
        .about,
      ])
  }

  @Test func theDescriptorsFollowTheSameOrder() {
    #expect(SettingsRegistry.panes.map(\.id) == SettingsRegistry.paneOrder)
  }

  /// A pane missing from every section is a pane with no sidebar row and no
  /// keyboard shortcut, reachable only by a debug route; a pane in two sections
  /// draws twice and takes two shortcut slots. Neither fails to compile.
  @Test func everyPaneAppearsExactlyOnce() {
    let order = SettingsRegistry.paneOrder
    #expect(Set(order) == Set(PaneID.allCases))
    #expect(order.count == PaneID.allCases.count)
  }

  @Test func onlyTheCareAndControlsSectionsAreLabelled() {
    #expect(SettingsRegistry.sections.map(\.header) == [nil, "CARE", "CONTROLS", nil])
  }

  /// The tail is a gap, never a header: the utility rows get air without
  /// being promoted to a peer section. A headerless section has nothing else to
  /// separate it, so this flag is the whole break.
  @Test func theUnlabelledTailCarriesItsOwnGap() {
    #expect(SettingsRegistry.sections.map(\.gapAbove) == [false, false, false, true])
    for section in SettingsRegistry.sections where section.gapAbove {
      #expect(section.header == nil)
    }
  }

  @Test func theSectionsHaveDistinctIdentities() {
    let ids = SettingsRegistry.sections.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test(arguments: [
    (PaneID.health, "Health", "waveform.path.ecg"),
    (PaneID.protection, "Protection", "shield"),
    (PaneID.checkup, "Checkup", "checkmark.seal"),
  ])
  func theCarePanesAreDescribed(id: PaneID, title: String, symbol: String) {
    let descriptor = SettingsRegistry.descriptor(for: id)
    #expect(descriptor.id == id)
    #expect(descriptor.title == title)
    #expect(descriptor.symbol == symbol)
  }

  /// Every row draws a glyph and a word; an empty one of either is a blank row
  /// that still selects.
  @Test func everyPaneHasATitleAndASymbol() {
    for pane in SettingsRegistry.panes {
      #expect(!pane.title.isEmpty)
      #expect(!pane.symbol.isEmpty)
    }
  }
}
