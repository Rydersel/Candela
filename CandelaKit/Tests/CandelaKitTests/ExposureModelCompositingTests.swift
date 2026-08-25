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

  /// Named for what it pins, which is narrower than "an occluded window
  /// contributes nothing": that holds only where the front window FILLS the
  /// cell. The partial case is the test below, and it does not hold there.
  @Test("a window behind one that fills the cell contributes nothing")
  func aFullCellFrontWindowHidesEverythingBehindIt() {
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

  /// The approximation, written down as a number rather than left implicit.
  ///
  /// Coverage is per cell, not per region, so the walk cannot tell "the two
  /// windows sit on the same 0.6 of this cell" from "they sit on different
  /// halves of it". It assumes they do not overlap until the cell fills, so a
  /// window that is totally hidden still claims whatever fraction the front one
  /// left and books its own luminance there.
  ///
  /// Under the single-prior model that only mis-sized the covered fraction and
  /// cost nothing, since every claim carried the same luminance. With per-app
  /// priors it mis-ATTRIBUTES: below, a window nobody can see moves the cell.
  /// The true value under exact occlusion would be 0.82, which is what
  /// `0.6 * 0.9` plus 0.4 of the uncovered fallback comes to.
  @Test("a partly-overlapped window behind still claims what the front one left")
  func aPartlyCoveringFrontWindowLeavesRoomForAHiddenOne() {
    // 0.6 of cell 0: the grid is 24x10 on a 2400x1000 display, so a cell is
    // 100x100 px and this covers 60 of its 100 columns.
    let sixTenths = CGRect(x: 0, y: 0, width: 60, height: 100)
    var params = ExposureModelParameters.baseline
    params.compositing = .topmostWins
    params.appPriors = ["Front": 0.9, "Behind": 0.05]

    let grid = ExposureModel.modelledGrid(
      inputs: ExposureModelInputs(
        windows: [window(1, "Front", sixTenths), window(2, "Behind", sixTenths)],
        wallpaperCells: nil, appearanceIsDark: false),
      through: transform, parameters: params)

    // 0.6 at 0.9, then 0.4 (all that is left) at the hidden window's 0.05.
    #expect(abs(grid[0] - (0.6 * 0.9 + 0.4 * 0.05)) < 1e-12)
    // And the fallback is gone: nothing of the cell reaches the wallpaper term,
    // even though 0.4 of it is genuinely uncovered.
    #expect(abs(grid[0] - ExposureModel.lightAppearancePrior) > 0.1)
  }

  /// Asserts the VALUES, not merely that the two answers differ: a fully
  /// reversed walk also makes them differ, so a difference is no evidence of
  /// the convention. Front-to-back means index 0 is nearest the viewer.
  @Test("window order decides the answer, so the log may never be re-sorted")
  func orderIsLoadBearingUnderTopmostWins() {
    let cellRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    let a = window(1, "A", cellRect)
    let b = window(2, "B", cellRect)

    var params = ExposureModelParameters.baseline
    params.compositing = .topmostWins
    params.appPriors = ["A": 0.9, "B": 0.05]

    func value(_ windows: [WindowSnapshot]) -> Double {
      ExposureModel.modelledGrid(
        inputs: ExposureModelInputs(
          windows: windows, wallpaperCells: nil, appearanceIsDark: false),
        through: transform, parameters: params)[0]
    }

    #expect(abs(value([a, b]) - 0.9) < 1e-12)
    #expect(abs(value([b, a]) - 0.05) < 1e-12)
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

  /// The remaining-fraction invariant, which is the thing the walk can get
  /// wrong: claimed plus remaining is exactly one in every cell.
  ///
  /// Neither `accumulated` nor `remaining` is observable from here, so they are
  /// read out through the luminances instead. Run the same 40 windows twice:
  /// once with every window at 1 over a black wallpaper, where the answer IS
  /// the claimed fraction, and once with every window at 0 over a white one,
  /// where it is the remaining fraction. Their sum has to be 1.
  ///
  /// This replaces an assertion that could not fail. "Every value lies in 0 to
  /// 1" holds by construction whenever the priors and the wallpaper do, clamp
  /// or no clamp, because the result is then a convex combination of them: a
  /// reviewer's 20 mutations, including one that over-claims and one that
  /// accumulates five times too much, were caught by none of it.
  @Test("claimed and remaining sum to exactly one in every cell")
  func theRemainingFractionIsConserved() {
    var windows: [WindowSnapshot] = []
    for index in 0..<40 {
      windows.append(
        window(
          UInt32(index), "App\(index % 5)",
          CGRect(x: Double(index) * 37, y: Double(index) * 11, width: 900, height: 600)))
    }
    let owners = Set(windows.map(\.ownerName))

    func grid(windowLuminance: Double, wallpaper: Double) -> [Double] {
      var params = ExposureModelParameters.baseline
      params.compositing = .topmostWins
      params.appPriors = Dictionary(uniqueKeysWithValues: owners.map { ($0, windowLuminance) })
      return ExposureModel.modelledGrid(
        inputs: ExposureModelInputs(
          windows: windows,
          wallpaperCells: [Double](repeating: wallpaper, count: PanelGrid.cellCount),
          appearanceIsDark: false),
        through: transform, parameters: params)
    }

    let claimed = grid(windowLuminance: 1, wallpaper: 0)
    let remaining = grid(windowLuminance: 0, wallpaper: 1)
    #expect(claimed.count == PanelGrid.cellCount)
    for cell in 0..<PanelGrid.cellCount {
      #expect(
        abs(claimed[cell] + remaining[cell] - 1) < 1e-12,
        "cell \(cell) claimed \(claimed[cell]) and left \(remaining[cell])")
    }

    // Control: the fixture has to contain partly claimed cells. In a fully
    // claimed or fully clear one the sum is 1 whatever the walk does, and an
    // over-claim would clamp back to 1 unnoticed.
    #expect(claimed.contains { $0 > 1e-9 && $0 < 1 - 1e-9 })
  }

  /// `modelledGrid` promises `0...1` whichever branch runs. Only the
  /// topmost-wins branch enforced it, which was safe while the parameters were
  /// private to the fit and clamped there; the type is public and every field
  /// is settable, so an out-of-range prior is reachable from outside and the
  /// summed branch would have passed it straight through.
  @Test("an out-of-range prior cannot push a cell outside 0 to 1, in either branch")
  func theOutputStaysInRangeUnderAnOutOfRangePrior() {
    let cellRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    for compositing in [ExposureModelParameters.Compositing.summedCoverage, .topmostWins] {
      for prior in [1.5, -0.5] {
        var params = ExposureModelParameters.baseline
        params.compositing = compositing
        params.lightAppearancePrior = prior
        // Covered and uncovered both, since the prior serves as the covered
        // luminance and as the missing wallpaper's stand-in.
        for windows in [[window(1, "A", cellRect)], []] {
          let grid = ExposureModel.modelledGrid(
            inputs: ExposureModelInputs(
              windows: windows, wallpaperCells: nil, appearanceIsDark: false),
            through: transform, parameters: params)
          for value in grid {
            #expect(value >= 0 && value <= 1, "\(compositing) at prior \(prior) read \(value)")
          }
        }
      }
    }
  }

  /// The two appearance priors are the only free parameters ladder rung V3
  /// varies, and nothing read them from the parameters: swapping both lookups
  /// for `ExposureModel`'s shipped constants passed every test in both suites,
  /// because no test ever set them to anything else. A fit could then report a
  /// refitted prior it never applied.
  ///
  /// The values are deliberately unlike the shipped 0.7 and 0.12, and ordered
  /// the other way round, so a light-for-dark mix-up fails too.
  @Test("the appearance priors are read from the parameters, not from the constants")
  func appearancePriorsComeFromTheParameters() {
    let cellRect = CGRect(x: 0, y: 0, width: 100, height: 100)
    var params = ExposureModelParameters.baseline
    params.lightAppearancePrior = 0.31
    params.darkAppearancePrior = 0.83

    for compositing in [ExposureModelParameters.Compositing.summedCoverage, .topmostWins] {
      params.compositing = compositing
      func grid(windows: [WindowSnapshot], dark: Bool) -> [Double] {
        ExposureModel.modelledGrid(
          inputs: ExposureModelInputs(
            windows: windows, wallpaperCells: nil, appearanceIsDark: dark),
          through: transform, parameters: params)
      }
      let covered = [window(1, "Unpriored", cellRect)]

      // The covered path: a window with no prior of its own falls through to
      // the appearance prior.
      #expect(abs(grid(windows: covered, dark: false)[0] - 0.31) < 1e-12, "\(compositing)")
      #expect(abs(grid(windows: covered, dark: true)[0] - 0.83) < 1e-12, "\(compositing)")
      // And the uncovered path, where a missing wallpaper falls back to it too.
      #expect(abs(grid(windows: [], dark: false)[0] - 0.31) < 1e-12, "\(compositing)")
      #expect(abs(grid(windows: [], dark: true)[0] - 0.83) < 1e-12, "\(compositing)")
    }
  }
}

