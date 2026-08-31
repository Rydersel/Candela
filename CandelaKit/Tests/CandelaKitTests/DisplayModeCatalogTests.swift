import Foundation
import Testing
@testable import CandelaKit

@Suite("Display mode curation")
struct DisplayModeCatalogTests {
  private var dell: [DisplayMode] { DisplayModeFixtures.dell }
  private var mag: [DisplayMode] { DisplayModeFixtures.mag }

  private func curatedDell() -> [DisplayModeRow] {
    DisplayModeCatalog.curated(dell,
                              nativePixelWidth: DisplayModeFixtures.dellNativePixels.0,
                              nativePixelHeight: DisplayModeFixtures.dellNativePixels.1)
  }

  /// With no declared physical size the floor is a fraction of the native
  /// minor axis, so this states the fraction rule rather than the flat 720 it
  /// replaced. The Dell is where the fraction was calibrated: 0.33 of 2160 is
  /// 713, which admits exactly what the old constant did on this panel.
  @Test func curationDropsModesBelowTheFractionOfNativeFloor() {
    let floor = Int(
      (Double(min(DisplayModeFixtures.dellNativePixels.0,
                  DisplayModeFixtures.dellNativePixels.1))
        * PanelDensityModel.fallbackFloorMinorAxisFraction).rounded())
    let rows = curatedDell()
    #expect(rows.allSatisfy { min($0.mode.logicalWidth, $0.mode.logicalHeight) >= floor })
    // The raw fixture definitely contains sub-floor junk.
    #expect(dell.contains { min($0.logicalWidth, $0.logicalHeight) < floor })
  }

  /// The acceptance case for the density floor: real aspect-correct rungs at the
  /// panel's own rate, each with a minor axis under 720 only because it is 21:9.
  /// The flat floor cut them.
  @Test func densityFloorReturnsTheMAGMidLadderRungs() {
    let modes = mag + DisplayModeFixtures.magRevealedMidLadder
    let rows = DisplayModeCatalog.curated(
      modes, nativePixelWidth: 3440, nativePixelHeight: 1440,
      geometry: PanelDensityModelTests.mag)
    let sizes = Set(rows.map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" })
    #expect(sizes.contains("1600x670"))
    #expect(sizes.contains("1344x562"))
    #expect(sizes.contains("1280x536"))
  }

  /// The other half of the same claim: a floor that admits 1280x536 must still
  /// refuse the sizes the floor exists for. 1024x429 is the near miss, one rung
  /// below the smallest kept rung on this panel.
  @Test func densityFloorStillDropsJunk() {
    let rows = DisplayModeCatalog.curated(
      mag, nativePixelWidth: 3440, nativePixelHeight: 1440,
      geometry: PanelDensityModelTests.mag)
    let sizes = Set(rows.map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" })
    #expect(!sizes.contains("400x300"))
    #expect(!sizes.contains("800x600"))
    #expect(!sizes.contains("1024x429"))
  }

  /// Someone choosing a size from this list must still find it there. Both new
  /// floors are measured against the shipped flat 720 minor axis, which is what
  /// "currently curated" means. Not against the nil-geometry call: that path is the
  /// loosest of the three and would demand the density floor keep sizes nothing
  /// ever showed.
  @Test func noCurrentlyCuratedRowDisappearsOnAnyPanel() {
    for (modes, native, geometry) in [
      (DisplayModeFixtures.mag, DisplayModeFixtures.magNativePixels,
       PanelDensityModelTests.mag),
      (DisplayModeFixtures.dell, DisplayModeFixtures.dellNativePixels,
       PanelDensityModelTests.dellRotated),
      (DisplayModeFixtures.builtIn, DisplayModeFixtures.builtInNativePixels,
       PanelDensityModelTests.builtIn),
    ] {
      // Zero native pixels reaches the flat floor, so the baseline runs through the
      // same grouping and ranking as the rows compared against it. A hand-filtered
      // list would not: curation returns representatives, not members.
      let before = Set(DisplayModeCatalog.curated(
        modes, nativePixelWidth: 0, nativePixelHeight: 0
      ).map(\.mode.ioModeID))
      #expect(!before.isEmpty)

      // Passing geometry may ADD rows; it must never remove one.
      let withDensity = Set(DisplayModeCatalog.curated(
        modes, nativePixelWidth: native.0, nativePixelHeight: native.1,
        geometry: geometry
      ).map(\.mode.ioModeID))
      #expect(before.subtracting(withDensity).isEmpty)

      // And the fraction fallback, the floor that runs when it does not.
      let withFraction = Set(DisplayModeCatalog.curated(
        modes, nativePixelWidth: native.0, nativePixelHeight: native.1
      ).map(\.mode.ioModeID))
      #expect(before.subtracting(withFraction).isEmpty)
    }
  }

  /// A virtual display declares an invented physical size, so a density taken from
  /// it is fiction. The floor refuses that geometry itself rather than trusting
  /// callers to strip it, since forgetting once floors a panel against a made-up size.
  @Test func virtualGeometryFloorsExactlyAsNoGeometryDoes() {
    let native = DisplayModeFixtures.magNativePixels
    let virtualGeometry = PanelGeometry(
      nativePixelWidth: native.0, nativePixelHeight: native.1,
      physicalWidthCm: DisplayModeFixtures.magPhysicalCm.0,
      physicalHeightCm: DisplayModeFixtures.magPhysicalCm.1, isVirtual: true)

    let asVirtual = DisplayModeCatalog.curated(
      mag, nativePixelWidth: native.0, nativePixelHeight: native.1,
      geometry: virtualGeometry)
    let asUnknown = DisplayModeCatalog.curated(
      mag, nativePixelWidth: native.0, nativePixelHeight: native.1)
    #expect(asVirtual == asUnknown)

    // And the two floors really do differ on this input, so the equality above
    // is a claim rather than a coincidence.
    #expect(asVirtual != DisplayModeCatalog.curated(
      mag, nativePixelWidth: native.0, nativePixelHeight: native.1,
      geometry: PanelDensityModelTests.mag))
  }

