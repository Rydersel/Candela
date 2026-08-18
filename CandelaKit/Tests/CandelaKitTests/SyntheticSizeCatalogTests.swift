import Foundation
import Testing
@testable import CandelaKit

/// Follows `DisplayModeFixtures.m`'s idiom: the `ioModeID` is derived from the
/// geometry rather than handed out by a counter, since a mutable `static var`
/// is a concurrency error under Swift 6 strict checking and a derived ID keeps
/// failures readable when the arrays get reordered.
private func fixtureRow(
  _ lw: Int, _ lh: Int, hidpi: Bool, native: Bool = false
) -> DisplayMode {
  DisplayMode(
    ioModeID: Int32(truncatingIfNeeded: lw &* 100_003 &+ lh &* 397 &+ 60),
    logicalWidth: lw, logicalHeight: lh,
    pixelWidth: hidpi ? lw * 2 : lw, pixelHeight: hidpi ? lh * 2 : lh,
    refreshHz: 60, isNative: native
  )
}

@Suite struct SyntheticSizeCatalogTests {
  /// The VD ceiling every case here runs against, so a stop that drops drops
  /// for the reason the case is about.
  static let ceiling = (width: 8192, height: 4320)

  @Test func magLadderFillsTheEmptyBand() {
    // native 3440x1440; existing HiDPI rows at 2048x858 and 1920x804
    // (revealed) and 1720x720 (exact 2x)
    let existing = [
      fixtureRow(2048, 858, hidpi: true), fixtureRow(1920, 804, hidpi: true),
      fixtureRow(1720, 720, hidpi: true), fixtureRow(3440, 1440, hidpi: false, native: true),
    ]
    let stops = SyntheticSizeCatalog.stops(
      nativeLogicalWidth: 3440, nativeLogicalHeight: 1440,
      existingRows: existing,
      ceilingPixelWidth: Self.ceiling.width, ceilingPixelHeight: Self.ceiling.height)
    #expect(stops.map(\.percentOfNative) == [95, 90, 85, 80, 75, 70, 65])
    #expect(stops.allSatisfy { $0.logicalWidth % 2 == 0 && $0.logicalHeight % 2 == 0 })
    #expect(stops.contains { $0.logicalWidth == 2580 && $0.logicalHeight == 1080 }) // 75%
  }

  @Test func precedenceDropsWhatRevelationServes() {
    // an existing HiDPI row AT a stop size (within 2%) removes that stop
    let existing = [fixtureRow(2580, 1080, hidpi: true)]
    let stops = SyntheticSizeCatalog.stops(
      nativeLogicalWidth: 3440, nativeLogicalHeight: 1440,
      existingRows: existing,
      ceilingPixelWidth: Self.ceiling.width, ceilingPixelHeight: Self.ceiling.height)
    #expect(!stops.contains { $0.percentOfNative == 75 })
    // Only the served stop goes: its neighbours are 6.7% away, well outside
    // the 2% precedence window.
    #expect(stops.map(\.percentOfNative) == [95, 90, 85, 80, 70, 65])
  }

  @Test func precedenceIgnoresNonHiDPIRows() {
    // The same geometry at 1x is the size revelation did NOT serve: a 1x row
    // is exactly the case synthesis exists for.
    let existing = [fixtureRow(2580, 1080, hidpi: false)]
    let stops = SyntheticSizeCatalog.stops(
      nativeLogicalWidth: 3440, nativeLogicalHeight: 1440,
      existingRows: existing,
      ceilingPixelWidth: Self.ceiling.width, ceilingPixelHeight: Self.ceiling.height)
    #expect(stops.contains { $0.percentOfNative == 75 })
  }

  @Test func precedenceNeedsBothAxesToMatch() {
    // Width lands inside the window, height does not: not the same size, so
    // the stop survives.
    let existing = [fixtureRow(2580, 1440, hidpi: true)]
    let stops = SyntheticSizeCatalog.stops(
      nativeLogicalWidth: 3440, nativeLogicalHeight: 1440,
      existingRows: existing,
      ceilingPixelWidth: Self.ceiling.width, ceilingPixelHeight: Self.ceiling.height)
    #expect(stops.contains { $0.percentOfNative == 75 })
  }

  @Test func ceilingAndFloorDropStops() {
    // 5K panel: 95% stop's fb exceeds 8192x4320 and is dropped
    let fiveK = SyntheticSizeCatalog.stops(
      nativeLogicalWidth: 5120, nativeLogicalHeight: 2880,
      existingRows: [],
      ceilingPixelWidth: Self.ceiling.width, ceilingPixelHeight: Self.ceiling.height)
    #expect(!fiveK.contains { $0.percentOfNative >= 80 })  // 80% of 2880 = 2304, fb 4608 > 4320
    // floor: a small panel where 65% dips under 720 minor axis
    let small = SyntheticSizeCatalog.stops(
      nativeLogicalWidth: 1920, nativeLogicalHeight: 1080,
      existingRows: [],
      ceilingPixelWidth: Self.ceiling.width, ceilingPixelHeight: Self.ceiling.height)
    #expect(small.allSatisfy { $0.logicalHeight >= 720 })
    #expect(small.map(\.percentOfNative) == [95, 90, 85, 80, 75, 70])
  }

