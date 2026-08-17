import Testing
@testable import CandelaKit

@Suite struct PanelDensityModelTests {
  // Physical sizes come from the measured fixtures symbolically, never as
  // literals: the derivation reads only the major axis, so it must not care
  // which field the fixture puts it in. The Dell case pairs rotated pixel
  // dimensions with the fixture's declared size deliberately.
  static let mag = PanelGeometry(
    nativePixelWidth: 3440, nativePixelHeight: 1440,
    physicalWidthCm: DisplayModeFixtures.magPhysicalCm.0,
    physicalHeightCm: DisplayModeFixtures.magPhysicalCm.1, isVirtual: false)
  static let dellRotated = PanelGeometry(
    nativePixelWidth: 2160, nativePixelHeight: 3840,
    physicalWidthCm: DisplayModeFixtures.dellPhysicalCm.0,
    physicalHeightCm: DisplayModeFixtures.dellPhysicalCm.1, isVirtual: false)
  static let builtIn = PanelGeometry(
    nativePixelWidth: DisplayModeFixtures.builtInNativePixels.0,
    nativePixelHeight: DisplayModeFixtures.builtInNativePixels.1,
    physicalWidthCm: DisplayModeFixtures.builtInPhysicalCm.0,
    physicalHeightCm: DisplayModeFixtures.builtInPhysicalCm.1, isVirtual: false)

  @Test func physicalPPIPairsMajorAxes() throws {
    // The Dell arrives rotated: pixel major 3840 pairs with the physical
    // major axis regardless of which field holds it.
    let ppi = try #require(PanelDensityModel.physicalPPI(Self.dellRotated))
    #expect(ppi > 150 && ppi < 180)
  }

  @Test func standardPPIPanelReadsNearOneTen() throws {
    let ppi = try #require(PanelDensityModel.physicalPPI(Self.mag))
    #expect(ppi > 100 && ppi < 120)
  }

  @Test func missingPhysicalSizeYieldsNil() {
    let g = PanelGeometry(nativePixelWidth: 3440, nativePixelHeight: 1440,
                          physicalWidthCm: nil, physicalHeightCm: nil,
                          isVirtual: false)
    #expect(PanelDensityModel.physicalPPI(g) == nil)
  }

  @Test func implausibleSizeYieldsNilNotAGuess() {
    // A 1 cm 4K panel would read thousands of PPI: garbage EDID, abstain.
    let g = PanelGeometry(nativePixelWidth: 3840, nativePixelHeight: 2160,
                          physicalWidthCm: 1, physicalHeightCm: 1,
                          isVirtual: false)
    #expect(PanelDensityModel.physicalPPI(g) == nil)
  }

