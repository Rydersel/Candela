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
    #expect(rows[0].alternateRefreshRates == [120, 24])
  }
}
