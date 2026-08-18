import CandelaKit
import CoreGraphics
import SwiftUI
import Testing

// The words and the rows synthesized sizes put on screen (SS4/SS5/SS9),
// asserted without a window (AT4 layer 1, AT5).
//
// Its own file rather than more cases in `CopyBuilderTests`: that suite's
// em-dash scan enumerates its builders by hand, and this one carries the same
// scan plus the two scans only this feature needs. Nothing here may name a
// refresh rate and nothing here may claim sharpness, and both rules are
// mechanical rather than a review habit.
//
// The reading technique is `CopyBuilderTests`': a `LocalizedStringKey`
// reflects to its KEY plus its arguments as separate values, so an interpolated
// sentence appears as "%@ could not ..." with "Candela" alongside rather than
// spliced in. Assertions on those sentences pin the literal half.
@Suite("Synthesis copy and rows")
@MainActor
struct SynthesisCopyTests {
  private func render(_ key: LocalizedStringKey) -> String { unescaped(String(describing: key)) }

  /// Reflection dumps a literal the way source would spell it, so apostrophes
  /// come back backslash-escaped. Undone once here so an assertion can be
  /// written the way the sentence reads.
  private func unescaped(_ dump: String) -> String {
    dump
      .replacingOccurrences(of: "\\'", with: "'")
      .replacingOccurrences(of: "\\\"", with: "\"")
  }

  private static let emDash = "\u{2014}"

  // MARK: - The strings the brief fixes

