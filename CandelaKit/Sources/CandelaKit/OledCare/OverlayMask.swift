import CoreGraphics
import Foundation

/// A per-cell alpha for the dimming overlay, in panel-physical space.
///
/// The overlay's spatial axis, built once and consumed twice: by #20's
/// feathered regions and, once its effect-size gate clears, by OC17's wear
/// mask. Values are opacity, matching `OledDimming.alpha(for:)`: 0 covers
/// nothing, 1 is opaque.
///
/// **Quantized on construction, and that is the whole design.** `OledOverlay`
/// skips the window-server round trip when the applied state is unchanged, and
/// at the overlay-up cadence an unconditional re-order is ~10 round trips per
/// second per display, each one re-stacking the overlay above whatever else
/// sits at shielding level. A mask derived from live luminance differs in the
/// twelfth decimal place every tick, so an unquantized mask would make every
/// apply a memo miss and turn that saving off permanently. Rounding to 1/255
/// costs nothing visible, because the rendered mask is an 8-bit image anyway,
/// and it makes `==` mean "will look the same".
public struct OverlayMask: Equatable, Sendable {
  /// The render target is 8-bit grayscale, so this is the finest distinction
  /// that survives to the screen. Anything finer is a difference that exists
  /// only in the comparison.
  static let levels: Double = 255

  /// `PanelGrid.cellCount` values in panel-physical row-major order, each
  /// 0...1 and already quantized.
  public private(set) var cells: [Double]

  /// A wrong-length array answers "cover nothing" rather than trapping, the
  /// same all-or-nothing rule `ExposureAccumulator` applies to a malformed
  /// sample: a partially-applied mask is a visible artifact on the user's
  /// screen, and there is no version of it that is better than none.
  public init(cells: [Double]) {
    guard cells.count == PanelGrid.cellCount else {
      self.cells = [Double](repeating: 0, count: PanelGrid.cellCount)
      return
    }
    self.cells = cells.map(Self.quantize)
  }

  public static func uniform(_ alpha: Double) -> OverlayMask {
    OverlayMask(cells: [Double](repeating: alpha, count: PanelGrid.cellCount))
  }

  static func quantize(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    let clamped = min(1, max(0, value))
    return (clamped * levels).rounded() / levels
  }

  /// True when every cell carries the same value, so the caller can skip the
  /// mask entirely and use the scalar path it already has.
  public var isUniform: Bool {
    guard let first = cells.first else { return true }
    return cells.allSatisfy { $0 == first }
  }

  public var peak: Double { cells.max() ?? 0 }

  /// Composes two masks as two sheets of tint over one another: the light that
  /// survives both is the product of what each lets through, so the combined
  /// opacity is `1 - (1 - a)(1 - b)`.
  ///
  /// **Not `max`.** `max` satisfies "never lighter", which is the rule this has
  /// to obey, and it was what shipped first. But it also makes the feature a
  /// no-op wherever it matters: a 0.15 nomination under a 0.5 idle dim composes
  /// to `max(0.5, 0.15)` = 0.5, identical to its surroundings, so the region a
  /// user turned this on to protect is dimmed exactly as much as the region
  /// beside it. Worse, the result is UNIFORM, which is the input that made the
  /// caller's `alpha = 1.0` convention paint the panel opaque black.
  ///
  /// The product form is both correct and strictly darker: the same pair
  /// composes to 0.575, and it can only reach 1.0 if one input already is.
  public func darkened(by other: OverlayMask) -> OverlayMask {
    OverlayMask(cells: zip(cells, other.cells).map { 1 - (1 - $0) * (1 - $1) })
  }

  /// A mask already turned into the display's own orientation, ready to render.
  ///
  /// A distinct type rather than a tuple because it is what crosses into the
  /// AppKit island, and the boundary is worth naming: the rotation lives in
  /// CandelaKit where it is tested, and `OledOverlay` renders whatever it is
  /// handed without knowing the convention. It is `Equatable` so the overlay's
  /// memoized apply keeps working, which is the constraint that shapes this
  /// whole type.
  public struct Oriented: Equatable, Sendable {
    public let cells: [Double]
    public let cols: Int
    public let rows: Int

    public var isUniform: Bool {
      guard let first = cells.first else { return true }
      return cells.allSatisfy { $0 == first }
    }
  }

  /// Re-expresses the mask in DISPLAY orientation, which is the space the
  /// overlay window is drawn in.
  ///
  /// Returns the grid transposed as the rotation requires, so a mask hot in the
  /// panel's top-right comes back hot in the display's top-left at 270°. The
  /// caller renders it as an image and lets the GPU interpolate; this method
  /// does no smoothing of its own, because a 24x10 grid magnified with a linear
  /// filter is already the gradient OC17 asks for and a second blur here would
  /// only cost fidelity.
  public func displayOriented(through transform: PanelSpaceTransform) -> Oriented {
    let swaps = transform.rotation.swapsAxes
    let cols = swaps ? PanelGrid.rows : PanelGrid.cols
    let rows = swaps ? PanelGrid.cols : PanelGrid.rows
    var out = [Double](repeating: 0, count: cols * rows)

    // Walk the DESTINATION so every display cell is written exactly once; the
    // reverse walk would leave holes wherever the mapping is not onto.
    for row in 0..<rows {
      for col in 0..<cols {
        let u = (Double(col) + 0.5) / Double(cols)
        let v = (Double(row) + 0.5) / Double(rows)
        let (p, q) = transform.panelPointForDisplay(u: u, v: v)
        let panelCol = min(PanelGrid.cols - 1, max(0, Int(p * Double(PanelGrid.cols))))
        let panelRow = min(PanelGrid.rows - 1, max(0, Int(q * Double(PanelGrid.rows))))
        out[row * cols + col] = cells[panelRow * PanelGrid.cols + panelCol]
      }
    }
    return Oriented(cells: out, cols: cols, rows: rows)
  }
}
