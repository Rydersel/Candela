import Foundation

/// Nominates panel regions for detection dimming (#20).
///
/// **The conjunction is the feature.** A cell is nominated only when it is both
/// persistently bright and covered by a window whose bounds have not moved past
/// `WindowObserver.stationaryThresholdSeconds`. Neither half stands alone:
/// brightness by itself nominates a playing video, whose bounds sit still while
/// every pixel under them changes, and dimming someone's film is the failure
/// that loses trust outright. Staticness by itself nominates a dark-mode
/// terminal, which is not wearing the panel, so the dim is spent where there is
/// nothing to protect.
///
/// Pure and static: everything arrives as an argument, including the grid, so
/// the coordinator owns the sampling cadence and this type owns only the rule.
public struct StaticRegionDetector: Sendable {

  public struct Thresholds: Equatable, Sendable {
    /// Linear luminance a cell must reach, 0...1.
    public let minimumLuminance: Double
    /// Overlay OPACITY applied to a nominated cell, matching `OverlayMask`:
    /// 0 covers nothing, 1 is opaque.
    public let depth: Double

    /// **Unmeasured, and it should stay labelled that way until a real sample
    /// runs on this machine.** What can be said is where it sits: the grid is
    /// LINEAR luminance, because `LuminanceSampler` applies the sRGB EOTF
    /// before the Rec. 709 weights, so encoded values spread much further apart
    /// than they look. A dark-mode window at #1E1E1E lands at 0.013, mid grey
    /// at 0.216, light-mode chrome at #F2F2F7 at 0.887. This number sits above
    /// mid grey and well below light chrome, which is the separation the
    /// conjunction is written about; the exact placement inside that gap is a
    /// guess to tune on hardware.
    public static let defaultMinimumLuminance: Double = 0.5

    /// Also a guess. #20 alters the screen while the user is working, so the
    /// default errs subtle: about 15% coverage is enough to cut drive current
    /// on a nominated region without reading as a fault in the display.
    public static let defaultDepth: Double = 0.15

    public static let `default` = Thresholds()

    /// Non-finite maps to the fail-closed end of each range rather than to the
    /// default. This is the one feature that changes the screen during active
    /// use, so a malformed threshold must nominate less, never more.
    public init(
      minimumLuminance: Double = defaultMinimumLuminance,
      depth: Double = defaultDepth
    ) {
      self.minimumLuminance = minimumLuminance.isNaN ? 1 : min(1, max(0, minimumLuminance))
      self.depth = depth.isNaN ? 0 : min(1, max(0, depth))
    }
  }

  /// `recentGrid` is per-cell linear luminance in PANEL-PHYSICAL order,
  /// `PanelGrid.cellCount` long, matching `ExposureMap.cells`.
  ///
  /// Returns nil when nothing qualifies, which the caller needs to be
  /// distinguishable from a mask that is present but all zeros: the first means
  /// skip the mask entirely and keep the cheap uniform-alpha path.
  ///
  /// No feathering here. The renderer magnifies 24×10 with a linear filter and
  /// that is what produces OC17's falloff; smoothing the nomination as well
  /// would blur an edge twice and buy nothing.
  public static func nominate(
    recentGrid: [Double],
    observation: WindowObservation,
    thresholds: Thresholds
  ) -> OverlayMask? {
    // Read from the window list, never inferred from the grid: a full-screen
    // window is identifiable exactly by bounds and layer, where a 24×10 grid
    // can only guess.
    guard observation.fullScreenOwner == nil else { return nil }

    // All or nothing, the rule `ExposureAccumulator` applies to a malformed
    // sample. A partially applied mask is a visible artifact on the user's
    // screen and there is no version of it better than none. The flag-array
    // length is not decoration either: relaxing it to a minimum traps on the
    // cell walk below, verified by mutating it.
    guard recentGrid.count == PanelGrid.cellCount,
      observation.stationaryByCell.count == PanelGrid.cellCount
    else { return nil }
    // Deliberately no upper bound: the sampler's weighted sum of linearized
    // channels can land a hair above 1 on an all-white cell, and refusing the
    // grid there would disable the feature exactly where it matters most.
    guard recentGrid.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }

    var cells = [Double](repeating: 0, count: PanelGrid.cellCount)
    for cell in cells.indices
    where recentGrid[cell] >= thresholds.minimumLuminance
      && observation.stationaryByCell[cell]
    {
      cells[cell] = thresholds.depth
    }

    let mask = OverlayMask(cells: cells)
    // Checked AFTER construction so a depth that survives the clamp but rounds
    // away under the 1/255 quantization is caught too: that mask is all zeros,
    // which is the case this returns nil for.
    guard mask.peak > 0 else { return nil }
    return mask
  }
}
