import CandelaKit
import SwiftUI
import Testing

// The Protection pane's two derivations: the startup caption
// that follows the restore picker, and the read-only summary of what
// Remember-size promises on each display.
//
// Both are static functions on the pane rather than computed properties over
// prefs, which is what makes them reachable here: the picker's three options
// are only told apart by their captions, and the summary is the one place in
// the window that describes a pinned size without owning the control.
//
// Copy is read through `String(describing:)` the way `CopyBuilderTests` reads
// it: a `LocalizedStringKey` reflects to its key, which in an unlocalized
// bundle is the sentence itself.
@Suite("Protection pane") @MainActor
struct ProtectionPaneTests {
  /// The key's own sentence, lifted out of the reflection wrapper so an
  /// assertion can be an equality rather than a containment. A dump in any other
  /// shape comes back whole, so a future runtime's spelling fails visibly rather
  /// than as an empty string.
  private func render(_ key: LocalizedStringKey) -> String {
    let dump = String(describing: key)
    guard
      let start = dump.range(of: "key: \""),
      let end = dump.range(of: "\", hasFormatting", range: start.upperBound..<dump.endIndex)
    else { return unescaped(dump) }
    return unescaped(String(dump[start.upperBound..<end.lowerBound]))
  }

  /// Reflection dumps a literal the way source would spell it, so apostrophes
  /// and quotes come back backslash-escaped.
  private func unescaped(_ dump: String) -> String {
    dump
      .replacingOccurrences(of: "\\'", with: "'")
      .replacingOccurrences(of: "\\\"", with: "\"")
  }

  private static let pin = DisplayModeDescriptor(
    logicalWidth: 3440, logicalHeight: 1440,
    pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175
  )

  private static let fractional = DisplayModeDescriptor(
    logicalWidth: 1920, logicalHeight: 1080,
    pixelWidth: 1920, pixelHeight: 1080, refreshHz: 59.9
  )

  // MARK: - The startup caption

