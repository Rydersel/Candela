import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

@Suite("Exposure model")
struct ExposureModelTests {

  private let uprightTransform = PanelSpaceTransform(
    displaySize: CGSize(width: 2400, height: 1000), rotation: .standard)

  private func window(
    _ bounds: CGRect, layer: Int = 0, id: UInt32 = 1, owner: String = "Editor"
  ) -> WindowSnapshot {
    WindowSnapshot(
      windowID: id, ownerPID: 42, ownerName: owner, bounds: bounds, layer: layer)
  }

  private var fullScreen: CGRect { CGRect(x: 0, y: 0, width: 2400, height: 1000) }
  private var leftHalf: CGRect { CGRect(x: 0, y: 0, width: 1200, height: 1000) }

  private func cell(row: Int, col: Int) -> Int { row * PanelGrid.cols + col }

  private func expectClose(
    _ value: Double, _ expected: Double, _ tolerance: Double = 1e-6,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(abs(value - expected) < tolerance, sourceLocation: sourceLocation)
  }

  // MARK: - Blending

  @Test func coveredCellsTakeThePriorAndUncoveredCellsTakeTheWallpaper() {
    let inputs = ExposureModelInputs(
      windows: [window(leftHalf)],
      wallpaperCells: [Double](repeating: 0.2, count: PanelGrid.cellCount),
      appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)

    #expect(grid.count == PanelGrid.cellCount)
    expectClose(grid[cell(row: 0, col: 0)], ExposureModel.lightAppearancePrior)
    expectClose(grid[cell(row: 5, col: 3)], ExposureModel.lightAppearancePrior)
    expectClose(grid[cell(row: 0, col: 23)], 0.2)
    expectClose(grid[cell(row: 9, col: 20)], 0.2)
  }

