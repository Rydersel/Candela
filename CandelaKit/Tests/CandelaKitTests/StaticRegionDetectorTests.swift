import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

@Suite("Static region detection")
struct StaticRegionDetectorTests {

  private let thresholds = StaticRegionDetector.Thresholds(minimumLuminance: 0.5, depth: 0.2)

  /// Two disjoint bands so every test can carry its own control: a case that
  /// only ever answers nil cannot tell "the rule rejected this" from "the
  /// detector rejects everything".
  private let bandA = 0..<5
  private let bandB = 100..<105

  private func grid(_ background: Double, _ bands: (Range<Int>, Double)...) -> [Double] {
    var cells = [Double](repeating: background, count: PanelGrid.cellCount)
    for (range, value) in bands {
      for cell in range { cells[cell] = value }
    }
    return cells
  }

  private func observation(
    stationary: Range<Int>..., fullScreenOwner: String? = nil
  ) -> WindowObservation {
    var flags = [Bool](repeating: false, count: PanelGrid.cellCount)
    for range in stationary {
      for cell in range { flags[cell] = true }
    }
    return WindowObservation(
      dominantOwnerByCell: [String?](repeating: nil, count: PanelGrid.cellCount),
      stationarySecondsByWindowID: [:],
      stationaryByCell: flags,
      fullScreenOwner: fullScreenOwner)
  }

  private func nominatedCells(_ mask: OverlayMask) -> Set<Int> {
    Set(mask.cells.indices.filter { mask.cells[$0] > 0 })
  }

  // MARK: - The conjunction

  @Test func aBrightStationaryRegionIsNominated() {
    let mask = StaticRegionDetector.nominate(
      recentGrid: grid(0.02, (bandB, 0.9)),
      observation: observation(stationary: bandB),
      thresholds: thresholds)

    // Confined as well as present: an implementation that nominates the whole
    // panel whenever anything qualifies passes "not nil" and fails this.
    #expect(nominatedCells(mask ?? .uniform(0)) == Set(bandB))
  }

  /// The video player. Its bounds do not move while every pixel under it does,
  /// so brightness alone would nominate it, and dimming a playing video is the
  /// failure that loses trust outright.
  @Test func aBrightMovingRegionIsNotNominated() {
    let mask = StaticRegionDetector.nominate(
      recentGrid: grid(0.02, (bandA, 0.9), (bandB, 0.9)),
      observation: observation(stationary: bandB),
      thresholds: thresholds)

    // Band A is exactly as bright as band B and differs only in staticness, so
    // a disjunction would nominate both and this asserts it does not.
    #expect(nominatedCells(mask ?? .uniform(0)) == Set(bandB))
  }

  /// The dark-mode terminal. Left open for hours and perfectly static, but it
  /// is not wearing the panel, so dimming it wastes the effect.
  @Test func aDarkStationaryRegionIsNotNominated() {
    let mask = StaticRegionDetector.nominate(
      recentGrid: grid(0.02, (bandA, 0.02), (bandB, 0.9)),
      observation: observation(stationary: bandA, bandB),
      thresholds: thresholds)

    // Band A is exactly as static as band B and differs only in luminance.
    #expect(nominatedCells(mask ?? .uniform(0)) == Set(bandB))
  }

  @Test func theLuminanceThresholdIsInclusive() {
    let atThreshold = StaticRegionDetector.nominate(
      recentGrid: grid(0, (bandB, 0.5)),
      observation: observation(stationary: bandB),
      thresholds: thresholds)
    let justBelow = StaticRegionDetector.nominate(
      recentGrid: grid(0, (bandB, 0.5 - 1e-9)),
      observation: observation(stationary: bandB),
      thresholds: thresholds)

    #expect(atThreshold != nil)
    #expect(justBelow == nil)
  }

  // MARK: - The full-screen gate

  /// Read from the window list, never inferred from the grid: the grid here is
  /// a small bright band on a dark field, which looks nothing like full-screen
  /// content, and the gate must still fire.
  @Test func nothingIsNominatedUnderAFullScreenWindow() {
    let gated = StaticRegionDetector.nominate(
      recentGrid: grid(0.02, (bandB, 0.9)),
      observation: observation(stationary: bandB, fullScreenOwner: "IINA"),
      thresholds: thresholds)
    let ungated = StaticRegionDetector.nominate(
      recentGrid: grid(0.02, (bandB, 0.9)),
      observation: observation(stationary: bandB),
      thresholds: thresholds)

    #expect(gated == nil)
    // The control: identical inputs but for the owner. Without it this test
    // would pass against a detector that never nominates anything.
    #expect(ungated != nil)
  }

