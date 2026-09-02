import CandelaKit
import CoreGraphics
import Testing

// The Size pop-up's derivation, over a BUILT-IN shaped catalog.
//
// These rows are shared by the external hub and the built-in display's page,
// and the built-in is the shape nothing covered: a high-PPI panel whose whole
// ladder is scaled, whose physical size is never filed (it does not pass
// through display discovery, so the density model abstains and no size is ever
// recommended), and which the refresh-rate pair 59.9 / 60.0 is real on.
//
// The defect worth catching here is a mark that appears where it must not.
// "Recommended" over an abstaining model and "Rendered by Candela" over a
// panel the exclusion rule excludes would both be the app claiming
// something it has not decided, and neither is visible to a Kit test: the
// catalog is honest in both cases and only the label builder can invent them.
@Suite("Resolution rows") @MainActor
struct ResolutionRowTests {
  // MARK: - Size labels

  /// The ordinary case, and the one most rows on a laptop panel take: a size,
  /// and nothing else. The tags that name the mode's kind belong to the All
  /// Sizes page, which is where the duplicates that need telling apart are.
  @Test func aSizeIsNamedWithNothingAppended() throws {
    let catalog = BuiltInFixtures.catalog()
    let row = try #require(catalog.rows.first { $0.mode.logicalWidth == 1800 })
    #expect(DisplaySizeRows.sizeItemLabel(row, in: catalog) == "1800 × 1169")
  }