  /// Half-covered cells blend, they do not round to one side. A window that
  /// stops mid-cell is the common case at 143 px granularity.
  @Test func aPartiallyCoveredCellBlendsInProportion() {
    let halfCellWide = CGRect(x: 0, y: 0, width: 50, height: 1000)
    let inputs = ExposureModelInputs(
      windows: [window(halfCellWide)],
      wallpaperCells: [Double](repeating: 0.0, count: PanelGrid.cellCount),
      appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
    expectClose(grid[cell(row: 0, col: 0)], 0.5 * ExposureModel.lightAppearancePrior)
  }

  // MARK: - Layer policy

  /// The desktop backdrop sits below zero and fills the screen. Counting it
  /// would read the wallpaper as full-screen window coverage and erase the
  /// wallpaper term entirely, on every display, forever.
  @Test func aBelowZeroBackdropWindowIsNotCoverage() {
    let inputs = ExposureModelInputs(
      windows: [window(fullScreen, layer: -1)],
      wallpaperCells: [Double](repeating: 0.1, count: PanelGrid.cellCount),
      appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
    for value in grid { expectClose(value, 0.1) }
  }

  @Test func aTransientHighLayerWindowIsNotCoverage() {
    let inputs = ExposureModelInputs(
      windows: [window(fullScreen, layer: 30)],
      wallpaperCells: [Double](repeating: 0.1, count: PanelGrid.cellCount),
      appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
    for value in grid { expectClose(value, 0.1) }
  }

  @Test func theIncludedRangeCoversOrdinaryWindowsThroughTheMenuBar() {
    #expect(ExposureModel.includedLayers == 0...25)
    #expect(ExposureModel.includedLayers.contains(0))
    #expect(ExposureModel.includedLayers.contains(20))
    #expect(ExposureModel.includedLayers.contains(25))
    #expect(ExposureModel.includedLayers.contains(-1) == false)
    #expect(ExposureModel.includedLayers.contains(26) == false)
  }

  @Test func anIncludedNonZeroLayerCounts() {
    let inputs = ExposureModelInputs(
      windows: [window(fullScreen, layer: 25)],
      wallpaperCells: [Double](repeating: 0.1, count: PanelGrid.cellCount),
      appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
    for value in grid { expectClose(value, ExposureModel.lightAppearancePrior) }
  }

  // MARK: - Overlap

  /// Two stacked windows cover the same cell once, not twice. Without the
  /// clamp a cell would exceed the prior and the grid would leave 0...1.
  @Test func overlappingWindowsClampAtFullCoverage() {
    let inputs = ExposureModelInputs(
      windows: [window(fullScreen, id: 1), window(fullScreen, id: 2)],
      wallpaperCells: [Double](repeating: 0.0, count: PanelGrid.cellCount),
      appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
    for value in grid {
      expectClose(value, ExposureModel.lightAppearancePrior)
      #expect(value <= 1.0)
    }
  }

  @Test func everyCellStaysWithinZeroToOne() {
    let inputs = ExposureModelInputs(
      windows: (1...6).map { window(fullScreen, id: UInt32($0)) },
      wallpaperCells: [Double](repeating: 1.0, count: PanelGrid.cellCount),
      appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
    #expect(grid.allSatisfy { $0 >= 0 && $0 <= 1 })
  }

  // MARK: - Wallpaper fallback

  @Test func anAbsentWallpaperFallsBackToThePrior() {
    let inputs = ExposureModelInputs(
      windows: [], wallpaperCells: nil, appearanceIsDark: true)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
    #expect(grid.count == PanelGrid.cellCount)
    for value in grid { expectClose(value, ExposureModel.darkAppearancePrior) }
  }

  @Test func aWrongLengthWallpaperFallsBackToThePrior() {
    let inputs = ExposureModelInputs(
      windows: [], wallpaperCells: [0.9, 0.9, 0.9], appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
    for value in grid { expectClose(value, ExposureModel.lightAppearancePrior) }
  }

  /// All-or-nothing, the accumulator's rule: one bad member discards the whole
  /// wallpaper rather than leaving the real cells beside an invented one.
  @Test func oneNonFiniteWallpaperCellDiscardsTheWholeWallpaper() {
    for poison in [Double.nan, .infinity, -.infinity] {
      var cells = [Double](repeating: 0.9, count: PanelGrid.cellCount)
      cells[100] = poison
      let inputs = ExposureModelInputs(
        windows: [], wallpaperCells: cells, appearanceIsDark: false)
      let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
      for value in grid { expectClose(value, ExposureModel.lightAppearancePrior) }
    }
  }

  @Test func oneOutOfRangeWallpaperCellDiscardsTheWholeWallpaper() {
    for poison in [-0.1, 1.5] {
      var cells = [Double](repeating: 0.9, count: PanelGrid.cellCount)
      cells[7] = poison
      let inputs = ExposureModelInputs(
        windows: [], wallpaperCells: cells, appearanceIsDark: false)
      let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
      for value in grid { expectClose(value, ExposureModel.lightAppearancePrior) }
    }
  }

  @Test func aValidWallpaperSurvivesItsExtremes() {
    var cells = [Double](repeating: 0.5, count: PanelGrid.cellCount)
    cells[0] = 0
    cells[1] = 1
    let inputs = ExposureModelInputs(
      windows: [], wallpaperCells: cells, appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
    expectClose(grid[0], 0)
    expectClose(grid[1], 1)
    expectClose(grid[2], 0.5)
  }

  // MARK: - Appearance

  @Test func theAppearanceFlipMovesCoveredCellsOnly() {
    let wallpaper = [Double](repeating: 0.3, count: PanelGrid.cellCount)
    let light = ExposureModel.modelledGrid(
      inputs: ExposureModelInputs(
        windows: [window(leftHalf)], wallpaperCells: wallpaper, appearanceIsDark: false),
      through: uprightTransform)
    let dark = ExposureModel.modelledGrid(
      inputs: ExposureModelInputs(
        windows: [window(leftHalf)], wallpaperCells: wallpaper, appearanceIsDark: true),
      through: uprightTransform)

    expectClose(light[cell(row: 0, col: 0)], ExposureModel.lightAppearancePrior)
    expectClose(dark[cell(row: 0, col: 0)], ExposureModel.darkAppearancePrior)
    expectClose(light[cell(row: 0, col: 23)], 0.3)
    expectClose(dark[cell(row: 0, col: 23)], 0.3)
  }

  @Test func thePriorsArePinnedAtTheirDocumentedGuesses() {
    #expect(ExposureModel.lightAppearancePrior == 0.7)
    #expect(ExposureModel.darkAppearancePrior == 0.12)
    #expect(ExposureModel.darkAppearancePrior < ExposureModel.lightAppearancePrior)
  }

  // MARK: - Panel-physical output

  /// The modelled grid must land in the SAME cells the measured path books
  /// into, or the comparison scores a coordinate bug rather than the model.
  /// Pinned with a value that differs under the inverse rotation mapping: the
  /// Dell mounted at 270 puts the display's top strip at the panel's RIGHT
  /// edge (column 23), and the inverse convention would put it at column 0.
  @Test func aRotatedDisplayPlacesATopStripInPanelNativeColumns() {
    let rotated = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .twoSeventy)
    // An eighth of the display's height: exact in binary, so the strip lands on
    // the columns 21 to 23 boundary without float drift.
    let topStrip = CGRect(x: 0, y: 0, width: 2160, height: 480)
    let inputs = ExposureModelInputs(
      windows: [window(topStrip)],
      wallpaperCells: [Double](repeating: 0.0, count: PanelGrid.cellCount),
      appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: rotated)

    for row in 0..<PanelGrid.rows {
      expectClose(grid[cell(row: row, col: 23)], ExposureModel.lightAppearancePrior)
      expectClose(grid[cell(row: row, col: 21)], ExposureModel.lightAppearancePrior)
      expectClose(grid[cell(row: row, col: 0)], 0)
      expectClose(grid[cell(row: row, col: 2)], 0)
    }
  }

  @Test func anUnusableTransformStillAnswersAFullGrid() {
    let broken = PanelSpaceTransform(displaySize: .zero, rotation: .standard)
    let inputs = ExposureModelInputs(
      windows: [window(fullScreen)],
      wallpaperCells: [Double](repeating: 0.4, count: PanelGrid.cellCount),
      appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: broken)
    #expect(grid.count == PanelGrid.cellCount)
    for value in grid { expectClose(value, 0.4) }
  }

  @Test func aWindowWithNonFiniteBoundsContributesNothing() {
    let inputs = ExposureModelInputs(
      windows: [window(CGRect(x: Double.nan, y: 0, width: 2400, height: 1000))],
      wallpaperCells: [Double](repeating: 0.25, count: PanelGrid.cellCount),
      appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(inputs: inputs, through: uprightTransform)
    for value in grid { expectClose(value, 0.25) }
  }
}