  @Test func fractionFallbackGovernsWithoutPhysicalSize() {
    // nil geometry: floor is a fraction of the native pixel minor axis.
    let rows = DisplayModeCatalog.curated(
      dell, nativePixelWidth: 2160, nativePixelHeight: 3840)
    let sizes = Set(rows.map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" })
    #expect(sizes.contains("720x1280"))   // 720 >= 0.33 x 2160
    #expect(!sizes.contains("300x400"))
  }

  /// Not hypothetical: `DisplayModeCoordinator` passes `native?.width ?? 0` when the
  /// native flag could not be read, and with no physical size either there is
  /// nothing left to take a fraction of.
  @Test func theFlatFloorIsTheLastResortWhenNothingAboutThePanelIsKnown() {
    let rows = DisplayModeCatalog.curated(dell, nativePixelWidth: 0, nativePixelHeight: 0)
    #expect(rows.allSatisfy {
      min($0.mode.logicalWidth, $0.mode.logicalHeight) >= DisplayModeCatalog.usabilityFloorMinorAxis
    })
    let sizes = Set(rows.map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" })
    #expect(sizes.contains("720x1280"))
    #expect(!sizes.contains("648x1152"))
  }

  /// Regression for the rotated-display bug. The development Dell runs rotated
  /// 270 degrees, where usable desktops are tall and narrow — a width-only
  /// floor cut these two entirely.
  @Test func usablePortraitModesSurviveOnARotatedDisplay() {
    let sizes = curatedDell().map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" }
    #expect(sizes.contains("945x1680"))
    #expect(sizes.contains("900x1600"))
  }

