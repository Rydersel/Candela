import CoreGraphics
import Testing

@testable import CandelaKit

// The per-window luminance term and the compositing mode it needs.
//
// The comparison gate measured today's model at Pearson 0.522 but 1-in-10 cell
// agreement and a hottest multiple of 2.02x against a measured 3.17x. The cause
// is structural: one global prior for all covered area means every fully
// covered cell gets the identical value, so the model can only express the
// partial-coverage fraction at window edges. These tests pin the generalisation
// that gives it a luminance term without changing what ships today.
@Suite("Exposure model compositing")
struct ExposureModelCompositingTests {

  private let transform = PanelSpaceTransform(
    displaySize: CGSize(width: 2400, height: 1000), rotation: .standard)

  private func window(
    _ id: UInt32, _ owner: String, _ rect: CGRect, layer: Int = 0
  ) -> WindowSnapshot {
    WindowSnapshot(
      windowID: id, ownerPID: Int32(id), ownerName: owner, bounds: rect, layer: layer)
  }

  /// The formula this replaced, written out independently so the baseline is
  /// checked against an expectation rather than against itself.
  private func shippedFormula(
    windows: [WindowSnapshot], wallpaper: [Double]?, dark: Bool
  ) -> [Double] {
    let prior = dark ? ExposureModel.darkAppearancePrior : ExposureModel.lightAppearancePrior
    var coverage = [Double](repeating: 0, count: PanelGrid.cellCount)
    for window in windows where ExposureModel.includedLayers.contains(window.layer) {
      let contribution = transform.coverage(ofDisplayRect: window.bounds)
      for cell in coverage.indices { coverage[cell] += contribution[cell] }
    }
    return (0..<PanelGrid.cellCount).map { cell in
      let covered = min(1, max(0, coverage[cell]))
      return covered * prior + (1 - covered) * (wallpaper?[cell] ?? prior)
    }
  }

  // MARK: - The baseline may not move

  @Test("baseline parameters reproduce the shipped formula exactly")
  func baselineIsBitIdenticalToTheShippedFormula() {
    let paper = (0..<PanelGrid.cellCount).map { Double($0) / Double(PanelGrid.cellCount) }
    let cases: [([WindowSnapshot], [Double]?, Bool)] = [
      ([], nil, false),
      ([], paper, true),
      ([window(1, "A", CGRect(x: 0, y: 0, width: 1200, height: 1000))], paper, false),
      ([
        window(1, "A", CGRect(x: 0, y: 0, width: 1200, height: 1000)),
        window(2, "B", CGRect(x: 600, y: 200, width: 900, height: 500)),
        window(3, "C", CGRect(x: 0, y: 0, width: 2400, height: 40), layer: 24),
      ], paper, false),
      ([window(9, "Z", CGRect(x: 0, y: 0, width: 2400, height: 1000), layer: 99)], paper, false),
    ]
    for (windows, paper, dark) in cases {
      let inputs = ExposureModelInputs(
        windows: windows, wallpaperCells: paper, appearanceIsDark: dark)
      let got = ExposureModel.modelledGrid(
        inputs: inputs, through: transform, parameters: .baseline)
      let want = shippedFormula(windows: windows, wallpaper: paper, dark: dark)
      #expect(got == want)
    }
  }

  /// The two modes are interchangeable at baseline (that is MP13), so nothing
  /// else in this suite can notice if the shipped default flips. Pin it
  /// directly: which branch ships is a decision, not an implementation detail.
  @Test("the shipped default composites by the clamped sum")
  func baselinePinsItsCompositingMode() {
    #expect(ExposureModelParameters.baseline.compositing == .summedCoverage)
    #expect(ExposureModelParameters.baseline.appPriors.isEmpty)
    #expect(ExposureModelParameters.baseline.layerPriors.isEmpty)
  }

  // MARK: - The generalisation

  @Test("topmost-wins equals the clamped sum when every window shares one prior")
  func topmostWinsCollapsesToTheClampedSumWithUniformPriors() {
    let windows = [
      window(1, "A", CGRect(x: 0, y: 0, width: 1400, height: 1000)),
      window(2, "B", CGRect(x: 700, y: 100, width: 1200, height: 700)),
      window(3, "C", CGRect(x: 1900, y: 0, width: 500, height: 1000)),
    ]
    let paper = [Double](repeating: 0.3, count: PanelGrid.cellCount)
    let inputs = ExposureModelInputs(
      windows: windows, wallpaperCells: paper, appearanceIsDark: false)

    var topmost = ExposureModelParameters.baseline
    topmost.compositing = .topmostWins

    let summed = ExposureModel.modelledGrid(
      inputs: inputs, through: transform, parameters: .baseline)
    let walked = ExposureModel.modelledGrid(
      inputs: inputs, through: transform, parameters: topmost)

    for cell in 0..<PanelGrid.cellCount {
      #expect(abs(summed[cell] - walked[cell]) < 1e-12)
    }
  }

