import CandelaKit
import CoreGraphics
import Testing

// Rows for All Sizes & Refresh Rates, derived from a catalog and asserted
// without a window.
//
// The defect this exists to catch: enumeration and apply both worked and the
// Kit suite was green, yet not one row in the picker was a revealed mode. Every
// revealed mode shares a logical size with a CoreGraphics 1x mode and the
// CoreGraphics id is always the lower one, so a representative chosen on lowest
// id handed every size group to the blurry twin. The fixtures below carry that
// collision.
@Suite("All modes rows") @MainActor
struct AllModesRowTests {
  // MARK: - The revelation shape

  @Test func aRevealedModeRepresentsItsSizeInTheCuratedList() throws {
    let rows = AllModesPage.rows(
      in: ModeFixtures.catalog(), listMode: .recommended, rateFilter: nil, expandedSizes: [])

    // One row per size, largest first, and the collision size resolves to the
    // revealed mode rather than its 1x twin.
    #expect(rows.map(\.id) == ["mode-5", "mode-30", "mode-101"])

    let collision = try #require(rows.first { $0.title == "1920 × 804" })
    #expect(collision.kind == .mode(ModeFixtures.revealed1920))
    #expect(collision.badge == DisplayModeCopy.addedByApp)
    #expect(collision.detail == "175 Hz · Scaled")
  }