  /// The ultrawide's exact-2x native mode is the most important one on that panel,
  /// and which floor applies depends on what could be read about the panel, so it
  /// has to survive all three.
  @Test func theUltrawidesNativeHiDPIModeSurvivesEveryFloor() {
    func keepsNative(_ rows: [DisplayModeRow]) -> Bool {
      rows.contains { $0.mode.logicalWidth == 1720 && $0.mode.logicalHeight == 720 }
    }
    let native = DisplayModeFixtures.magNativePixels
    #expect(keepsNative(DisplayModeCatalog.curated(
      mag, nativePixelWidth: native.0, nativePixelHeight: native.1,
      geometry: PanelDensityModelTests.mag)))
    #expect(keepsNative(DisplayModeCatalog.curated(
      mag, nativePixelWidth: native.0, nativePixelHeight: native.1)))
    #expect(keepsNative(DisplayModeCatalog.curated(
      mag, nativePixelWidth: 0, nativePixelHeight: 0)))
  }

  @Test func curatedRowsAreSortedByDescendingLogicalArea() {
    let areas = curatedDell().map(\.mode.logicalArea)
    #expect(areas == areas.sorted(by: >))
  }

  @Test func curationKeepsOneRowPerLogicalSize() {
    let sizes = curatedDell().map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" }
    #expect(sizes.count == Set(sizes).count)
  }

  /// Scaled-ness is relative to the panel, so the SAME logical size can be
  /// native on one panel and scaled on another. This is the bug that appears
  /// if isScaled is computed against the wrong reference.
  @Test func scaledIsJudgedAgainstTheOwningPanelsNativePixels() {
    let dellRow = curatedDell().first { $0.mode.pixelWidth == 2160 && $0.mode.pixelHeight == 3840 }
    #expect(dellRow?.isScaled == false)

    let bigger = curatedDell().first { $0.mode.pixelWidth == 2880 }
    #expect(bigger?.isScaled == true)
  }

  /// The MAG's ladder tops out at its native mode — nothing above the native
  /// framebuffer exists. Curation must not invent anything.
  @Test func theStandardPPIPanelHasNoModeAboveItsNativeFramebuffer() {
    let native = DisplayModeFixtures.magNativePixels
    // The exact curated result, in order. "Nothing exceeds the native framebuffer"
    // cannot fail for any input, since curation never synthesizes modes.
    let rows = DisplayModeCatalog.curated(mag,
                                          nativePixelWidth: native.0,
                                          nativePixelHeight: native.1,
                                          geometry: PanelDensityModelTests.mag)
    #expect(rows.map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" } == ["1720x720", "1280x720"])
    #expect(rows.first?.mode.logicalWidth == 1720)
  }

  /// The fraction fallback's cost. 0.33 was calibrated on the Dell, where it lands
  /// at 713 and reproduces the old flat 720; on a 21:9 panel the same fraction of
  /// 1440 is 475, so sizes the flat floor hid come back. Paid only where the panel
  /// declares no physical size, which the MAG does, so production takes the density path.
  @Test func theFractionFallbackIsLooserOnAnUltrawideThanTheFlatFloorWas() {
    let native = DisplayModeFixtures.magNativePixels
    let rows = DisplayModeCatalog.curated(mag,
                                          nativePixelWidth: native.0,
                                          nativePixelHeight: native.1)
    #expect(rows.map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" }
            == ["1720x720", "1280x720", "960x540", "800x600", "840x525",
                "672x504", "640x512", "640x480"])
  }

  @Test func theFullListIsNeverFiltered() {
    #expect(DisplayModeCatalog.full(dell).count == dell.count)
  }

  @Test func refreshRatesAreListedForOneLogicalSizeDescending() {
    let modes = [
      DisplayMode(ioModeID: 1, logicalWidth: 2560, logicalHeight: 1440, pixelWidth: 5120,
                  pixelHeight: 2880, refreshHz: 60, isNative: false),
      DisplayMode(ioModeID: 2, logicalWidth: 2560, logicalHeight: 1440, pixelWidth: 5120,
                  pixelHeight: 2880, refreshHz: 120, isNative: false),
      DisplayMode(ioModeID: 3, logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 3840,
                  pixelHeight: 2160, refreshHz: 60, isNative: false),
    ]
    #expect(DisplayModeCatalog.refreshRates(in: modes, logicalWidth: 2560, logicalHeight: 1440) == [120, 60])
  }

  /// The representative row for a size must be its FASTEST mode, or picking
  /// "2560×1440" silently gives you 24 Hz.
  @Test func theRepresentativeRowForASizeIsItsHighestRefreshRate() {
    let modes = [
      DisplayMode(ioModeID: 1, logicalWidth: 2560, logicalHeight: 1440, pixelWidth: 5120,
                  pixelHeight: 2880, refreshHz: 24, isNative: false),
      DisplayMode(ioModeID: 2, logicalWidth: 2560, logicalHeight: 1440, pixelWidth: 5120,
                  pixelHeight: 2880, refreshHz: 120, isNative: false),
    ]
    let rows = DisplayModeCatalog.curated(modes, nativePixelWidth: 5120, nativePixelHeight: 2880)
    #expect(rows.count == 1)
    #expect(rows[0].mode.refreshHz == 120)
  }
}