// Chrome admission by coverage.
//
// The layer range excludes everything below zero because the desktop backdrop
// fills the screen, and counting it would read the wallpaper as full-screen
// window coverage. That reasoning is about AREA, not layer, so a coverage bound
// expresses it directly while admitting the menu-bar strips the measured
// capture contains and the model has never seen.
//
// These exist because the offline harness modelled chrome the shipped type
// could not express, which would have made a passing rung unimplementable.
@Suite("Chrome admission by coverage")
struct ChromeCoverageAdmissionTests {

  private let transform = PanelSpaceTransform(
    displaySize: CGSize(width: 2400, height: 1000), rotation: .standard)

  private func window(_ owner: String, _ rect: CGRect, layer: Int) -> WindowSnapshot {
    WindowSnapshot(windowID: 1, ownerPID: 1, ownerName: owner, bounds: rect, layer: layer)
  }

  private let menuBar = -2_147_483_602
  private let transientAbove = 2_147_483_630

  private func grid(_ windows: [WindowSnapshot], _ parameters: ExposureModelParameters)
    -> [Double]
  {
    ExposureModel.modelledGrid(
      inputs: ExposureModelInputs(windows: windows, wallpaperCells: nil, appearanceIsDark: false),
      through: transform, parameters: parameters)
  }