  @Test func aStopExactlyAtTheCeilingSurvives() {
    // 75% of 5120x2880 is fb 7680x4320: the height sits ON the ceiling, and
    // the rule drops only what EXCEEDS it.
    let fiveK = SyntheticSizeCatalog.stops(
      nativeLogicalWidth: 5120, nativeLogicalHeight: 2880,
      existingRows: [],
      ceilingPixelWidth: Self.ceiling.width, ceilingPixelHeight: Self.ceiling.height)
    let seventyFive = fiveK.first { $0.percentOfNative == 75 }
    #expect(seventyFive?.pixelWidth == 7680)
    #expect(seventyFive?.pixelHeight == 4320)
  }

  @Test func evenRoundingMatchesTheDensityModelTwin() {
    // The built-in panel's odd minor axis is the rounding case: 1964 scaled by
    // each stop lands on halves and odds, and every result must come back even.
    let stops = SyntheticSizeCatalog.stops(
      nativeLogicalWidth: 3024, nativeLogicalHeight: 1964,
      existingRows: [],
      ceilingPixelWidth: Self.ceiling.width, ceilingPixelHeight: Self.ceiling.height)
    #expect(!stops.isEmpty)
    #expect(stops.allSatisfy { $0.logicalWidth % 2 == 0 && $0.logicalHeight % 2 == 0 })
    // 85% of 1964 is 1669.4, which rounds to the even 1670, not down to 1668.
    #expect(stops.contains { $0.percentOfNative == 85 && $0.logicalHeight == 1670 })
  }

  @Test func rowCarriesSentinelAndProvenance() {
    let s = SyntheticSize(logicalWidth: 2580, logicalHeight: 1080, percentOfNative: 75)
    let row = SyntheticSizeCatalog.row(for: s)
    #expect(row.provenance == .synthesized)
    #expect(row.ioModeID == DisplayMode.syntheticIoModeID(stopIndex: 4))
    #expect(row.pixelWidth == 5160 && row.refreshHz == 0)
    #expect(row.pixelHeight == 2160)
    #expect(row.isNative == false)
    #expect(row.isHiDPI)
  }

  @Test func everyStopGetsADistinctNegativeSentinel() {
    let stops = SyntheticSizeCatalog.stops(
      nativeLogicalWidth: 3440, nativeLogicalHeight: 1440,
      existingRows: [],
      ceilingPixelWidth: Self.ceiling.width, ceilingPixelHeight: Self.ceiling.height)
    let ids = stops.map { SyntheticSizeCatalog.row(for: $0).ioModeID }
    #expect(ids.allSatisfy { $0 < 0 })
    #expect(Set(ids).count == ids.count)
  }

  @Test func anOffLadderPercentStillYieldsANegativeSentinel() {
    // Nothing in the catalog generates a percent outside `stopPercents`, but
    // `row(for:)` is public: a sentinel that came out non-negative would be
    // handed to CoreGraphics as somebody else's mode ID.
    let odd = SyntheticSize(logicalWidth: 3400, logicalHeight: 1424, percentOfNative: 99)
    let id = SyntheticSizeCatalog.row(for: odd).ioModeID
    #expect(id < 0)
    let ladderIDs = SyntheticSizeCatalog.stopPercents.indices.map {
      DisplayMode.syntheticIoModeID(stopIndex: $0)
    }
    #expect(!ladderIDs.contains(id))
  }

  @Test func descriptorRoundTripsAndStaleDescriptorResolvesNil() throws {
    let s = SyntheticSize(logicalWidth: 2580, logicalHeight: 1080, percentOfNative: 75)
    let descriptor = SyntheticSizeDescriptor(logicalWidth: s.logicalWidth,
                                             logicalHeight: s.logicalHeight)
    let data = try JSONEncoder().encode(descriptor)
    let decoded = try JSONDecoder().decode(SyntheticSizeDescriptor.self, from: data)
    #expect(decoded == descriptor)

    let resolved = SyntheticSizeCatalog.size(
      matching: decoded, ofNativeWidth: 3440, nativeHeight: 1440,
      existingRows: [], ceilingPixelWidth: Self.ceiling.width,
      ceilingPixelHeight: Self.ceiling.height)
    #expect(resolved == s)

    // A descriptor the current ladder no longer generates resolves nil rather
    // than snapping to the nearest stop.
    let stale = SyntheticSizeDescriptor(logicalWidth: 3000, logicalHeight: 1000)
    #expect(SyntheticSizeCatalog.size(
      matching: stale, ofNativeWidth: 3440, nativeHeight: 1440,
      existingRows: [], ceilingPixelWidth: Self.ceiling.width,
      ceilingPixelHeight: Self.ceiling.height) == nil)
  }

  @Test func descriptorForAStopPrecedenceNowDropsResolvesNil() {
    // The stored size still generates arithmetically, but an existing HiDPI
    // row has since taken it over, so SS2 removes it from the ladder and the
    // stored choice must stop resolving.
    let descriptor = SyntheticSizeDescriptor(logicalWidth: 2580, logicalHeight: 1080)
    let resolved = SyntheticSizeCatalog.size(
      matching: descriptor, ofNativeWidth: 3440, nativeHeight: 1440,
      existingRows: [fixtureRow(2580, 1080, hidpi: true)],
      ceilingPixelWidth: Self.ceiling.width, ceilingPixelHeight: Self.ceiling.height)
    #expect(resolved == nil)
  }

  @Test func degenerateNativeGeometryProducesNoStops() {
    #expect(SyntheticSizeCatalog.stops(
      nativeLogicalWidth: 0, nativeLogicalHeight: 0, existingRows: [],
      ceilingPixelWidth: Self.ceiling.width,
      ceilingPixelHeight: Self.ceiling.height).isEmpty)
  }
}