/// SO18: a size row states what pressing it does. Every expectation here predicts
/// `DisplayModeCoordinator.Catalog.modeKeepingCurrentRefreshRate`. A prediction that
/// disagrees with the applier warns about a drop that does not happen, or stays
/// silent through one that does.
@Suite("Size selection outcomes (SO18)")
struct SizeSelectionOutcomeTests {
  private var ladder: [DisplayMode] { DisplayModeFixtures.magRateLadder }

  @Test func outcomeCarriesTheCurrentRateWhenTheTargetSizeOffersIt() {
    let outcome = DisplayModeCatalog.outcome(selectingWidth: 3440, selectingHeight: 1440,
                                             currentHz: 120, in: ladder)
    #expect(outcome == DisplayModeCatalog.SizeSelectionOutcome(appliedHz: 120,
                                                              lowersCurrentRate: false))
  }

  @Test func outcomeWarnsWhenTheTargetSizeCapsBelowTheCurrentRate() {
    let outcome = DisplayModeCatalog.outcome(selectingWidth: 2560, selectingHeight: 1080,
                                             currentHz: 175, in: ladder)
    #expect(outcome?.lowersCurrentRate == true)
    #expect(outcome?.appliedHz == 60)
  }

  @Test func outcomeIsNilForAnUnknownSize() {
    #expect(DisplayModeCatalog.outcome(selectingWidth: 1, selectingHeight: 1,
                                       currentHz: 60, in: ladder) == nil)
  }

  /// The applier takes the rate nearest the current one, not the size's fastest
  /// (`ModePersistence.closerRefresh`). At 75 Hz a size holding 60 and 120 lands on
  /// 60, so predicting "the fastest applies" promises 120 and hides a real drop.
  @Test func outcomeTakesTheNearestRateTheApplierWouldPickNotTheFastest() {
    let modes = [
      DisplayModeFixtures.mode(1, logical: (1600, 900), pixels: (1600, 900), hz: 60),
      DisplayModeFixtures.mode(2, logical: (1600, 900), pixels: (1600, 900), hz: 120),
    ]
    let outcome = DisplayModeCatalog.outcome(selectingWidth: 1600, selectingHeight: 900,
                                             currentHz: 75, in: modes)
    #expect(outcome?.appliedHz == 60)
    #expect(outcome?.lowersCurrentRate == true)
  }

  /// The applier resolves at the row's framebuffer, and the row for a size is its
  /// curated representative, HiDPI over 1x. A HiDPI variant offering only 60 caps a
  /// fast display even where the 1x variant at that size still lists 175.
  @Test func outcomeAnswersForTheRepresentativesFramebufferNotTheWholeLogicalSize() {
    let modes = [
      DisplayModeFixtures.mode(1, logical: (1920, 804), pixels: (3840, 1608), hz: 60),
      DisplayModeFixtures.mode(2, logical: (1920, 804), pixels: (1920, 804), hz: 175),
      DisplayModeFixtures.mode(3, logical: (1920, 804), pixels: (1920, 804), hz: 60),
    ]
    let representative = DisplayModeCatalog.curated(modes, nativePixelWidth: 3440,
                                                    nativePixelHeight: 1440).first?.mode
    #expect(representative?.pixelWidth == 3840)

    let outcome = DisplayModeCatalog.outcome(selectingWidth: 1920, selectingHeight: 804,
                                             currentHz: 175, in: modes)
    #expect(outcome?.appliedHz == 60)
    #expect(outcome?.lowersCurrentRate == true)
  }

  /// `modeKeepingCurrentRefreshRate` lives in the app target and cannot be called
  /// from here, but everything it decides comes from `ModePersistence.resolve` over
  /// the row's descriptor, so that call is reproduced exactly for every row and
  /// rate. Drift in either implementation fails here, not on a settings row.
  @Test(arguments: [DisplayModeFixtures.magRateLadder, DisplayModeFixtures.mag,
                    DisplayModeFixtures.dell])
  func outcomeAgreesWithTheApplierForEveryRowAndRate(modes: [DisplayMode]) {
    let rows = DisplayModeCatalog.curated(modes, nativePixelWidth: 3440, nativePixelHeight: 1440)
    #expect(!rows.isEmpty)

    for row in rows {
      for currentHz in DisplayModeCatalog.distinctRates(modes) {
        let wanted = DisplayModeDescriptor(
          logicalWidth: row.mode.logicalWidth, logicalHeight: row.mode.logicalHeight,
          pixelWidth: row.mode.pixelWidth, pixelHeight: row.mode.pixelHeight,
          refreshHz: currentHz
        )
        let resolved: DisplayMode? = switch ModePersistence.resolve(wanted, in: modes) {
        case let .exact(mode), let .refreshRateDiffers(mode),
             let .scaleDiffers(mode), let .sizeDiffers(mode): mode
        case .none: nil
        }
        let applied = resolved?.logicalWidth == row.mode.logicalWidth
          && resolved?.logicalHeight == row.mode.logicalHeight ? resolved! : row.mode

        let predicted = DisplayModeCatalog.outcome(
          selectingWidth: row.mode.logicalWidth, selectingHeight: row.mode.logicalHeight,
          currentHz: currentHz, in: modes
        )
        #expect(predicted?.appliedHz == DisplayMode.quantizedRefresh(applied.refreshHz),
                "\(row.mode.logicalWidth)x\(row.mode.logicalHeight) from \(currentHz) Hz")
      }
    }
  }

  /// Passing the row's own rate is what the applier does when the display has no
  /// current mode (`current?.refreshHz ?? row.mode.refreshHz`), and it must come
  /// back silent: there is no drop when the comparison point is the destination.
  @Test func theRowsOwnRateIsTheAppliersFallbackAndNeverWarns() {
    let ladder = DisplayModeFixtures.magRateLadder
    for row in DisplayModeCatalog.curated(ladder, nativePixelWidth: 3440,
                                          nativePixelHeight: 1440) {
      let outcome = DisplayModeCatalog.outcome(
        selectingWidth: row.mode.logicalWidth, selectingHeight: row.mode.logicalHeight,
        currentHz: row.mode.refreshHz, in: ladder
      )
      #expect(outcome?.appliedHz == DisplayMode.quantizedRefresh(row.mode.refreshHz))
      #expect(outcome?.lowersCurrentRate == false)
    }
  }

  /// A `0` placeholder makes every gap equal to the rate itself, so the slowest rate
  /// wins, and nothing is below zero, so the caps warning goes quiet exactly where
  /// it is needed. Callers with no current mode suppress the outcome, not pass 0.
  @Test func aZeroPlaceholderSilentlyPredictsTheSlowestRateWithNoWarning() {
    let outcome = DisplayModeCatalog.outcome(selectingWidth: 3440, selectingHeight: 1440,
                                             currentHz: 0,
                                             in: DisplayModeFixtures.magRateLadder)
    #expect(outcome?.appliedHz == 60)
    #expect(outcome?.lowersCurrentRate == false)
  }

  /// Float noise must not read as a rate change: 59.9998 is 60.
  @Test func outcomeQuantizesBeforeJudgingWhetherTheRateDropped() {
    let modes = [DisplayModeFixtures.mode(1, logical: (1600, 900), pixels: (1600, 900),
                                          hz: 59.9998)]
    let outcome = DisplayModeCatalog.outcome(selectingWidth: 1600, selectingHeight: 900,
                                             currentHz: 60, in: modes)
    #expect(outcome == DisplayModeCatalog.SizeSelectionOutcome(appliedHz: 60,
                                                              lowersCurrentRate: false))
  }
}