  /// The size macOS itself calls Default (the looks-like size whose
  /// framebuffer IS the panel) says so, in System Settings' own word. It is
  /// the built-in's counterpart to Recommended, which this panel can never
  /// carry because no physical size is ever filed for it.
  @Test func theDefaultSizeIsMarkedOnTheBuiltIn() throws {
    let catalog = BuiltInFixtures.catalog()
    let row = try #require(catalog.rows.first { $0.mode.logicalWidth == 1512 })
    #expect(
      DisplaySizeRows.sizeItemLabel(row, in: catalog)
        == "1512 × 982 (\(DisplayModeCopy.defaultSize))")
  }

  /// The trap the gate exists for, pinned with the exact geometry that springs
  /// it: on a standard-PPI external the native flag rides the HiDPI twin
  /// (logical 1720 x 720 on a 3440 x 1440 panel), which is NOT what System
  /// Settings calls Default there. An ungated rule would badge that row
  /// confidently; no row on an external may carry the word.
  @Test func anExternalNeverCarriesTheDefaultMark() {
    let catalog = BuiltInFixtures.externalWithNativeFlagOnTheHiDPITwin()
    let marked = catalog.rows.filter {
      DisplaySizeRows.sizeItemLabel($0, in: catalog).contains(DisplayModeCopy.defaultSize)
    }
    #expect(marked.isEmpty)
    // The control: the twin IS in the rows this asked about, so the emptiness
    // is the gate holding rather than curation having dropped the row.
    #expect(catalog.rows.contains { $0.mode.logicalWidth == 1720 })
  }

  /// The one mark this pop-up owes the reader on a laptop panel: choosing a
  /// size whose fastest mode is slower than the rate now in use costs refresh,
  /// and the cost belongs where the choice is made.
  @Test func aSizeThatWouldLowerTheRefreshRateSaysSo() throws {
    let catalog = BuiltInFixtures.catalog()
    let row = try #require(catalog.rows.first { $0.mode.logicalWidth == 1024 })
    #expect(DisplaySizeRows.sizeItemLabel(row, in: catalog) == "1024 × 665 (caps at 60 Hz)")
  }

  /// The control for the test above: the warning is a comparison against the
  /// running rate, not a property of the row, so a display already at 60 Hz has
  /// nothing to be warned about and the same row loses the mark.
  @Test func theSameSizeCarriesNoWarningWhenTheDisplayIsAlreadyAtThatRate() throws {
    let catalog = BuiltInFixtures.catalog(current: BuiltInFixtures.slowLadderRung)
    let row = try #require(catalog.rows.first { $0.mode.logicalWidth == 1024 })
    #expect(DisplaySizeRows.sizeItemLabel(row, in: catalog) == "1024 × 665")
  }

  /// A panel with no filed physical size gets no recommendation, which is the
  /// built-in's permanent state: it never reaches `hardwareFacts`, so the
  /// density model abstains. Nothing may wear the mark in that state.
  @Test func nothingIsRecommendedWithoutADensityVerdict() {
    let catalog = BuiltInFixtures.catalog()
    let marked = catalog.rows.filter {
      DisplaySizeRows.sizeItemLabel($0, in: catalog).contains(DisplayModeCopy.recommended)
    }
    #expect(marked.isEmpty)
  }

  /// The control for the test above: the same builder over the same rows DOES
  /// mark a size once a verdict names one, so the emptiness asserted there is
  /// about the verdict rather than about the label builder being inert.
  @Test func aRecommendedSizeIsMarkedWhenTheModelNamesOne() throws {
    // 1800, not 1512: the fixture fakes a density verdict onto a built-in
    // catalog, and 1512 is the Default size, so recommending it would test the
    // two marks' concatenation instead of the verdict. In production the two
    // are exclusive by construction (Recommended needs a density verdict,
    // which only discovery-visible externals get; Default needs isBuiltIn).
    let catalog = BuiltInFixtures.catalog(recommending: (width: 1800, height: 1169))
    let row = try #require(catalog.rows.first { $0.mode.logicalWidth == 1800 })
    #expect(
      DisplaySizeRows.sizeItemLabel(row, in: catalog)
        == "1800 × 1169 (\(DisplayModeCopy.recommended))")
  }

  /// The exclusion rule keeps synthesized stops away from the built-in, and
  /// the catalog carries none for it. The badge is the visible half of that
  /// rule.
  @Test func noRowOnTheBuiltInIsMarkedAsRendered() {
    let catalog = BuiltInFixtures.catalog()
    #expect(catalog.syntheticStops.isEmpty)
    let rendered = catalog.rows.filter {
      DisplaySizeRows.sizeItemLabel($0, in: catalog).contains(SynthesisCopy.badge)
    }
    #expect(rendered.isEmpty)
  }

  // MARK: - Which row is selected

  @Test func theRunningSizeIsTheSelectedRow() throws {
    let catalog = BuiltInFixtures.catalog()
    let selected = try #require(DisplaySizeRows.curatedSelection(in: catalog))
    let row = try #require(catalog.rows.first { $0.id == selected })
    #expect(row.mode.logicalWidth == 1512)
  }

  /// By SIZE, never by mode id: the row's representative is that size's FASTEST
  /// mode, so a display sitting at the same size's slower rate would otherwise
  /// select nothing and the pop-up would grow a duplicate item naming the size
  /// it is already showing.
  @Test func aSlowerRateAtTheSameSizeStillSelectsThatSizesRow() throws {
    let catalog = BuiltInFixtures.catalog(current: BuiltInFixtures.defaultRungAtNTSC)
    let selected = try #require(DisplaySizeRows.curatedSelection(in: catalog))
    let row = try #require(catalog.rows.first { $0.id == selected })
    #expect(row.mode.logicalWidth == 1512)
  }

  /// The state that puts an extra item in the menu: something outside this app
  /// left the display on a size the curation floor drops, so no curated row is
  /// current and the pop-up has to name the running mode itself.
  @Test func aSizeNobodyCuratedSelectsNoRow() {
    let catalog = BuiltInFixtures.catalog(current: BuiltInFixtures.tiny)
    #expect(DisplaySizeRows.curatedSelection(in: catalog) == nil)
  }
}