  /// Provenance has to reach both the row's mark and the mode a press applies.
  /// A row that looks right and applies the 1x twin is the defect one layer down.
  @Test func provenanceReachesBothTheMarkAndTheAppliedMode() throws {
    let rows = AllModesPage.rows(
      in: ModeFixtures.catalog(), listMode: .recommended, rateFilter: nil, expandedSizes: [])

    let marked = rows.filter { $0.badge == DisplayModeCopy.addedByApp }
    #expect(marked.count == 1)

    guard case let .mode(applied) = try #require(marked.first).kind else {
      Issue.record("a curated row applies a mode")
      return
    }
    #expect(applied.provenance == .coreGraphicsServices)
    #expect(applied.isRevealed)
  }

  /// Control for the two tests above: feed the derivation the rows a lowest-id
  /// tie-break produced, the state the picker shipped in, and they flip.
  @Test func aSizeGroupLostToItsBlurryTwinLosesTheMarkAndTheMode() throws {
    let regressed = ModeFixtures.catalog(
      curating: [DisplayModeRow(mode: ModeFixtures.blurry1920, isScaled: true)])
    let rows = AllModesPage.rows(
      in: regressed, listMode: .recommended, rateFilter: nil, expandedSizes: [])

    let collision = try #require(rows.first { $0.title == "1920 × 804" })
    #expect(collision.badge == nil)
    #expect(collision.kind == .mode(ModeFixtures.blurry1920))
  }

  /// The full list holds both twins, and only there is the pair distinguished:
  /// the 1x mode is tagged, the revealed one is marked.
  @Test func theFullListShowsBothTwinsAndTellsThemApart() throws {
    let rows = AllModesPage.rows(
      in: ModeFixtures.catalog(), listMode: .all, rateFilter: nil,
      expandedSizes: [ModeFixtures.collisionSizeID])

    #expect(rows.map(\.id) == [
      "3440 × 1440", "2560 × 1080", "1920 × 804", "mode-20", "mode-101",
    ])

    let blurry = try #require(rows.first { $0.id == "mode-20" })
    #expect(blurry.detail == "175 Hz · Scaled · low resolution")
    #expect(blurry.badge == nil)

    let revealed = try #require(rows.first { $0.id == "mode-101" })
    #expect(revealed.detail == "175 Hz · Scaled")
    #expect(revealed.badge == DisplayModeCopy.addedByApp)
    // The rate rides inside the size clause here, unlike a curated row, which
    // speaks the size alone and then what pressing it would apply.
    #expect(revealed.spoken == "1,920 by 804 at 175 hertz, Scaled, Added by Candela")
  }

  /// A low-resolution twin never wears the density model's mark, and the
  /// revealed mode at the same size wears both marks with Recommended leading.
  @Test func theRecommendedMarkSkipsTheLowResolutionTwin() throws {
    let catalog = ModeFixtures.catalog(recommending: (1920, 804))
    let rows = AllModesPage.rows(
      in: catalog, listMode: .all, rateFilter: nil,
      expandedSizes: [ModeFixtures.collisionSizeID])

    #expect(try #require(rows.first { $0.id == "mode-20" }).badge == nil)
    #expect(
      try #require(rows.first { $0.id == "mode-101" }).badge
        == "\(DisplayModeCopy.recommended), \(DisplayModeCopy.addedByApp)")
  }

  // MARK: - Grouping and ordering

  @Test func sizesAreCollapsedByDefaultAndOrderedLargestFirst() {
    let rows = AllModesPage.rows(
      in: ModeFixtures.catalog(), listMode: .all, rateFilter: nil, expandedSizes: [])

    #expect(rows.map(\.id) == ["3440 × 1440", "2560 × 1080", "1920 × 804"])
    #expect(rows.allSatisfy { $0.kind == .size(header: $0.title) })
  }

  @Test func aSizeRowStatesItsFastestRateAndItsOpenState() throws {
    let rows = AllModesPage.rows(
      in: ModeFixtures.catalog(), listMode: .all, rateFilter: nil,
      expandedSizes: [ModeFixtures.collisionSizeID])

    let native = try #require(rows.first { $0.id == "3440 × 1440" })
    #expect(native.detail == "up to 175 Hz")
    // The size the display is running carries the checkmark even while shut.
    #expect(native.isCurrent)
    #expect(native.chevronExpanded == false)
    #expect(native.spokenValue == "Collapsed")

    let opened = try #require(rows.first { $0.id == "1920 × 804" })
    #expect(opened.isCurrent == false)
    #expect(opened.chevronExpanded == true)
    #expect(opened.spokenValue == "Expanded")
  }

  /// A rate filter drops the sizes it empties and opens the ones it keeps, so
  /// the answer is on screen rather than behind thirty closed doors.
  @Test func aRateFilterDropsEmptySizesAndOpensTheRest() throws {
    let rows = AllModesPage.rows(
      in: ModeFixtures.catalog(), listMode: .all, rateFilter: 175, expandedSizes: [])

    #expect(rows.map(\.id) == ["3440 × 1440", "mode-5", "1920 × 804", "mode-20", "mode-101"])
    // Only the surviving rates count towards the size row's summary.
    #expect(try #require(rows.first { $0.id == "3440 × 1440" }).detail == "up to 175 Hz")
  }

  /// The curated list states what a press DOES: the size at the rate the
  /// display is already running, and a warning when the size cannot hold it.
  @Test func aCuratedRowWarnsWhenTheSizeCapsTheCurrentRate() throws {
    let rows = AllModesPage.rows(
      in: ModeFixtures.catalog(), listMode: .recommended, rateFilter: nil, expandedSizes: [])

    let capped = try #require(rows.first { $0.id == "mode-30" })
    #expect(capped.detail == "caps at 60 Hz · Scaled")

    let current = try #require(rows.first { $0.id == "mode-5" })
    #expect(current.detail == "175 Hz · Native")
    #expect(current.isCurrent)
  }

  /// The arrow keys, the rotor and the scroll heuristic walk a second, id-only
  /// derivation of this ordering. It has to agree with the rows the list draws.
  @Test func theIdOnlyOrderMatchesTheRowsTheListDraws() {
    let catalog = ModeFixtures.catalog()
    let states: [(AllModesPage.ListMode, Double?, Set<String>)] = [
      (.recommended, nil, []),
      (.all, nil, []),
      (.all, nil, [ModeFixtures.collisionSizeID]),
      (.all, 175, []),
    ]

    for (listMode, rateFilter, expanded) in states {
      let derived = AllModesPage.rows(
        in: catalog, listMode: listMode, rateFilter: rateFilter, expandedSizes: expanded)
      let ids = AllModesPage.rowIDs(
        for: listMode, in: catalog, rateFilter: rateFilter, expandedSizes: expanded)
      #expect(derived.map(\.id) == ids)
    }
  }

  // MARK: - Duplicates

  /// PINNED AS-IS, imperfections included. Two modes with the same size,
  /// framebuffer and rate draw two full-list rows a reader cannot tell apart;
  /// only the row id and the mode a press applies differ. The curated list keeps
  /// the lower `ioModeID` because every earlier tie-break has already tied.
  @Test func duplicateGeometryAndRateRowsAreNotDeduplicated() throws {
    let catalog = ModeFixtures.duplicateCatalog()
    let size = AllModesPage.RowID.size(width: 1280, height: 536)

    let full = AllModesPage.rows(
      in: catalog, listMode: .all, rateFilter: nil, expandedSizes: [size])
    #expect(full.map(\.id) == ["3440 × 1440", size, "mode-40", "mode-41"])

    let twins = full.filter { $0.id.hasPrefix("mode-4") }
    #expect(twins.count == 2)
    #expect(twins[0].title == twins[1].title)
    #expect(twins[0].detail == twins[1].detail)
    #expect(twins[0].badge == twins[1].badge)
    #expect(twins[0].spoken == twins[1].spoken)

    let curated = AllModesPage.rows(
      in: catalog, listMode: .recommended, rateFilter: nil, expandedSizes: [])
    #expect(curated.map(\.id) == ["mode-5", "mode-40"])
  }
}