@Suite("Size grouping and rate filters (SO18)")
struct DisplayModeGroupingTests {
  private var ladder: [DisplayMode] { DisplayModeFixtures.magRateLadder }

  @Test func groupingIsAreaDescendingWithRateDescendingMembers() {
    let groups = DisplayModeCatalog.groupedBySize(ladder)
    let areas = groups.map { $0.logicalWidth * $0.logicalHeight }
    #expect(areas == areas.sorted(by: >))
    for group in groups {
      let rates = group.modes.map(\.refreshHz)
      #expect(rates == rates.sorted(by: >))
    }
    #expect(groups.map { "\($0.logicalWidth)x\($0.logicalHeight)" }
            == ["3440x1440", "2560x1080", "1920x1080"])
    #expect(groups.first?.modes.map(\.refreshHz) == [175, 120, 60])
  }

  /// Nothing is dropped — this list is the escape hatch, not a curation.
  @Test func groupingKeepsEveryMode() {
    let groups = DisplayModeCatalog.groupedBySize(DisplayModeFixtures.dell)
    #expect(groups.flatMap(\.modes).count == DisplayModeFixtures.dell.count)
  }

  /// Equal rates at one size must not order by dictionary iteration; the tie
  /// falls to `ioModeID`, as everywhere else in this file.
  @Test func groupMembersTieBreakOnModeID() {
    let modes = [
      DisplayModeFixtures.mode(7, logical: (1600, 900), pixels: (3200, 1800), hz: 60),
      DisplayModeFixtures.mode(3, logical: (1600, 900), pixels: (1600, 900), hz: 60),
    ]
    #expect(DisplayModeCatalog.groupedBySize(modes).first?.modes.map(\.ioModeID) == [3, 7])
  }

  @Test func distinctRatesAreQuantizedAndDeduplicated() {
    // 59.9998 and 60.0 collapse; 59.94 quantizes to 59.9 and stays distinct.
    let modes = [
      DisplayModeFixtures.mode(1, logical: (1920, 1080), pixels: (1920, 1080), hz: 59.9998),
      DisplayModeFixtures.mode(2, logical: (1920, 1080), pixels: (1920, 1080), hz: 60.0),
      DisplayModeFixtures.mode(3, logical: (1920, 1080), pixels: (1920, 1080), hz: 59.94),
    ]
    #expect(DisplayModeCatalog.distinctRates(modes) == [60.0, 59.9])
  }

  @Test func distinctRatesSpanEverySizeInTheList() {
    #expect(DisplayModeCatalog.distinctRates(ladder) == [175, 120, 60])
  }

  /// SO14: the 1x mode is tagged, never its sharp twin.
  @Test func onlyTheBlurryHalfOfAPairIsTagged() {
    let sharp = DisplayModeFixtures.mode(1, logical: (1920, 804), pixels: (3840, 1608))
    let blurry = DisplayModeFixtures.mode(2, logical: (1920, 804), pixels: (1920, 804))
    let tagged = DisplayModeCatalog.lowResolutionDuplicates([sharp, blurry])
    #expect(tagged == [blurry.ioModeID])
  }

  /// The MAG's whole 1x ladder has no HiDPI twin anywhere, and calling every
  /// resolution that display has "low resolution" would be both useless and
  /// untrue.
  @Test func aSizeWithNoSharpVariantTagsNothing() {
    #expect(DisplayModeCatalog.lowResolutionDuplicates(ladder).isEmpty)
  }

  /// The test is per SIZE, not per list: a sharp mode at 1440 × 2560 says
  /// nothing about a 1x mode at 900 × 1600.
  @Test func theSharpTwinMustBeAtTheSameLogicalSize() {
    let sharpElsewhere = DisplayModeFixtures.mode(1, logical: (1440, 2560), pixels: (2880, 5120))
    let lone = DisplayModeFixtures.mode(2, logical: (900, 1600), pixels: (900, 1600))
    #expect(DisplayModeCatalog.lowResolutionDuplicates([sharpElsewhere, lone]).isEmpty)
  }

  /// Every rate of the blurry size is tagged — the pairing is by size, and a
  /// 60 Hz row and a 120 Hz row at that size are equally low-resolution.
  @Test func everyRateOfATaggedSizeIsTagged() {
    let sharp = DisplayModeFixtures.mode(1, logical: (1920, 1080), pixels: (3840, 2160))
    let blurry60 = DisplayModeFixtures.mode(2, logical: (1920, 1080), pixels: (1920, 1080), hz: 60)
    let blurry120 = DisplayModeFixtures.mode(3, logical: (1920, 1080), pixels: (1920, 1080), hz: 120)
    #expect(DisplayModeCatalog.lowResolutionDuplicates([sharp, blurry60, blurry120])
            == [blurry60.ioModeID, blurry120.ioModeID])
  }
}
