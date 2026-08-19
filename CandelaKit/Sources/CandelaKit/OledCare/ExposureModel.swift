import CoreGraphics
import Foundation

/// One instant's worth of permission-free evidence about what a display is
/// showing (EM3). Closed by design: window geometry, system appearance, and the
/// desktop wallpaper's own pixels, nothing else. Per-app luminance priors are
/// deliberately absent, because the comparison could not tell a bad prior apart
/// from a bad model.
public struct ExposureModelInputs: Sendable {
  /// Display-local coordinates, top-left origin, our own process already
  /// excluded by the window source.
  ///
  /// **Front-to-back, and the order is load-bearing.**
  /// `CGWindowListCopyWindowInfo` returns the list in that order and it must be
  /// preserved. Under `.summedCoverage` order changes nothing, which is exactly
  /// why it is easy to destroy by accident; under `.topmostWins` it decides
  /// which window owns each cell. Sorting this array, by owner or by id or for
  /// tidiness, silently changes every result without failing anything.
  public var windows: [WindowSnapshot]
  /// `PanelGrid.cellCount` values in panel-physical order, or nil when the
  /// wallpaper could not be read. Kit never loads images (EM6): the app target
  /// downsamples and converts, and hands the result over as floats.
  public var wallpaperCells: [Double]?
  public var appearanceIsDark: Bool

  public init(windows: [WindowSnapshot], wallpaperCells: [Double]?, appearanceIsDark: Bool) {
    self.windows = windows
    self.wallpaperCells = wallpaperCells
    self.appearanceIsDark = appearanceIsDark
  }
}

/// What a candidate model varies, so variants can be swept without forking
/// `ExposureModel`.
///
/// `.baseline` is exactly the shipped model, pinned by test rather than by
/// inspection: the offline harness replays recorded inputs and checks its
/// output against the grid the capture tool computed live, and that control is
/// meaningless if the baseline drifts.
public struct ExposureModelParameters: Equatable, Sendable {

  /// How overlapping windows combine.
  public enum Compositing: String, Equatable, Sendable, Codable {
    /// Coverage sums across windows and clamps at 1, the shipped behaviour.
    /// **Cannot express a per-window luminance**, which is the whole of the
    /// comparison gate's finding: with one value for all covered area, every
    /// fully covered cell gets the same number and the model can only vary
    /// through the partial-coverage fraction at window edges.
    case summedCoverage
    /// Walk front-to-back; each window claims what is left of each cell at its
    /// own luminance, and the remainder falls through to the wallpaper.
    case topmostWins
  }

  public var lightAppearancePrior: Double
  public var darkAppearancePrior: Double
  /// Window layer to luminance. The defensible half of the luminance term: the
  /// Dock and the menu bar are known chrome whose brightness tracks appearance.
  public var layerPriors: [Int: Double]
  /// Owning app to luminance. The half EM5 warned about, since a bad prior and
  /// a bad model look alike; only held-out validation makes it mean anything.
  public var appPriors: [String: Double]
  public var compositing: Compositing
  /// Admit system chrome (the Dock, the menu bar) from BELOW `includedLayers`,
  /// and only from below, when it covers less than this fraction of the panel.
  /// The range's other exclusion, the transient layers above it, stays excluded
  /// at every limit: see `ExposureModel.includedLayers`.
  ///
  /// **Nil is the shipped behaviour and the default.** The layer range excludes
  /// everything below zero because the desktop backdrop fills the screen, and
  /// counting it would read the wallpaper as full-screen window coverage. That
  /// reasoning is about AREA, not about layer, so a coverage bound expresses the
  /// intent directly while still admitting the menu-bar strips the measured
  /// capture contains and the model has never seen.
  ///
  /// **A value above 1 would defeat that**, since a full-display backdrop
  /// covers exactly 1 and no window can cover more, so this is read as
  /// `min(1, limit)` where it is used. Validated at the point of use rather
  /// than here: the field is public and settable, so a check in `init` only
  /// covers the callers that never assign to it.
  ///
  /// Exists so a candidate model can be expressed HERE rather than only in the
  /// offline harness: a rung the shipped type cannot represent is a rung whose
  /// pass could not be implemented.
  public var chromeCoverageLimit: Double?

