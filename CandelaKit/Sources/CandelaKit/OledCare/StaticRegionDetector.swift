import Foundation

/// Nominates panel regions for detection dimming.
///
/// **The conjunction is the feature, but it is narrower than it sounds.** A
/// cell is nominated only when it is both bright in the latest sample and
/// covered by a window whose bounds have not moved past
/// `WindowObserver.stationaryThresholdSeconds`. Staticness alone nominates a
/// dark-mode terminal, which is not wearing the panel; brightness alone
/// nominates a region under a window being dragged.
///
/// **It does NOT exclude a windowed video, and nothing here should claim it
/// does.** Bounds stability is not content staticness, and a player holding a
/// fixed rect for five minutes passes BOTH halves. Only `fullScreenOwner`
/// protects, and only for a genuinely full-screen window. That is why OC18 calls
/// geometry a prior and never a verdict, and why the caption promises exactly
/// "full-screen video is never dimmed" and no more. A windowed player is a known
/// gap.
///
/// "Persistently" is also weaker than it reads: `recentGrid` is ONE 60-second
/// sample, not the accumulated map. Persistence comes from the staticness half
/// alone.
///
/// Pure and static: everything arrives as an argument, so the coordinator owns
/// the sampling cadence and this type owns only the rule.
public struct StaticRegionDetector: Sendable {

  public struct Thresholds: Equatable, Sendable {
    /// Linear luminance a cell must reach, 0...1.
    public let minimumLuminance: Double
    /// Overlay OPACITY applied to a nominated cell, matching `OverlayMask`:
    /// 0 covers nothing, 1 is opaque.
    public let depth: Double

    /// **Unmeasured, and it should stay labelled that way until a real sample
    /// runs.** What can be said is where it sits: the grid is LINEAR luminance,
    /// because `LuminanceSampler` applies the sRGB EOTF before the Rec. 709
    /// weights, so encoded values spread much further apart than they look. A
    /// dark-mode window at #1E1E1E lands at 0.013, mid grey at 0.216, light-mode
    /// chrome at #F2F2F7 at 0.887. This sits above mid grey and well below light
    /// chrome; the exact placement in that gap is a guess to tune on hardware.
    public static let defaultMinimumLuminance: Double = 0.5

    /// Also a guess. This feature alters the screen while the user is working,
    /// so the default errs subtle: about 15% coverage cuts drive current on a
    /// nominated region without reading as a fault in the display.
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
  /// Nil when nothing qualifies, which the caller needs distinguishable from a
  /// mask that is present but all zeros: nil means skip the mask entirely and
  /// keep the cheap uniform-alpha path.
  ///
  /// No feathering here. The renderer magnifies 24×10 with a linear filter and
  /// that is OC17's falloff; smoothing the nomination too would blur an edge
  /// twice.
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
    // sample: a partially applied mask is a visible artifact on screen. The
    // flag-array length check is not decoration either; relaxing it to a
    // minimum traps on the cell walk below.
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