  @Test func theOptInRowSaysWhatItAddsAndWhatItCosts() {
    #expect(SynthesisCopy.optInTitle == "More sizes")
    #expect(SynthesisCopy.optInCaption == """
      Adds in-between scaled sizes rendered through a virtual display. \
      The picture may use more memory while one is active.
      """)
  }

  /// The two source marks stay distinguishable (SS5): one marks a mode our
  /// enumeration FOUND, the other a size this app renders.
  @Test func theSynthesizedBadgeIsDistinctFromTheRevealedOne() {
    #expect(SynthesisCopy.badge == "Rendered by Candela")
    #expect(DisplayModeCopy.addedByApp == "Added by Candela")
    #expect(SynthesisCopy.badge != DisplayModeCopy.addedByApp)
  }

  /// "display", never "panel": SO14 retired the word from visible copy while
  /// leaving it in the type vocabulary this property is named from.
  @Test func theRateColumnStatesTheRuleRatherThanAFigure() {
    #expect(SynthesisCopy.keepsPanelRefresh == "Keeps the display's refresh rate")
  }

  /// Pinned through the quoted key rather than by equality: a
  /// `LocalizedStringKey` reflects to the key plus its formatting flags, so
  /// equality would pin the dump's shape instead of the sentence. The quotes on
  /// both ends are what make this exact rather than a prefix match.
  @Test func theHDRRefusalNamesTheOneThingToDo() {
    #expect(render(SynthesisCopy.refusal(.hdrEngaged))
      .contains("\"Turn off HDR to use a synthesized size.\""))
  }

  /// The times sign comes from `DisplayModeCopy.size`, which exists so there is
  /// one spelling of it: a report line a search cannot match against the picker
  /// it was chosen in is a line nobody can follow up.
  @Test func theDiagnosticsLinesCarryTheSizeTheSlotAndTheCount() {
    #expect(
      SynthesisCopy.diagnosticsActive(width: 3096, height: 1296, slot: 4)
        == "Synthesized size active: \(DisplayModeCopy.size(width: 3096, height: 1296)) (virtual display slot 4)")
    #expect(SynthesisCopy.diagnosticsActive(width: 3096, height: 1296, slot: 4)
      == "Synthesized size active: 3096 × 1296 (virtual display slot 4)")
    #expect(SynthesisCopy.diagnosticsOffered(5) == "Synthesized sizes offered: 5")
    #expect(SynthesisCopy.diagnosticsOffered(0) == "Synthesized sizes offered: 0")
  }

  /// The pasted report's mode line while a stop is engaged: the size in force
  /// and the slot, from the engine, with no rate. The readback it replaces is
  /// the virtual master's descriptor under a fabricated mode id [MEASURED
  /// 2026-08-17], so quoting it would name a mode nobody can look up.
  @Test func theReportModeLineNamesTheStopAndItsSlot() {
    #expect(
      SynthesisCopy.reportMode(width: 3096, height: 1296, slot: 5)
        == "3096 × 1296 (synthesized, virtual display slot 5)")
  }

  // MARK: - The four scans

  @Test func noSentenceEmitsAnEmDash() {
    for entry in everyString() {
      #expect(!entry.text.contains(Self.emDash), "\(entry.site) emits an em dash: \(entry.text)")
    }
  }

  /// No copy may name a refresh rate. The mirror preserves whatever the display
  /// was running (measured at 100 Hz), 175 Hz specifically is a prediction, and
  /// the synthesized row's own rate is the 0 sentinel: "0 Hz" is a value no
  /// display runs at.
  @Test func noSentenceNamesARefreshRate() {
    for entry in everyString() {
      #expect(!entry.text.contains("Hz"), "\(entry.site) names a rate: \(entry.text)")
      #expect(!entry.text.lowercased().contains("hertz"), "\(entry.site) names a rate: \(entry.text)")
    }
  }

  /// RM11 and the camera gate: this feature sells size granularity, never
  /// sharpness. Supersampling reads SOFTER on standard-PPI glass, so every word
  /// below would be a claim we measured to be false.
  @Test func noSentenceClaimsSharpness() {
    let forbidden = ["sharp", "crisp", "retina", "hidpi", "full resolution", "quality"]
    for entry in everyString() {
      let text = entry.text.lowercased()
      for word in forbidden {
        #expect(!text.contains(word), "\(entry.site) claims \(word): \(entry.text)")
      }
    }
  }

  /// SO14 over everything this feature can put on screen: hardware is always a
  /// "display". The type vocabulary keeps the word (`keepsPanelRefresh` is still
  /// called that); only the sentences give it up.
  @Test func noSentenceSaysPanel() {
    for entry in everyString() {
      #expect(!entry.text.lowercased().contains("panel"), "\(entry.site) says panel: \(entry.text)")
    }
  }

  /// Positive control for all four scans. Reflection is what carries a
  /// `LocalizedStringKey`'s words into them; if it stopped, every scan above
  /// would pass over sentences it never saw.
  @Test func theScansCanSeeThroughEveryReturnType() {
    #expect(render(SynthesisCopy.refusal(.notOffered)).contains("More sizes"))
    #expect(render(SynthesisCopy.engineFailure(.noFreeSlot)).contains("two displays at once"))
    #expect(SynthesisCopy.badge.contains("Rendered"))

    #expect(render(LocalizedStringKey("planted \(Self.emDash) key")).contains(Self.emDash))
    #expect(render(LocalizedStringKey("planted 60 Hz key")).contains("Hz"))
    #expect(render(LocalizedStringKey("planted sharp key")).contains("sharp"))
    #expect(render(LocalizedStringKey("planted panel key")).lowercased().contains("panel"))

    // A collapse detector: the scans covering three strings would pass while
    // covering almost nothing.
    #expect(everyString().count > 15)
  }

  /// Every refusal is its own sentence. A reason that fell back to a neighbour's
  /// words would be a distinction the type makes and the copy does not.
  @Test func everyRefusalReasonSaysSomethingDifferent() {
    let rendered = Self.everyReason.map { render(SynthesisCopy.refusal($0)) }
    #expect(rendered.allSatisfy { !$0.isEmpty })
    #expect(Set(rendered).count == rendered.count)
  }

  /// The one refusal reachable while the size it is about is on the glass. It
  /// must never claim the size has been withdrawn: the reader can see it.
  @Test func theStaleSizeRefusalNeverClaimsTheSizeIsGone() {
    let text = render(SynthesisCopy.refusal(.sizeNoLongerOffered)).lowercased()
    #expect(!text.contains("no longer"))
    #expect(!text.contains("not offered"))
    #expect(!text.contains("removed"))
  }

  /// The loudest case in the failure enum says what may still be standing and
  /// what clears it. Silence here leaves a virtual display up with no account
  /// of it anywhere a person can read.
  @Test func anIncompleteUnwindSaysWhatIsStillStanding() {
    let text = render(SynthesisCopy.engineFailure(.unwindIncomplete))
    #expect(text.contains("virtual display may still be in place"))
    #expect(text.contains("quitting"))
  }

  private func everyString() -> [(site: String, text: String)] {
    var out: [(site: String, text: String)] = []
    out.append(("optInTitle", SynthesisCopy.optInTitle))
    out.append(("optInCaption", SynthesisCopy.optInCaption))
    out.append(("badge", SynthesisCopy.badge))
    out.append(("keepsPanelRefresh", SynthesisCopy.keepsPanelRefresh))
    out.append(("engagedSizeNotListed", SynthesisCopy.engagedSizeNotListed))
    for reason in Self.everyReason {
      out.append(("refusal(\(reason))", render(SynthesisCopy.refusal(reason))))
    }
    for failure in Self.everyFailure {
      out.append(("engineFailure(\(failure))", render(SynthesisCopy.engineFailure(failure))))
    }
    for (width, height, slot) in [(3096, 1296, 4), (2408, 1008, 5)] {
      out.append((
        "diagnosticsActive(\(width))",
        SynthesisCopy.diagnosticsActive(width: width, height: height, slot: slot)))
      out.append((
        "reportMode(\(width))",
        SynthesisCopy.reportMode(width: width, height: height, slot: slot)))
    }
    for count in [0, 1, 7] {
      out.append(("diagnosticsOffered(\(count))", SynthesisCopy.diagnosticsOffered(count)))
    }
    return out
  }

  /// Spelled out rather than derived: `Refusal.Reason` carries associated
  /// values and cannot be `CaseIterable`, and a scan that silently skipped a
  /// reason is exactly what these tests exist to prevent.
  private static let everyReason: [SynthesisCoordinator.Refusal.Reason] =
    [.builtIn, .hdrEngaged, .notOffered, .sizeNoLongerOffered, .busy]
      + ReconfigurationClaimant.allCases.map { .blocked(by: $0) }
      + everyFailure.map { .engine($0) }

  private static let everyFailure: [SynthesisFailure] = [
    .unavailable, .noFreeSlot, .createFailed(.classFamilyUnavailable),
    .virtualModeNotAchieved, .mirrorRefused, .engageNotAchieved, .notEngaged,
    .unwindIncomplete,
  ]

  // MARK: - The rows a synthesized stop produces

  /// The curated list is the merged one (SS4), so a synthesized stop is a row
  /// in it: marked, and with the rate column stating the rule rather than the
  /// 0 sentinel it carries.
  @Test func aSynthesizedRowIsMarkedAndNamesNoRate() throws {
    let rows = AllModesPage.rows(
      in: SynthesisFixtures.catalog(), listMode: .recommended, rateFilter: nil, expandedSizes: [])

    let synthesized = rows.filter { $0.badge == SynthesisCopy.badge }
    #expect(!synthesized.isEmpty)
    for row in synthesized {
      #expect(row.detail.contains(SynthesisCopy.keepsPanelRefresh))
      #expect(!row.detail.contains("Hz"))
      #expect(row.spoken.contains(SynthesisCopy.keepsPanelRefresh))
      #expect(!row.spoken.contains("hertz"))
      guard case let .mode(mode) = row.kind else {
        Issue.record("a synthesized row applies a mode")
        return
      }
      // The row applies the stop itself, not a published neighbour resolved
      // from its geometry: there is nothing at that size in the display's list.
      #expect(mode.isSynthesized)
    }
  }

  /// The whole picker, not only the marked rows: nothing anywhere in either
  /// list may render the 0 sentinel as a rate.
  @Test func noRowInEitherListRendersZeroHertz() {
    let catalog = SynthesisFixtures.catalog()
    let lists: [(AllModesPage.ListMode, Set<String>)] = [
      (.recommended, []),
      (.all, []),
      (.all, Set(AllModesPage.rowIDs(
        for: .all, in: catalog, rateFilter: nil, expandedSizes: []))),
    ]
    for (listMode, expanded) in lists {
      for row in AllModesPage.rows(
        in: catalog, listMode: listMode, rateFilter: nil, expandedSizes: expanded) {
        #expect(!Self.namesZeroHertz(row.detail), "\(row.id) renders 0 Hz: \(row.detail)")
        #expect(!Self.namesZeroHertz(row.spoken), "\(row.id) speaks 0 hertz: \(row.spoken)")
      }
    }
  }

  /// A ZERO rate, not a rate ENDING in zero. "caps at 60 Hz" contains the
  /// substring and is a perfectly good row, so the digit in front of the zero
  /// is what the question turns on.
  private static func namesZeroHertz(_ text: String) -> Bool {
    text.range(of: "(^|[^0-9])0 (Hz|hertz)", options: .regularExpression) != nil
  }

  /// SS4's All clause. The All list enumerates what the DISPLAY reports, and a
  /// synthesized stop is in no enumeration, so it has no row there and no size
  /// group of its own.
  @Test func theAllListHoldsNoSynthesizedRow() {
    let catalog = SynthesisFixtures.catalog()
    let expanded = Set(AllModesPage.rowIDs(
      for: .all, in: catalog, rateFilter: nil, expandedSizes: []))
    let rows = AllModesPage.rows(
      in: catalog, listMode: .all, rateFilter: nil, expandedSizes: expanded)

    #expect(rows.allSatisfy { $0.badge != SynthesisCopy.badge })
    #expect(rows.allSatisfy { row in
      guard case let .mode(mode) = row.kind else { return true }
      return !mode.isSynthesized
    })
  }

  /// While a stop is engaged the checkmark is on it and on nothing else: the
  /// display's own readback describes the virtual master, so no published row
  /// may claim to be current.
  @Test func theEngagedStopIsTheOnlyCurrentRow() throws {
    let engaged = try #require(SynthesisFixtures.stops.first)
    let rows = AllModesPage.rows(
      in: SynthesisFixtures.catalog(engaged: engaged), listMode: .recommended,
      rateFilter: nil, expandedSizes: [])

    let current = rows.filter(\.isCurrent)
    #expect(current.count == 1)
    #expect(try #require(current.first).title
      == DisplayModeCopy.size(width: engaged.logicalWidth, height: engaged.logicalHeight))
    #expect(try #require(current.first).badge?.contains(SynthesisCopy.badge) == true)
  }

  /// The All list's caption needs BOTH facts, and the second is the one a
  /// reachable state can take away: a size engaged with the opt-in off leaves
  /// the Recommended segment holding no stop either, so pointing at it would
  /// send someone to a list that does not have what the caption promised.
  @Test func theAllListNoticeNeedsARowToPointAt() throws {
    let engaged = try #require(SynthesisFixtures.stops.first)

    #expect(AllModesPage.showsEngagedSizeNotice(
      in: SynthesisFixtures.catalog(engaged: engaged)))
    // Engaged, opted out: the residue state.
    #expect(!AllModesPage.showsEngagedSizeNotice(
      in: SynthesisFixtures.catalog(engaged: engaged, offering: false)))
    // Offered, nothing engaged: an offer is not a state.
    #expect(!AllModesPage.showsEngagedSizeNotice(in: SynthesisFixtures.catalog()))
  }

  /// The menu-bar panel offers stops from `badgedSize` and from nothing else,
  /// so the mark has to be in that label or the panel offers the cost of a
  /// virtual display invisibly.
  @Test func theOneLineLabelTheMenuBarUsesCarriesTheMark() throws {
    let catalog = SynthesisFixtures.catalog()
    let stop = try #require(catalog.rows.first { $0.mode.isSynthesized })

    #expect(catalog.badgedSize(stop.mode).contains(SynthesisCopy.badge))
    #expect(catalog.badgedSize(stop.mode).hasPrefix(DisplayModeCopy.size(stop.mode)))
    #expect(!Self.namesZeroHertz(catalog.badgedSize(stop.mode)))
    // Unchanged for a published row: the mark is about the stop, not about the
    // label.
    let published = try #require(catalog.rows.first { !$0.mode.isSynthesized })
    #expect(!catalog.badgedSize(published.mode).contains(SynthesisCopy.badge))
  }
}

/// A MAG-shaped panel with the real stop ladder on it: the fixtures come from
/// `SyntheticSizeCatalog` rather than being hand-written, so a change to SS3's
/// percentages or to SS2's precedence is visible here rather than pinned to a
/// list this file made up.
@MainActor
private enum SynthesisFixtures {
  static let native = mode(5, 3440, 1440, 3440, 1440, hz: 175, isNative: true)
  static let ultrawide = mode(30, 2560, 1080, 2560, 1080, hz: 60)
  static let panel = [native, ultrawide]

  static let stops = SyntheticSizeCatalog.stops(
    nativeLogicalWidth: 3440, nativeLogicalHeight: 1440,
    existingRows: panel,
    ceilingPixelWidth: VirtualDisplayIdentity.maxPixels.wide,
    ceilingPixelHeight: VirtualDisplayIdentity.maxPixels.high)

  /// `offering: false` is the opted-out shape the coordinator builds when the
  /// pref is off: no stops in the rows and none in `syntheticStops`, which with
  /// `engaged:` set is the reset-residue state (a size on the glass that the
  /// picker no longer offers).
  static func catalog(
    engaged: SyntheticSize? = nil, offering: Bool = true
  ) -> DisplayModeCoordinator.Catalog {
    let published = DisplayModeCatalog.curated(
      panel, nativePixelWidth: 3440, nativePixelHeight: 1440)
    let stops = offering ? stops : []
    return DisplayModeCoordinator.Catalog(
      display: ConfiguredDisplay(
        id: 3,
        identity: DisplayConfigIdentity(vendor: 1, model: 2, serial: 3, isBuiltIn: false),
        name: "Fixture Panel", isBuiltIn: false),
      rows: SyntheticSizeCatalog.merged(
        published: published, stops: stops, nativePixels: (width: 3440, height: 1440)),
      all: panel,
      current: native,
      distinctLogicalSizes: Set(panel.map { "\($0.logicalWidth)x\($0.logicalHeight)" }).count,
      nativePixels: DisplayModeCoordinator.PixelSize(width: 3440, height: 1440),
      withheldForWireTiming: 0,
      density: nil,
      syntheticStops: stops,
      engagedSyntheticSize: engaged)
  }

  private static func mode(
    _ id: Int32, _ logicalWidth: Int, _ logicalHeight: Int,
    _ pixelWidth: Int, _ pixelHeight: Int, hz: Double, isNative: Bool = false
  ) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: logicalWidth, logicalHeight: logicalHeight,
      pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshHz: hz, isNative: isNative)
  }
}