  @Test("an occluded window contributes nothing under topmost-wins")
  func occlusionHidesTheWindowBehind() {
    let cellRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    let front = window(1, "Front", cellRect)
    let behind = window(2, "Behind", cellRect)

    var params = ExposureModelParameters.baseline
    params.compositing = .topmostWins
    params.appPriors = ["Front": 0.9, "Behind": 0.05]

    let inputs = ExposureModelInputs(
      windows: [front, behind], wallpaperCells: nil, appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(
      inputs: inputs, through: transform, parameters: params)

    // Cell 0 is fully inside both windows, so the front one owns all of it.
    #expect(abs(grid[0] - 0.9) < 1e-12)
  }

  @Test("window order decides the answer, so the log may never be re-sorted")
  func orderIsLoadBearingUnderTopmostWins() {
    let cellRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    let a = window(1, "A", cellRect)
    let b = window(2, "B", cellRect)

    var params = ExposureModelParameters.baseline
    params.compositing = .topmostWins
    params.appPriors = ["A": 0.9, "B": 0.05]

    let front = ExposureModel.modelledGrid(
      inputs: ExposureModelInputs(windows: [a, b], wallpaperCells: nil, appearanceIsDark: false),
      through: transform, parameters: params)
    let reversed = ExposureModel.modelledGrid(
      inputs: ExposureModelInputs(windows: [b, a], wallpaperCells: nil, appearanceIsDark: false),
      through: transform, parameters: params)

    #expect(front[0] != reversed[0])
  }

  @Test("the clamped sum cannot express a per-window prior, which is the finding")
  func summedCoverageIgnoresPerWindowPriors() {
    let cellRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    var params = ExposureModelParameters.baseline
    params.appPriors = ["Front": 0.9, "Behind": 0.05]

    let inputs = ExposureModelInputs(
      windows: [window(1, "Front", cellRect), window(2, "Behind", cellRect)],
      wallpaperCells: nil, appearanceIsDark: false)
    let grid = ExposureModel.modelledGrid(
      inputs: inputs, through: transform, parameters: params)

    #expect(abs(grid[0] - ExposureModel.lightAppearancePrior) < 1e-12)
  }

  // MARK: - Precedence and bounds

  @Test("app prior beats layer prior beats appearance prior")
  func luminancePrecedence() {
    let cellRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    var params = ExposureModelParameters.baseline
    params.compositing = .topmostWins
    params.layerPriors = [24: 0.8]
    params.appPriors = ["Named": 0.42]

    func value(owner: String, layer: Int) -> Double {
      ExposureModel.modelledGrid(
        inputs: ExposureModelInputs(
          windows: [window(1, owner, cellRect, layer: layer)],
          wallpaperCells: nil, appearanceIsDark: false),
        through: transform, parameters: params)[0]
    }

    #expect(abs(value(owner: "Named", layer: 24) - 0.42) < 1e-12)
    #expect(abs(value(owner: "Other", layer: 24) - 0.8) < 1e-12)
    #expect(abs(value(owner: "Other", layer: 0) - ExposureModel.lightAppearancePrior) < 1e-12)
  }

  @Test("heavy overlap keeps every cell in range and never over-claims")
  func remainingFractionStaysSane() {
    var windows: [WindowSnapshot] = []
    for index in 0..<40 {
      windows.append(
        window(
          UInt32(index), "App\(index % 5)",
          CGRect(x: Double(index) * 37, y: Double(index) * 11, width: 900, height: 600)))
    }
    var params = ExposureModelParameters.baseline
    params.compositing = .topmostWins
    params.appPriors = ["App0": 1.0, "App1": 0.0, "App2": 0.5, "App3": 0.75, "App4": 0.25]

    let grid = ExposureModel.modelledGrid(
      inputs: ExposureModelInputs(
        windows: windows, wallpaperCells: nil, appearanceIsDark: false),
      through: transform, parameters: params)

    #expect(grid.count == PanelGrid.cellCount)
    for value in grid { #expect(value >= 0 && value <= 1) }
  }
}
