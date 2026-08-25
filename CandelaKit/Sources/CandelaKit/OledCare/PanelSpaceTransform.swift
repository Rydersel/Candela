import CoreGraphics
import Foundation

/// The fixed grid every panel's exposure history is stored in.
///
/// 24:10 is 2.4:1, which is the MAG's ultrawide aspect, so its cells come out
/// almost square (143×144 px on 3440×1440): coarse enough that a one-shot
/// capture stays cheap, fine enough to separate a menu bar from the content
/// under it. **Cells are square only on that panel.** The grid is fixed rather
/// than per-panel so one stored shape serves every display, which means a 16:9
/// or 16:10 panel gets cells taller than they are wide (160×216 px on the Dell,
/// 35% taller). Harmless for accumulation, which is area-weighted, but anything
/// DRAWING the grid must use the display's own aspect and not 24:10.
public struct PanelGrid: Equatable, Sendable {
  public static let cols = 24
  public static let rows = 10
  public static let cellCount = cols * rows
}

/// Maps display coordinates onto panel-native grid cells.
///
/// **Panel-native is the geometry the glass was manufactured with**, not what
/// macOS reports. The Dell is a 3840×2160 panel mounted at 270°, so macOS hands
/// us 2160×3840; everything accumulates into panel-native cells so that
/// rotating a monitor does not scramble its wear history.
///
/// **Rotation convention: `CGDisplayRotation` is degrees CLOCKWISE.** Apple's
/// header says so outright (`CGDisplayConfiguration.h`, macOS 26 SDK): "Return
/// the rotation angle of a display in degrees clockwise. A display rotation of
/// 90° implies the display is rotated clockwise 90°, such that what was the
/// physical bottom of the display is now the left side, and what was the
/// physical top is now the right side."
///
/// At 270° the glass is therefore turned 90° anticlockwise in the world frame:
/// the manufactured top edge faces left and the manufactured right edge faces
/// up, so the display's top-left corner is the panel's **top-right**. That is
/// what `panelPoint`/`displayPoint` below implement, and
/// `ExposureAccumulatorTests.accumulationIsStableAcrossARotationChange` pins
/// it with a value that differs between this convention and its inverse.
///
/// This comment previously said the reading was taken as degrees
/// *counterclockwise* and that the mapping was unverified. The mapping was
/// always right; the stated premise was backwards, and the two errors cancelled
/// because the sentence went on to describe the rotation of the image within
/// the frame, which is the inverse of the glass's rotation in the world. Left
/// as it was, the next reader to check it against Apple would have "fixed" a
/// correct transform. Settled from documentation 2026-08-07, so this no longer
/// needs the rotated Dell to confirm it.
public struct PanelSpaceTransform: Equatable, Sendable {
  public let displaySize: CGSize
  public let rotation: DisplayRotation

  public init(displaySize: CGSize, rotation: DisplayRotation) {
    self.displaySize = displaySize
    self.rotation = rotation
  }

  /// A display can report zero size mid-reconfiguration; every entry point
  /// answers with "nothing" rather than dividing by it.
  private var hasUsableSize: Bool {
    displaySize.width > 0 && displaySize.height > 0
      && displaySize.width.isFinite && displaySize.height.isFinite
  }

  private static let noCoverage = [Double](repeating: 0, count: PanelGrid.cellCount)

  /// `CGRect.intersection` treats NaN as "no constraint" rather than
  /// propagating it, so a rect with a NaN origin intersects a 3440×1440 display
  /// to a FULL-WIDTH strip and an all-NaN rect to the whole display. That
  /// window would then out-cover every real one in `WindowObserver.observe`
  /// (1.0 beats any fraction), take every cell, and book the whole interval to
  /// its owner in a store that never washes out. `isNull` and `isInfinite` do
  /// not catch it.
  static func isUsable(_ rect: CGRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite
      && rect.size.width.isFinite && rect.size.height.isFinite
  }

  // MARK: - The rotation, in one place

