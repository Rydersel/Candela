import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

@Suite("Panel space transform")
struct PanelSpaceTransformTests {

  // MARK: - Points

  @Test func unrotatedTopLeftPointMapsToCellZero() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    #expect(t.cell(forDisplayPoint: CGPoint(x: 1, y: 1)) == 0)
  }

  @Test func unrotatedBottomRightPointMapsToLastCell() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    #expect(t.cell(forDisplayPoint: CGPoint(x: 3439, y: 1439)) == PanelGrid.cellCount - 1)
  }

  @Test func pointOutsideDisplayHasNoCell() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    #expect(t.cell(forDisplayPoint: CGPoint(x: -1, y: 10)) == nil)
    #expect(t.cell(forDisplayPoint: CGPoint(x: 10, y: 5000)) == nil)
    #expect(t.cell(forDisplayPoint: CGPoint(x: 3440, y: 10)) == nil)
    #expect(t.cell(forDisplayPoint: CGPoint(x: CGFloat.nan, y: 10)) == nil)
  }

  /// The Dell case. Mounted at 270°, macOS reports 2160×3840. 270° rotates the
  /// image a quarter turn clockwise onto the glass, so the display's top-left
  /// corner sits at the panel's own TOP-RIGHT.
  @Test func rotatedDisplayTopLeftMapsToPanelTopRight() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .twoSeventy)
    #expect(t.cell(forDisplayPoint: CGPoint(x: 1, y: 1)) == PanelGrid.cols - 1)
  }

  /// 90° is the other quarter turn: display top-left lands at the panel's
  /// bottom-left, first column of the last row.
  @Test func ninetyDegreeDisplayTopLeftMapsToPanelBottomLeft() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .ninety)
    #expect(
      t.cell(forDisplayPoint: CGPoint(x: 1, y: 1)) == (PanelGrid.rows - 1) * PanelGrid.cols)
  }

  @Test func oneEightyMapsDisplayTopLeftToPanelBottomRight() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .oneEighty)
    #expect(t.cell(forDisplayPoint: CGPoint(x: 1, y: 1)) == PanelGrid.cellCount - 1)
  }

  /// The property that matters more than any single mapping: a physical spot
  /// on the glass keeps its cell when the monitor is rotated.
  @Test func physicalCellIsStableAcrossRotation() {
    let upright = PanelSpaceTransform(
      displaySize: CGSize(width: 3840, height: 2160), rotation: .standard)
    let rotated = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .twoSeventy)
    // Panel-native top-right corner region.
    let uprightCell = upright.cell(forDisplayPoint: CGPoint(x: 3800, y: 40))
    // Same physical corner, seen through a 270° mount.
    let rotatedCell = rotated.cell(forDisplayPoint: CGPoint(x: 40, y: 40))
    #expect(uprightCell == PanelGrid.cols - 1)
    #expect(rotatedCell == uprightCell)
  }

  /// Tripwire against a rotation case that maps two display corners onto one
  /// panel cell — the shape a copy-pasted arithmetic error takes.
  @Test func everyRotationMapsTheFourDisplayCornersToFourDistinctCells() {
    for rotation in DisplayRotation.allCases {
      let size =
        rotation.swapsAxes
        ? CGSize(width: 2160, height: 3840) : CGSize(width: 3840, height: 2160)
      let t = PanelSpaceTransform(displaySize: size, rotation: rotation)
      let corners = [
        CGPoint(x: 1, y: 1),
        CGPoint(x: size.width - 1, y: 1),
        CGPoint(x: 1, y: size.height - 1),
        CGPoint(x: size.width - 1, y: size.height - 1),
      ]
      let cells = corners.compactMap { t.cell(forDisplayPoint: $0) }
      #expect(cells.count == 4, "\(rotation) dropped a corner")
      #expect(Set(cells).count == 4, "\(rotation) collapsed two corners onto one cell")
    }
  }

  @Test func degenerateDisplaySizeHasNoCells() {
    let zero = PanelSpaceTransform(displaySize: .zero, rotation: .standard)
    #expect(zero.cell(forDisplayPoint: CGPoint(x: 0, y: 0)) == nil)
    let negative = PanelSpaceTransform(
      displaySize: CGSize(width: -100, height: 200), rotation: .standard)
    #expect(negative.cell(forDisplayPoint: CGPoint(x: 10, y: 10)) == nil)
  }

  // MARK: - Coverage

  @Test func fullScreenRectCoversEveryCellFully() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    let coverage = t.coverage(ofDisplayRect: CGRect(x: 0, y: 0, width: 3440, height: 1440))
    #expect(coverage.count == PanelGrid.cellCount)
    #expect(coverage.allSatisfy { abs($0 - 1.0) < 0.001 })
  }

  @Test func emptyRectCoversNothing() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    #expect(t.coverage(ofDisplayRect: .zero).allSatisfy { $0 == 0 })
  }

  @Test func offScreenRectCoversNothing() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    let coverage = t.coverage(
      ofDisplayRect: CGRect(x: -800, y: -600, width: 400, height: 400))
    #expect(coverage.allSatisfy { $0 == 0 })
  }

  @Test func degenerateDisplaySizeCoversNothing() {
    let t = PanelSpaceTransform(displaySize: .zero, rotation: .standard)
    let coverage = t.coverage(ofDisplayRect: CGRect(x: 0, y: 0, width: 100, height: 100))
    #expect(coverage.count == PanelGrid.cellCount)
    #expect(coverage.allSatisfy { $0 == 0 })
  }

  /// A menu-bar-shaped strip must land in the top row and nowhere else.
  @Test func topStripCoversOnlyTheTopRow() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    let coverage = t.coverage(ofDisplayRect: CGRect(x: 0, y: 0, width: 3440, height: 24))
    for col in 0..<PanelGrid.cols {
      #expect(coverage[col] > 0)
    }
    for cell in PanelGrid.cols..<PanelGrid.cellCount {
      #expect(coverage[cell] == 0)
    }
  }

  /// Fractional, not boolean: half a cell is 0.5. Quantizing to whole cells
  /// would put a 143 px lie into every attribution.
  @Test func aHalfCoveredCellReportsHalfCoverage() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 2400, height: 1000), rotation: .standard)
    // One cell is 100×100 here. Cover the left half of the top-left cell.
    let coverage = t.coverage(ofDisplayRect: CGRect(x: 0, y: 0, width: 50, height: 100))
    #expect(abs(coverage[0] - 0.5) < 0.001)
    #expect(coverage[1] == 0)
  }

  @Test func coverageSumMatchesTheRectsShareOfTheDisplay() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    let rect = CGRect(x: 137, y: 211, width: 921, height: 604)
    let cellArea = 1.0 / Double(PanelGrid.cellCount)
    let covered = t.coverage(ofDisplayRect: rect).reduce(0, +) * cellArea
    let expected = (rect.width * rect.height) / (3440.0 * 1440.0)
    #expect(abs(covered - expected) < 0.0001)
  }

  /// Coverage travels through rotation the same way points do: a display-top
  /// strip on the 270° Dell is the panel's last column.
  @Test func rotatedTopStripCoversOnlyThePanelsLastColumn() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .twoSeventy)
    let coverage = t.coverage(ofDisplayRect: CGRect(x: 0, y: 0, width: 2160, height: 100))
    for row in 0..<PanelGrid.rows {
      #expect(coverage[row * PanelGrid.cols + (PanelGrid.cols - 1)] > 0)
      for col in 0..<(PanelGrid.cols - 1) {
        #expect(coverage[row * PanelGrid.cols + col] == 0)
      }
    }
  }

  // MARK: - Grid re-binning

  @Test func displayGridRebinsIntoPanelNativeOrientation() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .twoSeventy)
    // A 10-wide × 24-tall display-orientation sample, hot along its first row.
    var grid = [Double](repeating: 0, count: 240)
    for col in 0..<10 { grid[col] = 1.0 }
    let panel = t.panelNativeGrid(fromDisplayGrid: grid, cols: 10, rows: 24)
    #expect(panel.count == PanelGrid.cellCount)
    // That display row is the panel's LAST column under a 270° mount.
    for row in 0..<PanelGrid.rows {
      #expect(panel[row * PanelGrid.cols + (PanelGrid.cols - 1)] == 1.0)
    }
    for row in 0..<PanelGrid.rows {
      for col in 0..<(PanelGrid.cols - 1) {
        #expect(panel[row * PanelGrid.cols + col] == 0)
      }
    }
  }

  @Test func anUnrotatedGridOfTheSameShapePassesThrough() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    let grid = (0..<PanelGrid.cellCount).map { Double($0) / 240.0 }
    let panel = t.panelNativeGrid(
      fromDisplayGrid: grid, cols: PanelGrid.cols, rows: PanelGrid.rows)
    for cell in 0..<PanelGrid.cellCount {
      #expect(abs(panel[cell] - grid[cell]) < 1e-12)
    }
  }

  /// ScreenCaptureKit decides the capture size it feels like giving us, so the
  /// source grid's shape is not contractual — it gets resampled, not assumed.
  @Test func aFinerSourceGridIsAveragedDown() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    // 96×40 — four source cells per panel cell in each axis.
    var grid = [Double](repeating: 0, count: 96 * 40)
    for row in 0..<40 {
      for col in 0..<96 where col < 2 {  // left half of the first panel column
        grid[row * 96 + col] = 1.0
      }
    }
    let panel = t.panelNativeGrid(fromDisplayGrid: grid, cols: 96, rows: 40)
    #expect(abs(panel[0] - 0.5) < 0.001)
    #expect(panel[1] == 0)
  }

  @Test func aCoarserSourceGridIsSpreadOut() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    // 2×2 — the top-left quadrant is hot.
    let panel = t.panelNativeGrid(fromDisplayGrid: [1, 0, 0, 0], cols: 2, rows: 2)
    #expect(panel[0] == 1.0)
    #expect(panel[PanelGrid.cols - 1] == 0)
    #expect(panel[PanelGrid.cellCount - 1] == 0)
  }

  /// The test above is named for spreading but never exercises it: with a 2×2
  /// source the boundaries land on exactly 12/24 and 5/10, so no panel cell
  /// straddles one and every cell takes a single source value. A 3-column
  /// source puts a boundary at 8/24 and 16/24 — still integral — so this uses
  /// 7, whose boundaries fall inside panel cells 3, 6, 10, 13, 17 and 20.
  @Test func aPanelCellStraddlingTwoSourceCellsBlendsThem() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    // 7×1: first column hot, rest cold. 24/7 = 3.43 panel cells per source
    // column, so panel column 3 spans the boundary and must land strictly
    // between the two source values rather than snapping to either.
    var grid = [Double](repeating: 0, count: 7)
    grid[0] = 1.0
    let panel = t.panelNativeGrid(fromDisplayGrid: grid, cols: 7, rows: 1)

    #expect(panel[0] == 1.0)
    #expect(panel[1] == 1.0)
    #expect(panel[2] == 1.0)
    let straddling = panel[3]
    #expect(straddling > 0.0)
    #expect(straddling < 1.0)
    #expect(panel[4] == 0.0)
  }

  /// Coverage sums to the rect's share of the display in EVERY rotation, not
  /// just upright. The existing sum test is `.standard` only, so a rotation
  /// that lost or duplicated area would not show up in it.
  @Test func coverageSumsToTheRectsShareOfTheDisplayInEveryRotation() {
    let landscape = CGSize(width: 3440, height: 1440)
    let portrait = CGSize(width: 1440, height: 3440)
    let cases: [(DisplayRotation, CGSize)] = [
      (.standard, landscape), (.ninety, portrait),
      (.oneEighty, landscape), (.twoSeventy, portrait),
    ]
    for (rotation, size) in cases {
      let t = PanelSpaceTransform(displaySize: size, rotation: rotation)
      let rect = CGRect(x: 37, y: 91, width: 613, height: 428)
      let sum = t.coverage(ofDisplayRect: rect).reduce(0, +) / Double(PanelGrid.cellCount)
      let share = (rect.width * rect.height) / (size.width * size.height)
      #expect(abs(sum - share) < 1e-12, "rotation \(rotation) lost or duplicated area")
    }
  }

  /// `CGRect.intersection` treats NaN as "no constraint" rather than
  /// propagating it, so a NaN origin intersects the display to a full-width
  /// strip and an all-NaN rect to the WHOLE display. That window would then
  /// out-cover every real one in `WindowObserver.observe` and book the interval
  /// to its owner in a store that never washes out. `isNull` and `isInfinite`
  /// do not catch it.
  @Test func aRectWithNonFiniteComponentsCoversNothing() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    let bad: [CGRect] = [
      CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
      CGRect(x: 0, y: CGFloat.nan, width: 100, height: 100),
      CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100),
      CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan),
      CGRect(x: CGFloat.nan, y: CGFloat.nan, width: CGFloat.nan, height: CGFloat.nan),
    ]
    for rect in bad {
      let coverage = t.coverage(ofDisplayRect: rect)
      #expect(coverage.count == PanelGrid.cellCount)
      #expect(coverage.allSatisfy { $0 == 0 }, "a non-finite rect covered cells")
    }
  }

  @Test func aMalformedSourceGridRebinsToZeros() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    #expect(
      t.panelNativeGrid(fromDisplayGrid: [0.5, 0.5, 0.5], cols: PanelGrid.cols,
                        rows: PanelGrid.rows)
        == [Double](repeating: 0, count: PanelGrid.cellCount))
    #expect(
      t.panelNativeGrid(fromDisplayGrid: [], cols: 0, rows: 0)
        == [Double](repeating: 0, count: PanelGrid.cellCount))
  }

  @Test func theGridIsTwentyFourByTen() {
    #expect(PanelGrid.cols == 24)
    #expect(PanelGrid.rows == 10)
    #expect(PanelGrid.cellCount == 240)
  }
}