  @Test func looksLikeDensityOfTheClassicRung() throws {
    // looks-like 2560x1440 on the rotated Dell is logical 1440x2560.
    let d = try #require(PanelDensityModel.looksLikePPI(
      logicalWidth: 1440, logicalHeight: 2560, in: Self.dellRotated))
    #expect(PanelDensityModel.bandLooksLikePPI.contains(d))
  }

  @Test func nativeAtOneXOnHighPPIPanelIsAboveBand() throws {
    let d = try #require(PanelDensityModel.looksLikePPI(
      logicalWidth: 2160, logicalHeight: 3840, in: Self.dellRotated))
    #expect(d > PanelDensityModel.bandLooksLikePPI.upperBound)
  }

  @Test func magNativeIsInBand() throws {
    let d = try #require(PanelDensityModel.looksLikePPI(
      logicalWidth: 3440, logicalHeight: 1440, in: Self.mag))
    #expect(PanelDensityModel.bandLooksLikePPI.contains(d))
  }

  @Test func looksLikePPIAbstainsOnImplausibleGeometry() {
    let g = PanelGeometry(nativePixelWidth: 3840, nativePixelHeight: 2160,
                          physicalWidthCm: 1, physicalHeightCm: 1, isVirtual: false)
    #expect(PanelDensityModel.looksLikePPI(logicalWidth: 1920, logicalHeight: 1080, in: g) == nil)
  }

  @Test func dellAtNativeGetsTheClassicRecommendation() {
    let rows = DisplayModeCatalog.curated(
      DisplayModeFixtures.dell, nativePixelWidth: 2160, nativePixelHeight: 3840)
    let verdict = PanelDensityModel.evaluate(
      rows: rows, currentLogicalWidth: 2160, currentLogicalHeight: 3840,
      geometry: Self.dellRotated)
    #expect(verdict.currentPlacement == .above)
    #expect(verdict.recommendation?.logicalWidth == 1440)
    #expect(verdict.recommendation?.logicalHeight == 2560)
    #expect(verdict.ideal?.servedToday == true)
    // A recommendation is the best in-band candidate, so the mark and the
    // callout name the same size whenever both are showing.
    #expect(verdict.bestInBand == verdict.recommendation)
  }

  @Test func dellAlreadyOnTheRungAbstainsAsCurrentIsBest() {
    let rows = DisplayModeCatalog.curated(
      DisplayModeFixtures.dell, nativePixelWidth: 2160, nativePixelHeight: 3840)
    let verdict = PanelDensityModel.evaluate(
      rows: rows, currentLogicalWidth: 1440, currentLogicalHeight: 2560,
      geometry: Self.dellRotated)
    #expect(verdict.recommendation == nil)
    #expect(verdict.abstention == .currentIsBest)
    // The endorsement outlives the abstention: the size in use is still the
    // one the model would pick, so the mark stays on it.
    #expect(verdict.bestInBand?.logicalWidth == 1440)
    #expect(verdict.bestInBand?.logicalHeight == 2560)
  }

  /// The other in-band abstention, where the mark lands on a size the display
  /// is NOT running: three of the Dell's rungs are in band, so a person sitting
  /// on the coarsest of them needs no correction while the best one is still
  /// worth pointing at.
  @Test func dellInBandButNotOnTheBestRungStillNamesIt() {
    let rows = DisplayModeCatalog.curated(
      DisplayModeFixtures.dell, nativePixelWidth: 2160, nativePixelHeight: 3840)
    let verdict = PanelDensityModel.evaluate(
      rows: rows, currentLogicalWidth: 1296, currentLogicalHeight: 2304,
      geometry: Self.dellRotated)
    #expect(verdict.currentPlacement == .inBand)
    #expect(verdict.recommendation == nil)
    #expect(verdict.abstention == .currentInBand)
    #expect(verdict.bestInBand?.logicalWidth == 1440)
    #expect(verdict.bestInBand?.logicalHeight == 2560)
  }

  @Test func magAtNativeAbstainsInBand() {
    let rows = DisplayModeCatalog.curated(
      DisplayModeFixtures.mag, nativePixelWidth: 3440, nativePixelHeight: 1440)
    let verdict = PanelDensityModel.evaluate(
      rows: rows, currentLogicalWidth: 3440, currentLogicalHeight: 1440,
      geometry: Self.mag)
    #expect(verdict.recommendation == nil)
    #expect(verdict.abstention == .currentInBand)
    // The published HiDPI ladder tops out at 1720x720, roughly 55 PPI, so
    // nothing here is in band and there is no size to endorse.
    #expect(verdict.bestInBand == nil)
  }

  /// The MAG as macOS really presents it, 1x rungs included: its native size is
  /// then a candidate, it wins, and the display is already running it. The mark
  /// belongs on that row even though the model has nothing to say.
  @Test func magAtNativeWearsTheMarkOnItsOwnNativeSize() {
    let rows = DisplayModeCatalog.curated(
      DisplayModeFixtures.mag + DisplayModeFixtures.magRateLadder,
      nativePixelWidth: 3440, nativePixelHeight: 1440)
    let verdict = PanelDensityModel.evaluate(
      rows: rows, currentLogicalWidth: 3440, currentLogicalHeight: 1440,
      geometry: Self.mag)
    #expect(verdict.recommendation == nil)
    #expect(verdict.abstention == .currentIsBest)
    #expect(verdict.bestInBand?.logicalWidth == 3440)
    #expect(verdict.bestInBand?.logicalHeight == 1440)
  }

  @Test func virtualDisplayAbstainsBeforeAnythingElse() {
    let g = PanelGeometry(nativePixelWidth: 3840, nativePixelHeight: 2160,
                          physicalWidthCm: 60, physicalHeightCm: 34,
                          isVirtual: true)
    let verdict = PanelDensityModel.evaluate(
      rows: [], currentLogicalWidth: nil, currentLogicalHeight: nil, geometry: g)
    #expect(verdict.abstention == .virtualDisplay)
    #expect(verdict.ideal == nil)
    // No ranking happened, so there is nothing to mark either.
    #expect(verdict.bestInBand == nil)
  }

  @Test func noPhysicalSizeAbstainsWithNoIdeal() {
    let g = PanelGeometry(nativePixelWidth: 3440, nativePixelHeight: 1440,
                          physicalWidthCm: nil, physicalHeightCm: nil,
                          isVirtual: false)
    let verdict = PanelDensityModel.evaluate(
      rows: [], currentLogicalWidth: 3440, currentLogicalHeight: 1440, geometry: g)
    #expect(verdict.abstention == .noPhysicalSize)
    #expect(verdict.ideal == nil)
    #expect(verdict.bestInBand == nil)
  }

  @Test func idealIsAspectExactAndEven() throws {
    let verdict = PanelDensityModel.evaluate(
      rows: [], currentLogicalWidth: nil, currentLogicalHeight: nil,
      geometry: Self.dellRotated)
    let ideal = try #require(verdict.ideal)
    #expect(ideal.logicalWidth % 2 == 0)
    #expect(ideal.logicalHeight % 2 == 0)
    // Aspect within a percent of native.
    let native = Double(2160) / Double(3840)
    let got = Double(ideal.logicalWidth) / Double(ideal.logicalHeight)
    #expect(abs(got - native) / native < 0.01)
    #expect(ideal.servedToday == false)   // no rows were offered
  }

  @Test func rankingIsOrderIndependent() {
    let rows = DisplayModeCatalog.curated(
      DisplayModeFixtures.dell, nativePixelWidth: 2160, nativePixelHeight: 3840)
    let forward = PanelDensityModel.evaluate(
      rows: rows, currentLogicalWidth: 2160, currentLogicalHeight: 3840,
      geometry: Self.dellRotated)
    let backward = PanelDensityModel.evaluate(
      rows: rows.reversed(), currentLogicalWidth: 2160, currentLogicalHeight: 3840,
      geometry: Self.dellRotated)
    #expect(forward == backward)
  }

  /// The tie-break past the density gap is only reachable when two candidates
  /// are EXACTLY equal at the first comparison, which the major-axis derivation
  /// makes routine: the built-in panel offers three pairs sharing a major
  /// (1800x1125/1800x1169, 1512x945/1512x982, 1352x845/1352x878). The 1800 pair
  /// is above the band, so the two in-band pairs are what a ranking is actually
  /// asked to separate.
  ///
  /// 1280x800 is withheld deliberately. It beats both pairs on gap, so with it
  /// present no tie decides anything and a ranking cut down to its first
  /// comparison would pass. Without it the winner comes from the tie, and
  /// `min(by:)` keeps whichever tied row it saw first: the reversed run then
  /// disagrees with the forward one.
  @Test func tiedDensitiesRankTheSameWhicheverOrderTheyArriveIn() throws {
    let rows = DisplayModeCatalog.curated(
      DisplayModeFixtures.builtIn,
      nativePixelWidth: DisplayModeFixtures.builtInNativePixels.0,
      nativePixelHeight: DisplayModeFixtures.builtInNativePixels.1,
      geometry: Self.builtIn
    ).filter { $0.mode.logicalWidth != 1280 }

    func verdict(for rows: [DisplayModeRow]) -> DensityVerdict {
      // 3024x1964 is the 1x native size, far above the band, so nothing here
      // short-circuits on the current size.
      PanelDensityModel.evaluate(rows: rows, currentLogicalWidth: 3024,
                                 currentLogicalHeight: 1964, geometry: Self.builtIn)
    }
    #expect(verdict(for: rows) == verdict(for: rows.reversed()))

    // Both members of the winning pair are HiDPI, so the tie falls through to
    // logical area and the taller one takes the row.
    let picked = try #require(verdict(for: rows).recommendation)
    #expect(picked.logicalWidth == 1352)
    #expect(picked.logicalHeight == 878)
  }

  /// Abstention with physical size KNOWN, which is the state the synthesis seam
  /// exists for. Every size the ultrawide publishes is below the band once
  /// density is applied: its 2x native mode looks like roughly 55 PPI, and the
  /// panel offers nothing between that and 1x native.
  @Test func noApplicableSizeReachesTheBandOnTheUltrawide() throws {
    let rows = DisplayModeCatalog.curated(
      DisplayModeFixtures.mag,
      nativePixelWidth: DisplayModeFixtures.magNativePixels.0,
      nativePixelHeight: DisplayModeFixtures.magNativePixels.1,
      geometry: Self.mag)
    #expect(!rows.isEmpty)   // an empty list would abstain for the wrong reason

    let verdict = PanelDensityModel.evaluate(
      rows: rows, currentLogicalWidth: 1720, currentLogicalHeight: 720,
      geometry: Self.mag)
    #expect(verdict.abstention == .noCandidateInBand)
    #expect(verdict.recommendation == nil)
    #expect(verdict.bestInBand == nil)
    #expect(verdict.currentPlacement == .below)
    let ideal = try #require(verdict.ideal)
    #expect(ideal.servedToday == false)
  }
}
