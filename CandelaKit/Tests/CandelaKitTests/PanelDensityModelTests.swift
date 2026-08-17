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
}