  /// Normalized display point → normalized panel-native point. Both are
  /// `0...1` with a top-left origin and y downwards.
  private func panelPoint(u: Double, v: Double) -> (p: Double, q: Double) {
    switch rotation {
    case .standard: (u, v)
    case .ninety: (v, 1 - u)
    case .oneEighty: (1 - u, 1 - v)
    case .twoSeventy: (1 - v, u)
    }
  }

  /// `panelPoint` for `OverlayMask`, which needs the same mapping to walk a
  /// display-oriented grid back into panel cells, and for the window ghost
  /// overlay, which maps display-local window corners onto the drawn surface.
  ///
  /// Exposed rather than duplicated: the rotation convention is subtle enough
  /// that it already shipped with a backwards doc comment, and two spellings of
  /// it would be two places a correction has to find. This is the one place.
  /// Public for the app-target overlay, same reasoning at one remove.
  public func panelPointForDisplay(u: Double, v: Double) -> (p: Double, q: Double) {
    panelPoint(u: u, v: v)
  }

  private func displayPoint(p: Double, q: Double) -> (u: Double, v: Double) {
    switch rotation {
    case .standard: (p, q)
    case .ninety: (1 - q, p)
    case .oneEighty: (1 - p, 1 - q)
    case .twoSeventy: (q, 1 - p)
    }
  }

  // MARK: - Points

  /// Grid cell for a point given in DISPLAY coordinates (origin top-left,
  /// display's current rotated orientation). Nil if outside the display.
  public func cell(forDisplayPoint point: CGPoint) -> Int? {
    guard hasUsableSize, point.x.isFinite, point.y.isFinite else { return nil }
    guard point.x >= 0, point.y >= 0,
      point.x < displaySize.width, point.y < displaySize.height
    else { return nil }

    let (p, q) = panelPoint(u: point.x / displaySize.width, v: point.y / displaySize.height)
    let col = min(PanelGrid.cols - 1, max(0, Int(p * Double(PanelGrid.cols))))
    let row = min(PanelGrid.rows - 1, max(0, Int(q * Double(PanelGrid.rows))))
    return row * PanelGrid.cols + col
  }

  // MARK: - Rects

  /// Fractional coverage of each grid cell by a rect in DISPLAY coordinates.
  /// Returns 240 values in 0...1, indexed row-major in PANEL-NATIVE
  /// orientation. Fractional rather than boolean: a window straddling a cell
  /// boundary contributes in proportion, or attribution quantizes into visible
  /// lies at 143 px granularity.
  public func coverage(ofDisplayRect rect: CGRect) -> [Double] {
    guard hasUsableSize, !rect.isNull, !rect.isInfinite, Self.isUsable(rect) else {
      return Self.noCoverage
    }
    let onScreen = rect.intersection(CGRect(origin: .zero, size: displaySize))
    guard !onScreen.isNull, onScreen.width > 0, onScreen.height > 0 else { return Self.noCoverage }

    let panel = panelRect(
      normalizedDisplayRect: (
        u0: onScreen.minX / displaySize.width, u1: onScreen.maxX / displaySize.width,
        v0: onScreen.minY / displaySize.height, v1: onScreen.maxY / displaySize.height
      ))

    var coverage = Self.noCoverage
    let cellWidth = 1.0 / Double(PanelGrid.cols)
    let cellHeight = 1.0 / Double(PanelGrid.rows)
    for row in 0..<PanelGrid.rows {
      let vertical =
        overlap(panel.q0, panel.q1, Double(row) * cellHeight, Double(row + 1) * cellHeight)
        / cellHeight
      guard vertical > 0 else { continue }
      for col in 0..<PanelGrid.cols {
        let horizontal =
          overlap(panel.p0, panel.p1, Double(col) * cellWidth, Double(col + 1) * cellWidth)
          / cellWidth
        coverage[row * PanelGrid.cols + col] = min(1, horizontal * vertical)
      }
    }
    return coverage
  }

  // MARK: - Grids