  // MARK: - Nothing to nominate

  /// A bare desktop: nothing covers these cells, so `stationaryByCell` is false
  /// throughout and a bright wallpaper nominates nothing.
  @Test func anEmptyObservationNominatesNothing() {
    let empty = StaticRegionDetector.nominate(
      recentGrid: grid(0.9),
      observation: observation(),
      thresholds: thresholds)
    let covered = StaticRegionDetector.nominate(
      recentGrid: grid(0.9),
      observation: observation(stationary: bandB),
      thresholds: thresholds)

    #expect(empty == nil)
    // The control: the same grid under a window that has not moved.
    #expect(covered != nil)
  }

  /// The caller needs "no regions" to be distinguishable from "regions, all at
  /// zero depth": the first means skip the mask and keep the cheap scalar path.
  /// An implementation returning `.uniform(0)` fails on the nil check alone.
  @Test func nothingQualifyingReturnsNilRatherThanAZeroMask() {
    let nothing = StaticRegionDetector.nominate(
      recentGrid: grid(0.02),
      observation: observation(stationary: bandA),
      thresholds: thresholds)
    let something = StaticRegionDetector.nominate(
      recentGrid: grid(0.02, (bandA, 0.9)),
      observation: observation(stationary: bandA),
      thresholds: thresholds)

    #expect(nothing == nil)
    #expect(something != nil)
  }

  /// A depth that rounds away under `OverlayMask`'s 1/255 quantization leaves a
  /// mask that is all zeros despite cells having qualified, which is the same
  /// "regions, all at zero depth" the caller must never receive. One quantum up
  /// is the control, so this pins the boundary and not just the nil.
  @Test func aDepthBelowTheQuantumReturnsNil() {
    let belowQuantum = StaticRegionDetector.nominate(
      recentGrid: grid(0.9),
      observation: observation(stationary: bandB),
      thresholds: StaticRegionDetector.Thresholds(minimumLuminance: 0.5, depth: 0.001))
    let atQuantum = StaticRegionDetector.nominate(
      recentGrid: grid(0.9),
      observation: observation(stationary: bandB),
      thresholds: StaticRegionDetector.Thresholds(
        minimumLuminance: 0.5, depth: 1.0 / OverlayMask.levels))

    #expect(belowQuantum == nil)
    #expect(atQuantum != nil)
  }

  // MARK: - Depth

  @Test func aNominatedCellCarriesTheConfiguredDepthAndNotItsLuminance() {
    let mask = StaticRegionDetector.nominate(
      recentGrid: grid(0.02, (bandB, 0.9)),
      observation: observation(stationary: bandB),
      thresholds: StaticRegionDetector.Thresholds(minimumLuminance: 0.5, depth: 0.4))

    #expect(mask?.cells[bandB.lowerBound] == OverlayMask.quantize(0.4))
    #expect(mask?.cells[bandA.lowerBound] == 0)
  }

  /// Feathering belongs to the renderer's linear magnification, so the
  /// nomination edge is a step: two adjacent cells, one in and one out, must
  /// come back at exactly the two values and never at anything between.
  @Test func theNominationEdgeIsNotSmoothedHere() {
    let mask = StaticRegionDetector.nominate(
      recentGrid: grid(0.02, (bandB, 0.9)),
      observation: observation(stationary: bandB),
      thresholds: thresholds)

    let values = Set(mask?.cells ?? [])
    #expect(values == [0, OverlayMask.quantize(0.2)])
  }

  // MARK: - All-or-nothing validation

  @Test func aMalformedGridIsRejectedWholesale() {
    let stationary = observation(stationary: bandB)

    // The control: the same shape, well formed, does nominate.
    #expect(
      StaticRegionDetector.nominate(
        recentGrid: grid(0.9), observation: stationary, thresholds: thresholds) != nil)