  /// The shipped default must not move. This is the regression guard for a
  /// change made to the engine at the request of an offline tool.
  @Test("a nil limit is the shipped behaviour, for every layer")
  func nilLimitChangesNothing() {
    let strip = window("Window Server", CGRect(x: 0, y: 0, width: 2400, height: 100), layer: menuBar)
    let cursor = window("Cursor", CGRect(x: 0, y: 0, width: 200, height: 200),
      layer: transientAbove)
    let ordinary = window("App", CGRect(x: 0, y: 200, width: 1200, height: 600), layer: 0)

    for compositing in [ExposureModelParameters.Compositing.summedCoverage, .topmostWins] {
      var params = ExposureModelParameters.baseline
      params.compositing = compositing
      // Priors that would show if either window were admitted.
      params.layerPriors = [menuBar: 0.0, transientAbove: 1.0]
      #expect(grid([ordinary, strip, cursor], params) == grid([ordinary], params))
    }
  }

  @Test("a chrome-sized window below the range is admitted once a limit is set")
  func chromeIsAdmittedByCoverage() {
    // A full cell tall (the grid is 24x10, so 100 px on a 1000 px display), or
    // cell 0 is only partly covered and mixes with the backdrop.
    let strip = window("Window Server", CGRect(x: 0, y: 0, width: 2400, height: 100), layer: menuBar)
    var params = ExposureModelParameters.baseline
    params.compositing = .topmostWins
    params.layerPriors = [menuBar: 1.0]
    params.chromeCoverageLimit = 0.5

    let without = grid([strip], .baseline)
    let with = grid([strip], params)
    #expect(with != without)
    // Cell 0 is inside the strip, so it takes the layer's own luminance.
    #expect(abs(with[0] - 1.0) < 1e-12)
  }

  /// Admission is an admission rule, not a topmost-wins feature, and both
  /// branches run it. Nothing said so: disabling chrome under
  /// `.summedCoverage` passed every test in this file, because every chrome
  /// test above chose `.topmostWins`.
  @Test("chrome is admitted under summed coverage too, not only under topmost-wins")
  func chromeIsAdmittedUnderSummedCoverageAsWell() {
    let strip = window(
      "Window Server", CGRect(x: 0, y: 0, width: 2400, height: 100), layer: menuBar)
    // The summed branch carries no per-window luminance, so admission can only
    // show as coverage displacing the wallpaper. A wallpaper equal to the
    // appearance prior would hide it and the test could not fail.
    let paper = [Double](repeating: 0.0, count: PanelGrid.cellCount)

    func value(chromeLimit: Double?) -> [Double] {
      var params = ExposureModelParameters.baseline
      params.compositing = .summedCoverage
      params.chromeCoverageLimit = chromeLimit
      return ExposureModel.modelledGrid(
        inputs: ExposureModelInputs(
          windows: [strip], wallpaperCells: paper, appearanceIsDark: false),
        through: transform, parameters: params)
    }

    // Cell 0 is inside the strip; cell 24 is the row below it and must not move
    // either way, which is the control that the strip is the cause.
    #expect(value(chromeLimit: nil)[0] == 0.0)
    #expect(abs(value(chromeLimit: 0.5)[0] - ExposureModel.lightAppearancePrior) < 1e-12)
    #expect(value(chromeLimit: nil)[PanelGrid.cols] == 0.0)
    #expect(value(chromeLimit: 0.5)[PanelGrid.cols] == 0.0)
  }