/// A MAG-shaped panel carrying the collision the revelation defect turned on:
/// one logical size at 1x from CoreGraphics and at 2x from our own enumeration,
/// with the CoreGraphics id the lower.
@MainActor
private enum ModeFixtures {
  static let native = mode(5, 3440, 1440, 3440, 1440, hz: 175, isNative: true)
  static let nativeSlower = mode(8, 3440, 1440, 3440, 1440, hz: 120)
  static let ultrawide = mode(30, 2560, 1080, 2560, 1080, hz: 60)
  static let blurry1920 = mode(20, 1920, 804, 1920, 804, hz: 175)
  static let revealed1920 = mode(
    101, 1920, 804, 3840, 1608, hz: 175, provenance: .coreGraphicsServices)

  /// Same geometry, same rate, two ids: the one shape the full list cannot
  /// tell apart.
  static let duplicateLower = mode(40, 1280, 536, 2560, 1072, hz: 175)
  static let duplicateHigher = mode(41, 1280, 536, 2560, 1072, hz: 175)

  static let collisionSizeID = AllModesPage.RowID.size(width: 1920, height: 804)

  static let panel = [native, nativeSlower, ultrawide, blurry1920, revealed1920]

  static func catalog(
    recommending: (width: Int, height: Int)? = nil, curating rows: [DisplayModeRow]? = nil
  ) -> DisplayModeCoordinator.Catalog {
    catalog(modes: panel, recommending: recommending, rows: rows)
  }

  static func duplicateCatalog() -> DisplayModeCoordinator.Catalog {
    catalog(modes: [native, duplicateLower, duplicateHigher], recommending: nil, rows: nil)
  }

  /// Curated rows come from the real `DisplayModeCatalog` unless a test supplies
  /// its own: the representative choice is where the defect was, so a fixture
  /// that always supplied rows would assert on nothing.
  private static func catalog(
    modes: [DisplayMode], recommending: (width: Int, height: Int)?, rows: [DisplayModeRow]?
  ) -> DisplayModeCoordinator.Catalog {
    let sizes = Set(modes.map { "\($0.logicalWidth)x\($0.logicalHeight)" })
    let suggestion = recommending.map {
      SizeRecommendation(logicalWidth: $0.width, logicalHeight: $0.height, looksLikePPI: 100)
    }
    return DisplayModeCoordinator.Catalog(
      display: ConfiguredDisplay(
        id: 3,
        identity: DisplayConfigIdentity(vendor: 1, model: 2, serial: 3, isBuiltIn: false),
        name: "Fixture Panel", isBuiltIn: false),
      rows: rows
        ?? DisplayModeCatalog.curated(modes, nativePixelWidth: 3440, nativePixelHeight: 1440),
      all: modes,
      current: native,
      distinctLogicalSizes: sizes.count,
      nativePixels: DisplayModeCoordinator.PixelSize(width: 3440, height: 1440),
      withheldForWireTiming: 0,
      density: suggestion.map {
        DensityVerdict(
          recommendation: $0, abstention: nil, bestInBand: $0, ideal: nil,
          currentPlacement: nil)
      })
  }

  private static func mode(
    _ id: Int32, _ logicalWidth: Int, _ logicalHeight: Int,
    _ pixelWidth: Int, _ pixelHeight: Int, hz: Double, isNative: Bool = false,
    provenance: ModeProvenance = .coreGraphics
  ) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: logicalWidth, logicalHeight: logicalHeight,
      pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshHz: hz,
      isNative: isNative, provenance: provenance)
  }
}
