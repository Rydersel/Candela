import CoreGraphics
import SwiftUI
import Testing

// The arithmetic behind the two setup pages that draw one item per display,
// checked without laying a view out. The render suite cannot see a clip at all,
// so the fit a wide rig needs is asserted here or nowhere.
@Suite("Onboarding layout")
struct OnboardingLayoutTests {
  /// The setup window is 760 wide and the glyph row sits inside the page's
  /// 30 pt gutter, so this is what the panels have to fit into.
  private static let availableWidth: CGFloat = 700
  /// The two heights the glyph row draws at: mid-scan, then cards shown.
  private static let scanHeight: CGFloat = 150
  private static let cardsShownHeight: CGFloat = 110
  /// The spacing the row has always drawn at.
  private static let restingSpacing: CGFloat = 34

  /// The whole table, because the table is the decision: three across is the
  /// widest readable row, and a fourth card wraps two by two rather than
  /// stranding one.
  @Test func theColumnCountWrapsFourCardsTwoByTwo() {
    #expect((1...8).map(OnboardingCardGrid.columns(for:)) == [1, 2, 3, 2, 3, 3, 3, 3])
  }

  /// A row of one or two draws where it always has only because every column
  /// carries the page's card cap. A bare `.flexible()` maxes at `.infinity`, so
  /// one card would stretch the whole content width, which no render test sees.
  @Test func everyCardColumnCarriesThePagesCardWidthCap() {
    let cap: CGFloat = 300
    for count in 1...8 {
      let columns = OnboardingCardGrid.gridColumns(for: count, maxCardWidth: cap)
      #expect(columns.count == OnboardingCardGrid.columns(for: count), "\(count)")
      for column in columns {
        guard case .flexible(_, let maximum) = column.size else {
          Issue.record("a column for \(count) cards is not flexible")
          continue
        }
        #expect(maximum == cap, "\(count)")
      }
    }
  }

  /// The defect as arithmetic: four ultrawide panels at a fixed height and
  /// spacing ask for more width than the window has, and the clip swallows the
  /// outer ones.
  @Test func theGlyphRowFitsFourUltrawidePanelsInTheWindow() {
    let aspects = [CGFloat](repeating: 2.39, count: 4)
    // The positive control. Without it the fit below could be passing against
    // a row that never overflowed in the first place.
    #expect(
      OnboardingCardGrid.totalWidth(
        height: Self.cardsShownHeight, spacing: Self.restingSpacing, aspects: aspects)
        > Self.availableWidth)

    let metrics = OnboardingCardGrid.glyphMetrics(
      aspects: aspects, availableWidth: Self.availableWidth, baseHeight: Self.cardsShownHeight)
    #expect(
      OnboardingCardGrid.totalWidth(
        height: metrics.height, spacing: metrics.spacing, aspects: aspects)
        <= Self.availableWidth)
  }

  /// The rig people actually have: the ultrawide and the rotated 4K. Both row
  /// states stay where they are today, so the fit above costs this page nothing.
  @Test func theGlyphRowLeavesTwoPanelsWhereTheyAre() {
    let aspects: [CGFloat] = [3440.0 / 1440.0, 2160.0 / 3840.0]
    for baseHeight in [Self.scanHeight, Self.cardsShownHeight] {
      let metrics = OnboardingCardGrid.glyphMetrics(
        aspects: aspects, availableWidth: Self.availableWidth, baseHeight: baseHeight)
      #expect(metrics.height == baseHeight)
      #expect(metrics.spacing == Self.restingSpacing)
    }
  }
}