/// A catalog shaped like the MacBook's own panel: a 3024x1964 native
/// framebuffer, a scaled ladder above it, and the 59.9/60.0 pair that makes
/// refresh-rate quantization a real question rather than float noise.
private enum BuiltInFixtures {
  static let native = mode(1, 1512, 982, 3024, 1964, hz: 120, isNative: true)
  static let defaultRung = mode(2, 1512, 982, 3024, 1964, hz: 120)
  /// Same size, NTSC's genuine rate. Quantization has to keep it apart from 60.
  static let defaultRungAtNTSC = mode(3, 1512, 982, 3024, 1964, hz: 59.9)
  static let larger = mode(4, 1800, 1169, 3600, 2338, hz: 120)
  static let largest = mode(5, 2056, 1329, 4112, 2658, hz: 120)
  /// The rung whose fastest mode cannot hold 120 Hz, which is what the caps
  /// warning is about.
  static let slowLadderRung = mode(6, 1024, 665, 2048, 1330, hz: 60)
  /// Under the usability floor (0.33 of the 1964-pixel minor axis is 648), so
  /// curation drops it and a display running it matches no row.
  static let tiny = mode(7, 640, 400, 1280, 800, hz: 60)

  static let panel = [native, defaultRung, defaultRungAtNTSC, larger, largest, slowLadderRung, tiny]

  static func catalog(
    current: DisplayMode = defaultRung,
    recommending: (width: Int, height: Int)? = nil
  ) -> DisplayModeCoordinator.Catalog {
    let suggestion = recommending.map {
      SizeRecommendation(logicalWidth: $0.width, logicalHeight: $0.height, looksLikePPI: 120)
    }
    return DisplayModeCoordinator.Catalog(
      display: ConfiguredDisplay(
        id: 1,
        identity: DisplayConfigIdentity(vendor: 0, model: 0, serial: 0, isBuiltIn: true),
        name: "Built-in Display", isBuiltIn: true),
      // The real curation, never a hand-written row list: the representative
      // choice per size is exactly what a label is asked about.
      rows: DisplayModeCatalog.curated(panel, nativePixelWidth: 3024, nativePixelHeight: 1964),
      all: panel,
      current: current,
      distinctLogicalSizes: Set(panel.map { "\($0.logicalWidth)x\($0.logicalHeight)" }).count,
      nativePixels: DisplayModeCoordinator.PixelSize(width: 3024, height: 1964),
      withheldForWireTiming: 0,
      density: suggestion.map {
        DensityVerdict(
          recommendation: $0, abstention: nil, bestInBand: $0, ideal: nil,
          currentPlacement: nil)
      })
  }

  /// The external whose geometry springs the default-mark trap: the native
  /// flag on the HiDPI twin of the panel's own size, exactly as the MAG
  /// publishes it.
  static func externalWithNativeFlagOnTheHiDPITwin() -> DisplayModeCoordinator.Catalog {
    let twin = mode(10, 1720, 720, 3440, 1440, hz: 175, isNative: true)
    let panelSize = mode(11, 3440, 1440, 3440, 1440, hz: 175)
    let all = [twin, panelSize]
    return DisplayModeCoordinator.Catalog(
      display: ConfiguredDisplay(
        id: 2,
        identity: DisplayConfigIdentity(vendor: 0x3669, model: 0x3DD0, serial: 0, isBuiltIn: false),
        name: "MAG 341C OLED", isBuiltIn: false),
      rows: DisplayModeCatalog.curated(all, nativePixelWidth: 3440, nativePixelHeight: 1440),
      all: all,
      current: panelSize,
      distinctLogicalSizes: 2,
      nativePixels: DisplayModeCoordinator.PixelSize(width: 3440, height: 1440),
      withheldForWireTiming: 0,
      density: nil)
  }

  private static func mode(
    _ id: Int32, _ logicalWidth: Int, _ logicalHeight: Int,
    _ pixelWidth: Int, _ pixelHeight: Int, hz: Double, isNative: Bool = false
  ) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: logicalWidth, logicalHeight: logicalHeight,
      pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshHz: hz,
      isNative: isNative, provenance: .coreGraphics)
  }
}
