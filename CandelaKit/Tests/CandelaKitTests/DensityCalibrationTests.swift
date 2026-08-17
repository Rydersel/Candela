import Testing
@testable import CandelaKit

/// The calibration ledger the density model's constants are pinned against.
///
/// Every other suite states a RULE and picks the one or two sizes that show it.
/// This one states the OUTCOME: the complete curated size list each of the
/// three measured panels produces with its physical geometry supplied, plus the
/// band membership of the densities the band edges were chosen around. A
/// constant nudged by a point or two rarely breaks a rule, but it moves these
/// lists, and the move is the thing worth seeing.
@Suite("Density calibration ledger")
struct DensityCalibrationTests {
  private static func sizes(_ rows: [DisplayModeRow]) -> [String] {
    rows.map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" }
  }

  /// Revelation's three mid-ladder rungs are merged in deliberately: they are
  /// the sizes the flat 720 floor cut and the density floor brings back, so a
  /// ledger of the published ladder alone would not notice losing them again.
  /// They interleave by area rather than sitting at the end, which is the
  /// curated sort doing its job across two sources.
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

  /// The three densities the band edges were chosen around, each with its
  /// placement. Two must be inside or the model shouts at desktops that already
  /// look right; one must be outside or it never speaks at all.
  ///
  /// The 27-inch 5K is not a panel on the rig, so its geometry is built here:
  /// 5120x2880 in the same 27-inch shell the Dell declares, which is what makes
  /// it the reference point for "what macOS considers normal".
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
}

// These arrays ARE the calibration ledger. They are transcribed from a run, not
// reasoned out, so a failure here is not a bug report: it says a constant moved
// and these are the sizes it moved. A retune edits them deliberately, in the
// same commit as the constant, and the diff is the review artifact.
