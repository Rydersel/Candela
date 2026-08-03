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
    #expect(rows.allSatisfy { $0.mode.logicalWidth >= DisplayModeCatalog.usabilityFloorLogicalWidth })
    // The raw fixture definitely contains sub-floor junk.
    #expect(dell.contains { $0.logicalWidth < DisplayModeCatalog.usabilityFloorLogicalWidth })
  }

  @Test func curatedRowsAreSortedByDescendingLogicalArea() {
    let areas = curatedDell().map(\.mode.logicalArea)
    #expect(areas == areas.sorted(by: >))
  }

  @Test func curationKeepsOneRowPerLogicalSize() {
    let sizes = curatedDell().map { "\($0.mode.logicalWidth)x\($0.mode.logicalHeight)" }
    #expect(sizes.count == Set(sizes).count)
  }

  /// The whole point of the feature: a mode macOS does not surface must still
  /// reach the user.
  @Test func modesMacOSHidesSurviveCuration() {
    let hidden = curatedDell().filter { !$0.mode.surfacedByMacOS }
    #expect(!hidden.isEmpty)
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
    #expect(rows.allSatisfy { $0.mode.pixelWidth <= DisplayModeFixtures.magNativePixels.0 })
    #expect(rows.first?.mode.logicalWidth == 1720)
  }

  @Test func theFullListIsNeverFiltered() {
    #expect(DisplayModeCatalog.full(dell).count == dell.count)
  }

  @Test func refreshRatesAreListedForOneLogicalSizeDescending() {
    let modes = [
      DisplayMode(ioModeID: 1, logicalWidth: 2560, logicalHeight: 1440, pixelWidth: 5120,
                  pixelHeight: 2880, refreshHz: 60, isNative: false, surfacedByMacOS: true),
      DisplayMode(ioModeID: 2, logicalWidth: 2560, logicalHeight: 1440, pixelWidth: 5120,
                  pixelHeight: 2880, refreshHz: 120, isNative: false, surfacedByMacOS: true),
      DisplayMode(ioModeID: 3, logicalWidth: 1920, logicalHeight: 1080, pixelWidth: 3840,
                  pixelHeight: 2160, refreshHz: 60, isNative: false, surfacedByMacOS: true),
    ]
    #expect(DisplayModeCatalog.refreshRates(in: modes, logicalWidth: 2560, logicalHeight: 1440) == [120, 60])
  }

  /// The representative row for a size must be its FASTEST mode, or picking
  /// "2560×1440" silently gives you 24 Hz.
  @Test func theRepresentativeRowForASizeIsItsHighestRefreshRate() {
    let modes = [
      DisplayMode(ioModeID: 1, logicalWidth: 2560, logicalHeight: 1440, pixelWidth: 5120,
                  pixelHeight: 2880, refreshHz: 24, isNative: false, surfacedByMacOS: true),
      DisplayMode(ioModeID: 2, logicalWidth: 2560, logicalHeight: 1440, pixelWidth: 5120,
                  pixelHeight: 2880, refreshHz: 120, isNative: false, surfacedByMacOS: true),
    ]
    let rows = DisplayModeCatalog.curated(modes, nativePixelWidth: 5120, nativePixelHeight: 2880)
    #expect(rows.count == 1)
    #expect(rows[0].mode.refreshHz == 120)
    #expect(rows[0].alternateRefreshRates == [120, 24])
  }
}