  /// Re-bin a luminance grid sampled in DISPLAY orientation into PANEL-NATIVE
  /// cells. Input is row-major in display orientation, and its shape is not
  /// contractual — ScreenCaptureKit reduces the requested capture size — so
  /// each panel cell is the area-weighted mean of the source cells under it.
  /// A malformed grid re-bins to zeros rather than trapping.
  public func panelNativeGrid(
    fromDisplayGrid grid: [Double], cols: Int, rows: Int
  ) -> [Double] {
    guard cols > 0, rows > 0, grid.count == cols * rows else { return Self.noCoverage }

    var panel = Self.noCoverage
    let cellWidth = 1.0 / Double(PanelGrid.cols)
    let cellHeight = 1.0 / Double(PanelGrid.rows)
    let sourceWidth = 1.0 / Double(cols)
    let sourceHeight = 1.0 / Double(rows)

    for row in 0..<PanelGrid.rows {
      for col in 0..<PanelGrid.cols {
        let source = displayRect(
          normalizedPanelRect: (
            p0: Double(col) * cellWidth, p1: Double(col + 1) * cellWidth,
            q0: Double(row) * cellHeight, q1: Double(row + 1) * cellHeight
          ))
        // Sub-ULP slivers at exact cell boundaries survive the rotation
        // arithmetic; keeping them would perturb an otherwise exact resample.
        let sliver = (source.u1 - source.u0) * (source.v1 - source.v0) * 1e-9

        var weighted = 0.0
        var total = 0.0
        for sourceRow in indexRange(source.v0, source.v1, count: rows) {
          let vertical =
            overlap(
              source.v0, source.v1, Double(sourceRow) * sourceHeight,
              Double(sourceRow + 1) * sourceHeight)
          for sourceCol in indexRange(source.u0, source.u1, count: cols) {
            let horizontal =
              overlap(
                source.u0, source.u1, Double(sourceCol) * sourceWidth,
                Double(sourceCol + 1) * sourceWidth)
            let weight = horizontal * vertical
            guard weight > sliver else { continue }
            weighted += weight * grid[sourceRow * cols + sourceCol]
            total += weight
          }
        }
        if total > 0 { panel[row * PanelGrid.cols + col] = weighted / total }
      }
    }
    return panel
  }

  // MARK: - Geometry helpers

  private typealias NormalizedDisplayRect = (u0: Double, u1: Double, v0: Double, v1: Double)
  private typealias NormalizedPanelRect = (p0: Double, p1: Double, q0: Double, q1: Double)

  /// Right-angle rotations keep an axis-aligned rect axis-aligned, so two
  /// opposite corners describe the whole thing.
  private func panelRect(normalizedDisplayRect rect: NormalizedDisplayRect)
    -> NormalizedPanelRect
  {
    let a = panelPoint(u: rect.u0, v: rect.v0)
    let b = panelPoint(u: rect.u1, v: rect.v1)
    return (min(a.p, b.p), max(a.p, b.p), min(a.q, b.q), max(a.q, b.q))
  }

  private func displayRect(normalizedPanelRect rect: NormalizedPanelRect)
    -> NormalizedDisplayRect
  {
    let a = displayPoint(p: rect.p0, q: rect.q0)
    let b = displayPoint(p: rect.p1, q: rect.q1)
    return (min(a.u, b.u), max(a.u, b.u), min(a.v, b.v), max(a.v, b.v))
  }

  private func overlap(_ lower: Double, _ upper: Double, _ cellLower: Double, _ cellUpper: Double)
    -> Double
  {
    max(0, min(upper, cellUpper) - max(lower, cellLower))
  }

  /// Source indices a normalized span can touch, widened by one either side so
  /// float error at a boundary cannot drop a contributing cell.
  private func indexRange(_ lower: Double, _ upper: Double, count: Int) -> ClosedRange<Int> {
    let first = min(count - 1, max(0, Int((lower * Double(count)).rounded(.down)) - 1))
    let last = min(count - 1, max(first, Int((upper * Double(count)).rounded(.up))))
    return first...last
  }
}