  /// A limit above 1 is meaningless and dangerous: a full-display backdrop
  /// covers exactly 1 and nothing covers more, so any greater value admits the
  /// blanket that would delete the wallpaper term on every display. Read as
  /// `min(1, limit)` where it is used, because the field is public and settable
  /// and a check in `init` would only cover the callers that never assign.
  @Test("a limit above 1 still refuses a full-display backdrop")
  func anOutOfRangeLimitCannotAdmitABackdrop() {
    let dockLayer = -2_147_483_624
    let backdrop = window("Dock", CGRect(x: 0, y: 0, width: 2400, height: 1000), layer: dockLayer)
    let half = window("Dock", CGRect(x: 0, y: 0, width: 1200, height: 1000), layer: dockLayer)
    let paper = [Double](repeating: 0.42, count: PanelGrid.cellCount)

    func value(_ windows: [WindowSnapshot], _ compositing: ExposureModelParameters.Compositing,
      _ limit: Double) -> [Double] {
      var params = ExposureModelParameters.baseline
      params.compositing = compositing
      params.layerPriors = [dockLayer: 1.0]
      params.chromeCoverageLimit = limit
      return ExposureModel.modelledGrid(
        inputs: ExposureModelInputs(
          windows: windows, wallpaperCells: paper, appearanceIsDark: false),
        through: transform, parameters: params)
    }

    for compositing in [ExposureModelParameters.Compositing.summedCoverage, .topmostWins] {
      for limit in [1.0, 1.5, 100.0] {
        for cell in value([backdrop], compositing, limit) {
          #expect(abs(cell - 0.42) < 1e-12, "\(compositing) at limit \(limit) read \(cell)")
        }
        // Control: the same out-of-range limit still admits chrome that is not
        // a backdrop, so the assertion above is about the coverage bound and
        // not about admission having been switched off.
        #expect(
          value([half], compositing, limit)[0] != 0.42,
          "\(compositing) at limit \(limit) admitted nothing at all")
      }
    }
  }

  @Test("a full-display backdrop is refused, so the wallpaper term survives")
  func fullDisplayBackdropIsRefused() {
    let backdrop = window(
      "Dock", CGRect(x: 0, y: 0, width: 2400, height: 1000), layer: -2_147_483_624)
    var params = ExposureModelParameters.baseline
    params.compositing = .topmostWins
    params.chromeCoverageLimit = 0.5
    let paper = [Double](repeating: 0.42, count: PanelGrid.cellCount)

    let modelled = ExposureModel.modelledGrid(
      inputs: ExposureModelInputs(
        windows: [backdrop], wallpaperCells: paper, appearanceIsDark: false),
      through: transform, parameters: params)
    // The wallpaper must still be visible everywhere; a blanketed grid would
    // read 0.7 (the appearance prior) instead.
    for value in modelled { #expect(abs(value - 0.42) < 1e-12) }
  }

  /// The two exclusions are not symmetric, and a coverage bound cannot tell a
  /// transient pop-up from a menu bar, because both are small.
  @Test("a transient window above the range is never admitted, whatever the limit")
  func transientLayersStayExcluded() {
    // Big enough to fill a cell, and given a prior that differs from the
    // backdrop. Without both, admitting it would change no number and the test
    // could not fail: a transient window with no prior resolves to the same
    // appearance prior an uncovered cell falls back to.
    let cursor = window("Window Server", CGRect(x: 0, y: 0, width: 200, height: 200),
      layer: transientAbove)
    var params = ExposureModelParameters.baseline
    params.compositing = .topmostWins
    params.layerPriors = [transientAbove: 0.0]
    params.chromeCoverageLimit = 0.99
    #expect(grid([cursor], params) == grid([cursor], .baseline))
  }

  @Test("the limit is a strict upper bound")
  func limitIsStrict() {
    // Exactly half the display: 1200x1000 of 2400x1000.
    let half = window("Dock", CGRect(x: 0, y: 0, width: 1200, height: 1000), layer: menuBar)
    var params = ExposureModelParameters.baseline
    params.compositing = .topmostWins
    params.layerPriors = [menuBar: 1.0]
    params.chromeCoverageLimit = 0.5
    #expect(grid([half], params) == grid([half], .baseline))

    params.chromeCoverageLimit = 0.51
    #expect(grid([half], params) != grid([half], .baseline))
  }
}