  @Test func eachStartupChoiceKeepsItsOwnSentence() {
    #expect(
      render(ProtectionPane.startupCaption(for: .doNothing))
        == "Keeps using the values from last time, and sends them to the display the first time you change something.")
    #expect(
      render(ProtectionPane.startupCaption(for: .write))
        == "Useful when a display forgets its settings while asleep.")
    #expect(
      render(ProtectionPane.startupCaption(for: .read))
        == "Reads brightness, contrast and volume back from the display. Not all hardware answers.")
  }

  /// A caption shared by two options would describe a restore that does not
  /// happen on one of them, which is the whole reason the switch is exhaustive.
  @Test func noTwoChoicesShareACaption() {
    let captions = StartupAction.allCases.map { render(ProtectionPane.startupCaption(for: $0)) }
    #expect(Set(captions).count == StartupAction.allCases.count)
    #expect(captions.allSatisfy { !$0.isEmpty })
  }

  /// The house rules, on the strings this pane can emit: no em dash, and the
  /// hardware is never called a panel.
  @Test func theStartupCaptionsFollowTheCopyRules() {
    for action in StartupAction.allCases {
      let caption = render(ProtectionPane.startupCaption(for: action))
      #expect(!caption.contains("\u{2014}"), "em dash in \(action)'s caption")
      #expect(!caption.lowercased().contains("panel"), "\"panel\" in \(action)'s caption")
    }
  }

  // MARK: - The remembered-size summary

  private func input(
    _ name: String, _ key: String, _ pinned: RememberResolutionRow.PinnedRow
  ) -> ProtectionPane.RememberedSizeInput {
    ProtectionPane.RememberedSizeInput(name: name, persistenceKey: key, pinned: pinned)
  }

  @Test func noDisplaysProduceNoRows() {
    #expect(ProtectionPane.rememberedSizeRows([]).isEmpty)
  }

  /// The three promises, in the words the summary shows them in. `.hidden` is
  /// the one that has to say something: the display's Remember row draws
  /// nothing at all in that state, and a blank value here would read as a
  /// summary that failed to load rather than as remembering being off.
  @Test func eachPromiseIsNamed() {
    #expect(ProtectionPane.value(for: .hidden) == "Off")
    #expect(ProtectionPane.value(for: .empty) == "On, nothing pinned")
    #expect(ProtectionPane.value(for: .pinned(Self.pin)) == "3440 × 1440 · 175 Hz")
  }

  /// A fractional rate survives: 59.9 is a real mode and truncating it would
  /// name a size the display is not pinned to.
  @Test func aFractionalRateIsNotRounded() {
    #expect(ProtectionPane.value(for: .pinned(Self.fractional)) == "1920 × 1080 · 59.9 Hz")
  }

  /// The glyph-packed value gets a spoken form; the two word answers are
  /// already words and stay themselves rather than gaining a second spelling.
  @Test func thePinnedValueIsSpokenAsWords() {
    #expect(
      ProtectionPane.spokenValue(for: .pinned(Self.pin)) == "3,440 by 1,440 at 175 hertz")
    #expect(ProtectionPane.spokenValue(for: .hidden) == ProtectionPane.value(for: .hidden))
    #expect(ProtectionPane.spokenValue(for: .empty) == ProtectionPane.value(for: .empty))
  }

  @Test func aRowCarriesItsDisplaysNameKeyAndPromise() {
    let rows = ProtectionPane.rememberedSizeRows([
      input("MacBook Pro", "builtIn", .empty),
      input("MAG 341C", "mag-1", .pinned(Self.pin)),
      input("DELL U2725QE", "dell-1", .hidden),
    ])
    #expect(rows.map(\.name) == ["MacBook Pro", "MAG 341C", "DELL U2725QE"])
    #expect(rows.map(\.persistenceKey) == ["builtIn", "mag-1", "dell-1"])
    #expect(rows.map(\.value) == ["On, nothing pinned", "3440 × 1440 · 175 Hz", "Off"])
  }

  /// Order is the caller's, never sorted here: the pane hands the built-in
  /// first and then the externals in the order the sidebar lists them, and a
  /// summary that re-sorted would put the rows in a different order than the
  /// sidebar rows they navigate to.
  @Test func theCallersOrderIsKept() {
    let keys = ["dell-1", "builtIn", "mag-1"]
    let rows = ProtectionPane.rememberedSizeRows(keys.map { input($0, $0, .hidden) })
    #expect(rows.map(\.persistenceKey) == keys)
  }

  /// Two panels of the same model share one persistence key, so the name and
  /// the row identity both need the sidebar's ordinal. Without it the list
  /// shows one name twice and a `ForEach` over the duplicate id hands the old
  /// view instance to the other display's row.
  @Test func twoDisplaysSharingAKeyAreNumberedTheWayTheSidebarNumbersThem() {
    let rows = ProtectionPane.rememberedSizeRows([
      input("MAG 341C", "mag", .pinned(Self.pin)),
      input("MAG 341C", "mag", .hidden),
    ])
    #expect(rows.map(\.name) == ["MAG 341C (1)", "MAG 341C (2)"])
    #expect(Set(rows.map(\.id)).count == 2)
    // The ordinal never reaches the destination: both rows navigate to the one
    // page that key resolves to.
    #expect(rows.allSatisfy { $0.persistenceKey == "mag" })
  }

  /// A display with a key of its own keeps its bare name: numbering every row
  /// would put a "(1)" beside a display there is only one of.
  @Test func aSoleDisplayIsNotNumbered() {
    let rows = ProtectionPane.rememberedSizeRows([input("MAG 341C", "mag", .hidden)])
    #expect(rows.map(\.name) == ["MAG 341C"])
    #expect(rows.map(\.id) == ["mag"])
  }

  // MARK: - The page itself

  /// Layer 2. The fixture model has no displays, so this covers the page
  /// with the restore picker on it and the summary in its empty state, which is
  /// what a Mac with nothing attached opens on.
  @Test func thePageRendersWithNoDisplaysAttached() {
    let model = TestFixtures.appModel()
    let pane = ProtectionPane()
      .environment(model)
      .environment(SettingsActions(model: model))
      .environment(\.settingsAccent, .display(isBuiltIn: false, ordinal: 0))
      .frame(width: SettingsTheme.pageWidth + 64, height: 520)
    let image = ImageRenderer(content: pane).cgImage
    #expect(image != nil, "ProtectionPane produced no image")
    #expect((image?.width ?? 0) > 20)
    #expect((image?.height ?? 0) > 20)
  }

  @Test func theSummaryValuesFollowTheCopyRules() {
    let promises: [RememberResolutionRow.PinnedRow] = [
      .hidden, .empty, .pinned(Self.pin), .pinned(Self.fractional),
    ]
    for promise in promises {
      for text in [ProtectionPane.value(for: promise), ProtectionPane.spokenValue(for: promise)] {
        #expect(!text.contains("\u{2014}"), "em dash in \(text)")
        #expect(!text.lowercased().contains("panel"), "\"panel\" in \(text)")
      }
    }
  }
}
