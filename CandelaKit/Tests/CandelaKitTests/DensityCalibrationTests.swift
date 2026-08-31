import Testing
@testable import CandelaKit

/// The calibration ledger the density model's constants are pinned against.
/// Other suites state a rule and pick the sizes that show it; this one states the
/// outcome, the whole curated list each measured panel produces. A constant nudged
/// by a point rarely breaks a rule, but it moves these lists.
@Suite("Density calibration ledger")
struct DensityCalibrationTests {
  private static func sizes(_ rows: [DisplayModeRow]) -> [String] {
    rows.map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" }
  }

  /// The revealed mid-ladder rungs are merged in because the flat 720 floor cut
  /// them and the density floor brings them back, which a ledger of the published
  /// ladder alone would not notice losing again. They interleave by area.
  @Test func magCuratedSetWithGeometry() {
    let rows = DisplayModeCatalog.curated(
      DisplayModeFixtures.mag + DisplayModeFixtures.magRevealedMidLadder,
      nativePixelWidth: DisplayModeFixtures.magNativePixels.0,
      nativePixelHeight: DisplayModeFixtures.magNativePixels.1,
      geometry: PanelDensityModelTests.mag)
    #expect(Self.sizes(rows) == [
      "1720x720", "1600x670", "1280x720", "1344x562", "1280x536",
    ])
  }

  @Test func dellCuratedSetWithGeometry() {
    let rows = DisplayModeCatalog.curated(
      DisplayModeFixtures.dell,
      nativePixelWidth: DisplayModeFixtures.dellNativePixels.0,
      nativePixelHeight: DisplayModeFixtures.dellNativePixels.1,
      geometry: PanelDensityModelTests.dellRotated)
    #expect(Self.sizes(rows) == [
      "1890x3360", "1800x3200", "1692x3008", "1440x2560", "1296x2304",
      "1152x2048", "1080x1920", "945x1680", "900x1600", "846x1504",
      "720x1280", "648x1152", "576x1024", "600x960", "540x960",
    ])
  }

  @Test func builtInCuratedSetWithGeometry() {
    let rows = DisplayModeCatalog.curated(
      DisplayModeFixtures.builtIn,
      nativePixelWidth: DisplayModeFixtures.builtInNativePixels.0,
      nativePixelHeight: DisplayModeFixtures.builtInNativePixels.1,
      geometry: PanelDensityModelTests.builtIn)
    #expect(Self.sizes(rows) == [
      "1800x1169", "1800x1125", "1512x982", "1512x945", "1352x878",
      "1352x845", "1280x800", "1147x745", "1147x716", "1024x665",
      "1024x640", "960x600",
    ])
  }

  /// The densities the band edges were chosen around. Two must be inside or the
  /// model shouts at desktops that already look right; one must be outside or it
  /// never speaks at all. The 27-inch 5K is not on the rig, so its geometry is
  /// built from the Dell's shell: it is the reference for what macOS calls normal.
  @Test func theBandAnchorsSitWhereTheConstantsClaim() throws {
    let fiveK = PanelGeometry(
      nativePixelWidth: 5120, nativePixelHeight: 2880,
      physicalWidthCm: DisplayModeFixtures.dellPhysicalCm.0,
      physicalHeightCm: DisplayModeFixtures.dellPhysicalCm.1, isVirtual: false)

    for (label, width, height, geometry, expected, placement) in [
      ("5K default", 2560, 1440, fiveK, 108.4, BandPlacement.inBand),
      ("built-in default", 1512, 982, PanelDensityModelTests.builtIn, 128.0, .inBand),
      ("4K at 1x", 2160, 3840, PanelDensityModelTests.dellRotated, 162.6, .above),
    ] {
      let density = try #require(
        PanelDensityModel.looksLikePPI(logicalWidth: width, logicalHeight: height,
                                       in: geometry),
        "\(label) yielded no density")
      #expect((density * 10).rounded() / 10 == expected, "\(label)")
      #expect(PanelDensityModel.bandPlacement(of: density) == placement, "\(label)")
    }
  }

  /// The anchors above sit deep inside the band or far outside it, so an edge could
  /// move several points unnoticed. These straddle the edges instead, close enough
  /// that a one-point retune shows up here first. Edge pins, not rungs anyone
  /// chooses: two are invented sizes, kept only for the density they produce.
  @Test func theBandEdgesRejectTheSizesJustOutsideThem() throws {
    for (label, width, height, geometry, expected, placement) in [
      ("just inside the low edge", 1147, 745, PanelDensityModelTests.builtIn,
       97.1, BandPlacement.inBand),
      ("just below the low edge", 1120, 727, PanelDensityModelTests.builtIn,
       94.8, .below),
      ("just inside the high edge", 1769, 3144, PanelDensityModelTests.dellRotated,
       133.1, .inBand),
      ("just above the high edge", 1800, 3200, PanelDensityModelTests.dellRotated,
       135.5, .above),
    ] {
      let density = try #require(
        PanelDensityModel.looksLikePPI(logicalWidth: width, logicalHeight: height,
                                       in: geometry),
        "\(label) yielded no density")
      #expect((density * 10).rounded() / 10 == expected, "\(label)")
      #expect(PanelDensityModel.bandPlacement(of: density) == placement, "\(label)")
    }
  }
}

// These arrays are transcribed from a run, not reasoned out, so a failure here is
// not a bug report: it says a constant moved and names the sizes it moved. A retune
// edits them in the same commit as the constant.