  public init(
    lightAppearancePrior: Double, darkAppearancePrior: Double,
    layerPriors: [Int: Double], appPriors: [String: Double], compositing: Compositing,
    chromeCoverageLimit: Double? = nil
  ) {
    self.lightAppearancePrior = lightAppearancePrior
    self.darkAppearancePrior = darkAppearancePrior
    self.layerPriors = layerPriors
    self.appPriors = appPriors
    self.compositing = compositing
    self.chromeCoverageLimit = chromeCoverageLimit
  }

  public static let baseline = ExposureModelParameters(
    lightAppearancePrior: ExposureModel.lightAppearancePrior,
    darkAppearancePrior: ExposureModel.darkAppearancePrior,
    layerPriors: [:], appPriors: [:], compositing: .summedCoverage)

  /// App prior, then layer prior, then the appearance prior. Most specific
  /// evidence about a window wins.
  ///
  /// Public, and taking the owner and layer rather than a `WindowSnapshot`, so
  /// the offline fit harness in its own target can call it instead of spelling
  /// the chain out again: it works from windows already reduced to coverage, and
  /// a second copy of this is kept honest only by a runtime control.
  public func luminance(forOwner owner: String, layer: Int, appearancePrior: Double) -> Double {
    appPriors[owner] ?? layerPriors[layer] ?? appearancePrior
  }

  func luminance(for window: WindowSnapshot, appearancePrior: Double) -> Double {
    luminance(forOwner: window.ownerName, layer: window.layer, appearancePrior: appearancePrior)
  }
}

/// Estimates content luminance per panel-native cell from signals that need no
/// permission, so it can be compared against the Screen Recording measurement
/// that keeps dying with the grant.
///
/// **Everything here is estimated and must be called that (EM7).** The output
/// is never a measurement and never a health claim; its only consumer is the
/// paired comparison that decides whether the estimate can be trusted at all.
///
/// **No brightness term (EM13).** The measured capture reads the composited
/// framebuffer, and the panel's brightness is applied downstream of it, so both
/// sides of the comparison are content luminance in `0...1`. Scaling only the
/// modelled side would inject variance the measured side is blind to.
public enum ExposureModel {
  /// Covered-area content luminance under light appearance.
  ///
  /// **Unmeasured guess, and the comparison is the instrument that judges it
  /// (EM5).** Light-appearance app content is mostly near-white with dark text
  /// and some chrome, so this sits below 1 rather than at it. Tuning it from
  /// the soak is expected; the gate verdict is re-run afterwards, which is why
  /// tuning it is not circular.
  public static let lightAppearancePrior = 0.7

  /// Covered-area content luminance under dark appearance. Same standing as
  /// `lightAppearancePrior`: an unmeasured guess the comparison judges. Dark
  /// content is not black, it is dark grey with light text, so this is well
  /// above zero.
  public static let darkAppearancePrior = 0.12

  /// Window layers that count as content coverage (EM4).
  ///
  /// Ordinary app windows and their panels. Excludes two families for opposite
  /// reasons. Below zero is the desktop backdrop, which fills the screen:
  /// counting it would read the wallpaper as full-screen window coverage and
  /// delete the wallpaper term on every display. Above the range are transient
  /// high layers such as pop-up menus and drag images, which are on screen for
  /// a moment and would book a sampling interval's worth of coverage for it.
  ///
  /// **This range does NOT reach the Dock or the menu bar, and never did**
  /// [MEASURED 2026-08-18]. An earlier version of this comment said it did.
  /// Both live near `-2147483602`, far below zero, and the window source
  /// applies `.excludeDesktopElements` before this range is ever consulted, so
  /// system chrome does not reach the model by either route. The measured
  /// capture does contain its light, so the two sides of the comparison are
  /// asymmetric there.
  ///
  /// Widening the range is not the fix. The Dock and Wallpaper entries are
  /// full-display backing windows (3440x1440 on the MAG), so admitting them
  /// would blanket every cell and delete the wallpaper term, which is the
  /// failure the paragraph above already describes. Only the menu-bar strips
  /// are genuinely chrome-sized.
  ///
  /// Chrome auto-hide needs no special case: a hidden menu bar is not in the
  /// on-screen list.
  public static let includedLayers: ClosedRange<Int> = 0...25