    #expect(
      StaticRegionDetector.nominate(
        recentGrid: [Double](repeating: 0.9, count: PanelGrid.cellCount - 1),
        observation: stationary, thresholds: thresholds) == nil)
    #expect(
      StaticRegionDetector.nominate(
        recentGrid: [Double](repeating: 0.9, count: PanelGrid.cellCount + 1),
        observation: stationary, thresholds: thresholds) == nil)

    // Each of these sits OUTSIDE both bands, so a detector that merely skipped
    // the offending cell would still nominate band B and fail here.
    for bad in [Double.nan, .infinity, -.infinity, -1] {
      #expect(
        StaticRegionDetector.nominate(
          recentGrid: grid(0.9, (200..<201, bad)),
          observation: stationary, thresholds: thresholds) == nil,
        "grid carrying \(bad) must be refused whole")
    }
  }

  @Test func aMalformedObservationIsRejectedWholesale() {
    func observation(stationaryCellCount: Int) -> WindowObservation {
      WindowObservation(
        dominantOwnerByCell: [String?](repeating: nil, count: PanelGrid.cellCount),
        stationarySecondsByWindowID: [:],
        stationaryByCell: [Bool](repeating: true, count: stationaryCellCount),
        fullScreenOwner: nil)
    }

    // The control first: a full-length flag array over the same grid nominates.
    #expect(
      StaticRegionDetector.nominate(
        recentGrid: grid(0.9),
        observation: observation(stationaryCellCount: PanelGrid.cellCount),
        thresholds: thresholds) != nil)

    // A short array would nominate its first 239 cells if the detector read it
    // cell by cell, which is the partial application the all-or-nothing rule
    // exists to prevent.
    #expect(
      StaticRegionDetector.nominate(
        recentGrid: grid(0.9),
        observation: observation(stationaryCellCount: PanelGrid.cellCount - 1),
        thresholds: thresholds) == nil)
    #expect(
      StaticRegionDetector.nominate(
        recentGrid: grid(0.9),
        observation: observation(stationaryCellCount: PanelGrid.cellCount + 1),
        thresholds: thresholds) == nil)
  }

  // MARK: - Thresholds

  /// Fail closed. This feature alters the screen while the user is working, so
  /// a threshold that arrives non-finite must nominate less, never more.
  @Test func aNonFiniteLuminanceThresholdNominatesNothing() {
    func nominate(_ minimumLuminance: Double) -> OverlayMask? {
      StaticRegionDetector.nominate(
        recentGrid: grid(0.9),
        observation: observation(stationary: bandB),
        thresholds: StaticRegionDetector.Thresholds(
          minimumLuminance: minimumLuminance, depth: 0.2))
    }

    #expect(nominate(0.5) != nil)  // the control: these inputs do qualify
    #expect(nominate(.nan) == nil)
    #expect(nominate(.infinity) == nil)
  }

  @Test func aNonFiniteDepthNominatesNothing() {
    func nominate(_ depth: Double) -> OverlayMask? {
      StaticRegionDetector.nominate(
        recentGrid: grid(0.9),
        observation: observation(stationary: bandB),
        thresholds: StaticRegionDetector.Thresholds(minimumLuminance: 0.5, depth: depth))
    }

    #expect(nominate(0.2) != nil)  // the control
    #expect(nominate(.nan) == nil)
  }

  @Test func thresholdsAreClampedToTheirRanges() {
    let high = StaticRegionDetector.Thresholds(minimumLuminance: 4, depth: 9)
    #expect(high.minimumLuminance == 1)
    #expect(high.depth == 1)

    let low = StaticRegionDetector.Thresholds(minimumLuminance: -4, depth: -9)
    #expect(low.minimumLuminance == 0)
    #expect(low.depth == 0)
  }

  /// The default threshold's whole job is to sit between the two content
  /// classes the conjunction is written about. The grid is LINEAR luminance
  /// (`LuminanceSampler` applies the sRGB EOTF), so the encoded values are much
  /// further apart than they look: a dark-mode window at #1E1E1E is 0.013 and
  /// light-mode chrome at #F2F2F7 is 0.887.
  @Test func theDefaultThresholdSeparatesLightChromeFromADarkWindow() {
    let defaults = StaticRegionDetector.Thresholds.default
    #expect(defaults.minimumLuminance > 0.013)
    #expect(defaults.minimumLuminance < 0.887)
    // Mid grey (#808080) is 0.216 linear and is not what this feature is for.
    #expect(defaults.minimumLuminance > 0.216)
  }

  /// The default depth alters the screen during active use, so it stays subtle;
  /// zero would make the feature a no-op that still pays for the mask.
  @Test func theDefaultDepthIsSubtleAndNonZero() {
    let defaults = StaticRegionDetector.Thresholds.default
    #expect(defaults.depth > 1.0 / OverlayMask.levels)
    #expect(defaults.depth <= 0.3)
  }
}
