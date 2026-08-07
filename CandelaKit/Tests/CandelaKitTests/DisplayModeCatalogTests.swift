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

  @Test func curationDropsModesBelowTheUsabilityFloor() {
    let rows = curatedDell()
    #expect(rows.allSatisfy {
      min($0.mode.logicalWidth, $0.mode.logicalHeight) >= DisplayModeCatalog.usabilityFloorMinorAxis
    })
    // The raw fixture definitely contains sub-floor junk.
    #expect(dell.contains {
      min($0.logicalWidth, $0.logicalHeight) < DisplayModeCatalog.usabilityFloorMinorAxis
    })
  }

  /// Regression for the rotated-display bug. The development Dell runs rotated
  /// 270 degrees, where usable desktops are tall and narrow — a width-only
  /// floor cut these two entirely.
  @Test func usablePortraitModesSurviveOnARotatedDisplay() {
    let sizes = curatedDell().map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" }
    #expect(sizes.contains("945x1680"))
    #expect(sizes.contains("900x1600"))
  }

  /// The ultrawide's exact-2x native mode is 1720x720. Its minor axis is 720,
  /// so any floor above that removes the single most important mode on that
  /// panel — which is why the floor is 720 and not 768.
  @Test func theUltrawidesNativeHiDPIModeSurvivesTheFloor() {
    let rows = DisplayModeCatalog.curated(mag,
                                          nativePixelWidth: DisplayModeFixtures.magNativePixels.0,
                                          nativePixelHeight: DisplayModeFixtures.magNativePixels.1)
    #expect(rows.contains { $0.mode.logicalWidth == 1720 && $0.mode.logicalHeight == 720 })
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
    let rows = DisplayModeCatalog.curated(mag,
                                          nativePixelWidth: DisplayModeFixtures.magNativePixels.0,
                                          nativePixelHeight: DisplayModeFixtures.magNativePixels.1)
    // The exact curated result, in order — a tautology like "nothing exceeds
    // the native framebuffer" cannot fail for any input, since curation never
    // synthesizes modes. This pins the floor AND the grouping by name.
    #expect(rows.map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" } == ["1720x720", "1280x720"])
    #expect(rows.first?.mode.logicalWidth == 1720)
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

/// SO18: a size row states what pressing it DOES.
///
/// Every expectation here is a prediction of `DisplayModeCoordinator.Catalog
/// .modeKeepingCurrentRefreshRate`, which resolves the row's geometry at the
/// display's current rate through `ModePersistence.resolve`. A prediction that
/// disagrees with the applier is worse than no prediction: the row would warn
/// about a drop that does not happen, or stay silent through one that does.
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

  /// The applier takes the rate NEAREST the current one, not the size's
  /// fastest (`ModePersistence.closerRefresh`, reached through step 1 of
  /// `resolve`). At 75 Hz — a rate both development panels really offer — a
  /// size holding 60 and 120 lands on 60, so a prediction of "the fastest
  /// rate applies" would promise 120 and suppress the warning for a real drop.
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

  /// The applier resolves at the ROW's framebuffer, and the row for a size is
  /// its curated representative — HiDPI over 1x. A revealed HiDPI variant
  /// offering only 60 therefore caps a 175 Hz display, even though the 1x
  /// variant at the same logical size still lists 175.
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

  /// The prediction, executed against the engine it predicts.
  ///
  /// `modeKeepingCurrentRefreshRate` lives in the app target and cannot be
  /// called from here, but everything it decides comes from
  /// `ModePersistence.resolve` over the curated row's descriptor at the
  /// current rate — so that call is reproduced exactly, for every curated row
  /// against every rate the list contains. A drift in either implementation
  /// fails here rather than showing a wrong warning on a settings row.
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
}
