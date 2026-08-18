import Foundation
import Testing
@testable import CandelaKit

/// `SyntheticSizeCatalogTests`' idiom: the id is derived from the geometry
/// rather than handed out by a counter.
private func publishedRow(_ lw: Int, _ lh: Int, hidpi: Bool = true) -> DisplayModeRow {
  DisplayModeRow(
    mode: DisplayMode(
      ioModeID: Int32(truncatingIfNeeded: lw &* 100_003 &+ lh &* 397 &+ 60),
      logicalWidth: lw, logicalHeight: lh,
      pixelWidth: hidpi ? lw * 2 : lw, pixelHeight: hidpi ? lh * 2 : lh,
      refreshHz: 60, isNative: false
    ),
    isScaled: true
  )
}

@Suite struct SyntheticRowMergeTests {
  static let native = (width: 3440, height: 1440)

  @Test func noStopsLeavesThePublishedListExactlyAsItWas() {
    let published = [publishedRow(3440, 1440), publishedRow(1720, 720)]
    let merged = SyntheticSizeCatalog.merged(
      published: published, stops: [], nativePixels: Self.native
    )
    #expect(merged == published)
  }

  @Test func stopsSortIntoTheAreaOrderTheCuratedListUses() {
    let published = [publishedRow(3440, 1440), publishedRow(1720, 720)]
    let stops = [
      SyntheticSize(logicalWidth: 3268, logicalHeight: 1368, percentOfNative: 95),
      SyntheticSize(logicalWidth: 2236, logicalHeight: 936, percentOfNative: 65),
    ]
    let merged = SyntheticSizeCatalog.merged(
      published: published, stops: stops, nativePixels: Self.native
    )
    #expect(merged.map(\.mode.logicalWidth) == [3440, 3268, 2236, 1720])
    // Descending logical area, which is `DisplayModeCatalog.curated`'s order.
    let areas: [Int] = merged.map { $0.mode.logicalWidth * $0.mode.logicalHeight }
    #expect(areas == areas.sorted(by: >))
  }

  /// The reason this function exists rather than a bare `+` and the catalog's
  /// own comparator: a synthesized row's sentinel id is negative, so an
  /// id-ascending tie-break would put it in FRONT of the published row it
  /// doubles.
  @Test func aSynthesizedRowSortsAfterAPublishedRowOfTheSameSize() {
    let published = [publishedRow(2580, 1080)]
    let stops = [SyntheticSize(logicalWidth: 2580, logicalHeight: 1080, percentOfNative: 75)]
    let merged = SyntheticSizeCatalog.merged(
      published: published, stops: stops, nativePixels: Self.native
    )
    #expect(merged.count == 2)
    #expect(merged[0].mode.isSynthesized == false)
    #expect(merged[1].mode.isSynthesized)
  }

  @Test func aSynthesizedRowCarriesTheProvenanceAndTheSentinelID() {
    let stops = [SyntheticSize(logicalWidth: 3268, logicalHeight: 1368, percentOfNative: 95)]
    let merged = SyntheticSizeCatalog.merged(
      published: [], stops: stops, nativePixels: Self.native
    )
    #expect(merged.count == 1)
    #expect(merged[0].mode.provenance == .synthesized)
    #expect(merged[0].mode.ioModeID < 0)
    // 2x by construction, which is what the virtual display is minted at.
    #expect(merged[0].mode.pixelWidth == 6536 && merged[0].mode.pixelHeight == 2736)
  }

  @Test func scaledIsJudgedAgainstThePanelAndSuppressedWithoutIt() {
    let stops = [SyntheticSize(logicalWidth: 3268, logicalHeight: 1368, percentOfNative: 95)]
    #expect(SyntheticSizeCatalog.merged(
      published: [], stops: stops, nativePixels: Self.native
    )[0].isScaled)
    // No native geometry means no judgement rather than one against zeros.
    #expect(SyntheticSizeCatalog.merged(
      published: [], stops: stops, nativePixels: nil
    )[0].isScaled == false)
  }
}