  /// Estimated content luminance per panel-native cell, always exactly
  /// `PanelGrid.cellCount` values in `0...1` (EM12: panel-physical, through the
  /// same transform the measured path uses).
  ///
  /// Compositing follows `parameters.compositing`. Both branches inherit the
  /// same documented approximation: two windows covering parts of one cell are
  /// assumed not to overlap within it until the cell fills, so the covered
  /// fraction is the only thing their stacking decides.
  public static func modelledGrid(
    inputs: ExposureModelInputs, through transform: PanelSpaceTransform,
    parameters: ExposureModelParameters = .baseline
  ) -> [Double] {
    let prior =
      inputs.appearanceIsDark
      ? parameters.darkAppearancePrior : parameters.lightAppearancePrior
    let backdrop = usableWallpaper(inputs.wallpaperCells)

    /// Coverage for an admitted window, or nil when the window is excluded.
    ///
    /// Chrome is admitted by COVERAGE, never by AREA. The layer decides
    /// whether a window is eligible at all; coverage decides whether an
    /// eligible one gets in. Chrome windows in a window list belong to every
    /// display, so an area test against this display admits another panel's
    /// full-screen backdrop. Coverage is display-local by construction, so a
    /// foreign window is exactly 0 and a full-display backdrop is exactly 1,
    /// and both are refused.
    func admitted(_ window: WindowSnapshot) -> [Double]? {
      let contribution = transform.coverage(ofDisplayRect: window.bounds)
      guard contribution.count == PanelGrid.cellCount else { return nil }
      if includedLayers.contains(window.layer) { return contribution }
      // BELOW the range only. The two exclusions are not symmetric: below is
      // the desktop backdrop and system chrome, which a coverage bound can
      // separate; above are transient pop-up menus, drag images and cursor
      // layers, which are on screen for an instant and would book a whole
      // sampling interval. A coverage bound cannot tell those apart, because
      // they are small too.
      guard window.layer < includedLayers.lowerBound,
        let limit = parameters.chromeCoverageLimit
      else { return nil }
      let fraction = contribution.reduce(0, +) / Double(PanelGrid.cellCount)
      // Capped at 1: a full-display backdrop covers exactly that, so any
      // greater limit admits the blanket the paragraph above says cannot
      // happen. The field is public and settable, so trusting it is not an
      // option.
      guard fraction > 0, fraction < min(1, limit) else { return nil }
      return contribution
    }

    switch parameters.compositing {
    case .summedCoverage:
      var coverage = [Double](repeating: 0, count: PanelGrid.cellCount)
      for window in inputs.windows {
        guard let contribution = admitted(window) else { continue }
        for cell in coverage.indices {
          coverage[cell] += contribution[cell]
        }
      }

      var grid = [Double](repeating: 0, count: PanelGrid.cellCount)
      for cell in grid.indices {
        let covered = min(1, max(0, coverage[cell]))
        let value = covered * prior + (1 - covered) * (backdrop?[cell] ?? prior)
        // Clamped for the same reason the other branch is: the priors are
        // public and settable, and this function's doc promises `0...1`
        // whichever branch runs. Identity at every in-range prior, so the
        // baseline stays bit-identical.
        grid[cell] = min(1, max(0, value))
      }
      return grid

    case .topmostWins:
      // Each cell carries the fraction of itself not yet claimed by a nearer
      // window. With one shared prior the claims telescope to
      // `prior * min(1, sum)`, so this is a strict generalisation of the branch
      // above rather than a different model.
      var remaining = [Double](repeating: 1, count: PanelGrid.cellCount)
      var accumulated = [Double](repeating: 0, count: PanelGrid.cellCount)
      for window in inputs.windows {
        guard let contribution = admitted(window) else { continue }
        let luminance = parameters.luminance(for: window, appearancePrior: prior)
        for cell in 0..<PanelGrid.cellCount {
          let claim = min(contribution[cell], remaining[cell])
          guard claim > 0 else { continue }
          accumulated[cell] += claim * luminance
          remaining[cell] = max(0, remaining[cell] - claim)
        }
      }

      var grid = [Double](repeating: 0, count: PanelGrid.cellCount)
      for cell in grid.indices {
        let value = accumulated[cell] + remaining[cell] * (backdrop?[cell] ?? prior)
        // Float error at a boundary can put this a hair outside the range the
        // accumulator's bookability check requires.
        grid[cell] = min(1, max(0, value))
      }
      return grid
    }
  }

  /// A wallpaper is taken whole or refused whole, matching `ExposureAccumulator`.
  /// Salvaging the good members of a malformed array would leave real cells
  /// beside invented ones in a store that never washes out, and the resulting
  /// map would look plausible.
  private static func usableWallpaper(_ cells: [Double]?) -> [Double]? {
    guard let cells, cells.count == PanelGrid.cellCount else { return nil }
    guard cells.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return nil }
    return cells
  }
}
