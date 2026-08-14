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
  /// Includes ordinary app windows (layer 0) up through the Dock and the menu
  /// bar. Excludes two families for opposite reasons. Below zero is the desktop
  /// backdrop, which fills the screen: counting it would read the wallpaper as
  /// full-screen window coverage and delete the wallpaper term on every
  /// display. Above the range are transient high layers such as pop-up menus
  /// and drag images, which are on screen for a moment and would book a
  /// sampling interval's worth of coverage for it. Chrome auto-hide needs no
  /// special case: a hidden menu bar is not in the on-screen list.
  public static let includedLayers: ClosedRange<Int> = 0...25

  /// Estimated content luminance per panel-native cell, always exactly
  /// `PanelGrid.cellCount` values in `0...1` (EM12: panel-physical, through the
  /// same transform the measured path uses).
  ///
  /// Coverage is the clamped sum of each included window's contribution.
  /// Summing overlapping windows and clamping is the documented approximation:
  /// with one shared prior for all covered area, stacking order changes nothing
  /// but the covered fraction, so the clamp costs only the double-counting.
  public static func modelledGrid(
    inputs: ExposureModelInputs, through transform: PanelSpaceTransform
  ) -> [Double] {
    let prior = inputs.appearanceIsDark ? darkAppearancePrior : lightAppearancePrior
    let backdrop = usableWallpaper(inputs.wallpaperCells)

    var coverage = [Double](repeating: 0, count: PanelGrid.cellCount)
    for window in inputs.windows where includedLayers.contains(window.layer) {
      let contribution = transform.coverage(ofDisplayRect: window.bounds)
      guard contribution.count == coverage.count else { continue }
      for cell in coverage.indices {
        coverage[cell] += contribution[cell]
      }
    }

    var grid = [Double](repeating: 0, count: PanelGrid.cellCount)
    for cell in grid.indices {
      let covered = min(1, max(0, coverage[cell]))
      grid[cell] = covered * prior + (1 - covered) * (backdrop?[cell] ?? prior)
    }
    return grid
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
