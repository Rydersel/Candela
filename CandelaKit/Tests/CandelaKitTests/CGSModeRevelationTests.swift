import Foundation
import Testing

@testable import CandelaKit

@Suite("CGS mode revelation — gates")
struct CGSModeRevelationGateTests {
  private let magW = CGSModeFixtures.magNativePixels.0
  private let magH = CGSModeFixtures.magNativePixels.1

  private func plausible(_ d: CGSModeDescriptor) -> Bool {
    CGSModeRevelation.isPlausible(d, nativePixelWidth: magW, nativePixelHeight: magH)
  }

  @Test func realModesArePlausible() {
    #expect(plausible(CGSModeFixtures.magRevealed1920x804))
    #expect(plausible(CGSModeFixtures.magRevealed2048x858))
    #expect(plausible(CGSModeFixtures.magRevealedNativeAt2x))
  }

  /// An earlier experiment measured the calibration case: an intuited 320px floor rejected this.
  @Test func aSmallButRealModeIsPlausible() {
    #expect(
      CGSModeRevelation.isPlausible(
        CGSModeFixtures.dellSmallButReal,
        nativePixelWidth: CGSModeFixtures.dellNativePixels.0,
        nativePixelHeight: CGSModeFixtures.dellNativePixels.1))
  }

  @Test func pixelsInconsistentWithDensityAreImplausible() {
    #expect(!plausible(CGSModeFixtures.garbageInconsistentPixels))
  }

  @Test func absurdDensityIsImplausible() {
    #expect(!plausible(CGSModeFixtures.garbageAbsurdDensity))
  }

  @Test func aFramebufferFarAboveNativeIsImplausible() {
    // 4x native pixel COUNT is the ceiling; native-at-2x (4x count) is allowed.
    #expect(plausible(CGSModeFixtures.magRevealedNativeAt2x))
    let tooBig = CGSModeDescriptor(
      modeNumber: 999, flags: 1, logicalWidth: 5000, logicalHeight: 2093,
      pixelWidth: 10000, pixelHeight: 4186, refreshHz: 60, density: 2.0)
    #expect(!plausible(tooBig))
  }

  @Test func zeroNativePixelsRejectsEverything() {
    #expect(
      !CGSModeRevelation.isPlausible(
        CGSModeFixtures.magRevealed1920x804, nativePixelWidth: 0, nativePixelHeight: 0))
  }

  @Test func dropCountsStartAtZero() {
    let counts = CGSModeRevelation.DropCounts()
    #expect(counts.alreadyKnown == 0)
    #expect(counts.unusable == 0)
    #expect(counts.implausible == 0)
    #expect(counts.notHiDPI == 0)
    #expect(counts.offAspect == 0)
    #expect(counts.noNativeParentTiming == 0)
    #expect(counts.total == 0)
  }
}

@Suite("CGS mode revelation — merge")
struct CGSModeRevelationMergeTests {
  private func revealMag(_ cgs: [CGSModeDescriptor]) -> CGSModeRevelation.RevelationResult {
    CGSModeRevelation.reveal(
      cgs: cgs,
      existing: RevealedModeFixtures.magExistingCG(),
      nativePixelWidth: CGSModeFixtures.magNativePixels.0,
      nativePixelHeight: CGSModeFixtures.magNativePixels.1,
      guardsWireTiming: true)
  }

  /// The built-in trap: same geometry, refresh 59 vs 60, SAME id.
  /// Dedup on id drops it; dedup on geometry+refresh would duplicate it.
  @Test func aModeAlreadyInCoreGraphicsIsDroppedByIDDespiteRefreshDisagreeing() {
    let result = CGSModeRevelation.reveal(
      cgs: [CGSModeFixtures.builtInDuplicate],
      existing: RevealedModeFixtures.builtInExistingCG(),
      nativePixelWidth: 3024, nativePixelHeight: 1964,
      guardsWireTiming: true)
    #expect(result.modes.isEmpty)
    #expect(result.dropped.alreadyKnown == 1)
  }

  @Test func aGenuinelyNewHiDPIModeIsRevealed() throws {
    let result = revealMag([CGSModeFixtures.magRevealed1920x804])
    #expect(result.modes.count == 1)
    let m = try #require(result.modes.first)
    #expect(m.ioModeID == 101)
    #expect(m.logicalWidth == 1920)
    #expect(m.pixelWidth == 3840)
    #expect(m.provenance == .coreGraphicsServices)
    #expect(m.isHiDPI)
  }

  /// A revealed mode is never the panel's own timing. Uses the 100 Hz rung deliberately:
  /// the wire-timing guard withholds the 120 Hz one, and `allSatisfy` over an empty list
  /// is vacuously true.
  @Test func revealedModesAreNeverNative() {
    let result = revealMag([CGSModeFixtures.magRevealedNativeAt2x100])
    #expect(result.modes.count == 1)
    #expect(result.modes.allSatisfy { !$0.isNative })
  }

  @Test func oneXModesAlreadyKnownAreDroppedAsKnown() {
    let result = revealMag([CGSModeFixtures.magOneX])
    #expect(result.modes.isEmpty)
    // It is already known by id 12, so alreadyKnown wins over notHiDPI.
    #expect(result.dropped.alreadyKnown == 1)
  }

  @Test func aOneXModeNotInCoreGraphicsIsDroppedAsNotHiDPI() {
    let novel1x = CGSModeDescriptor(
      modeNumber: 777, flags: 1, logicalWidth: 2560, logicalHeight: 1072,
      pixelWidth: 2560, pixelHeight: 1072, refreshHz: 60, density: 1.0)
    let result = revealMag([novel1x])
    #expect(result.modes.isEmpty)
    #expect(result.dropped.notHiDPI == 1)
  }

  /// 4:3 on a 2.39:1 panel would letterbox.
  @Test func offAspectModesAreDropped() {
    let result = revealMag([CGSModeFixtures.magLegacy4x3])
    #expect(result.modes.isEmpty)
    #expect(result.dropped.offAspect == 1)
  }

  @Test func unusableModesAreDropped() {
    let unusable = CGSModeDescriptor(
      modeNumber: 800, flags: CGSModeDescriptor.unusableFlag | 1,
      logicalWidth: 1920, logicalHeight: 804,
      pixelWidth: 3840, pixelHeight: 1608, refreshHz: 175, density: 2.0)
    let result = revealMag([unusable])
    #expect(result.modes.isEmpty)
    #expect(result.dropped.unusable == 1)
  }

  @Test func implausibleModesAreDropped() {
    let result = revealMag([CGSModeFixtures.garbageInconsistentPixels])
    #expect(result.modes.isEmpty)
    #expect(result.dropped.implausible == 1)
  }

  // MARK: Refresh borrowing

  @Test func refreshIsBorrowedFromCoreGraphicsWhenWithinOneHz() {
    #expect(CGSModeRevelation.resolveRefresh(truncated: 59, against: [60.0, 120.0]) == 60.0)
  }

  @Test func refreshIsKeptVerbatimWhenNothingIsClose() {
    #expect(CGSModeRevelation.resolveRefresh(truncated: 175, against: [60.0, 120.0]) == 175.0)
  }

  @Test func refreshBorrowingPicksTheClosestCandidate() {
    #expect(CGSModeRevelation.resolveRefresh(truncated: 59, against: [59.94, 60.0]) == 59.94)
  }

  @Test func refreshBorrowingBreaksTiesTowardTheLargerValue() {
    // 59 is equidistant from 58.5 and 59.5.
    #expect(CGSModeRevelation.resolveRefresh(truncated: 59, against: [58.5, 59.5]) == 59.5)
  }

  // MARK: Degenerate inputs

  @Test func emptyInputsReturnEmpty() {
    #expect(revealMag([]).modes.isEmpty)
  }

  /// Fail closed with no CoreGraphics list to judge against: an empty list is no evidence
  /// about what the panel advertises, and a mode that crops the desktop can only be avoided,
  /// never detected afterwards. Unreachable in production, since the native pixel size is
  /// derived from a member of this very list, but pinned rather than left to chance.
  @Test func noCoreGraphicsListMeansNoRevealedModes() {
    let noExisting = CGSModeRevelation.reveal(
      cgs: [CGSModeFixtures.magRevealed1920x804], existing: [],
      nativePixelWidth: 3440, nativePixelHeight: 1440,
      guardsWireTiming: true)
    #expect(noExisting.modes.isEmpty)
    #expect(noExisting.dropped.noNativeParentTiming == 1)

    // And the gate is what did it — unguarded, the same input reveals.
    let unguarded = CGSModeRevelation.reveal(
      cgs: [CGSModeFixtures.magRevealed1920x804], existing: [],
      nativePixelWidth: 3440, nativePixelHeight: 1440,
      guardsWireTiming: false)
    #expect(unguarded.modes.count == 1)
  }

  @Test func zeroNativePixelsRevealsNothingRatherThanCrashing() {
    let result = CGSModeRevelation.reveal(
      cgs: [CGSModeFixtures.magRevealed1920x804],
      existing: RevealedModeFixtures.magExistingCG(),
      nativePixelWidth: 0, nativePixelHeight: 0,
      guardsWireTiming: true)
    #expect(result.modes.isEmpty)
  }

  @Test func theFullMagLadderSurvivesTogether() {
    let result = revealMag([
      CGSModeFixtures.magRevealed1920x804,
      CGSModeFixtures.magRevealed2048x858,
      CGSModeFixtures.magRevealedNativeAt2x100,
      CGSModeFixtures.magLegacy4x3,
      CGSModeFixtures.magOneX,
    ])
    #expect(result.modes.count == 3)
    #expect(result.dropped.offAspect == 1)
    #expect(result.dropped.alreadyKnown == 1)
    #expect(result.dropped.noNativeParentTiming == 0)
    #expect(result.modes.allSatisfy { $0.provenance == .coreGraphicsServices })
  }
}

@Suite("Revealed modes reach the curated picker")
struct RevealedModeCurationTests {
  private let nativeW = 3440
  private let nativeH = 1440

  /// CoreGraphics publishes a 1x mode at a logical size and revelation adds a 2x mode at
  /// the same size, so both land in one curation group and only one row survives.
  private func collidingPair(logicalWidth: Int, logicalHeight: Int, cgID: Int32, cgsID: Int32)
    -> [DisplayMode]
  {
    [
      DisplayMode(
        ioModeID: cgID, logicalWidth: logicalWidth, logicalHeight: logicalHeight,
        pixelWidth: logicalWidth, pixelHeight: logicalHeight, refreshHz: 175,
        isNative: false, provenance: .coreGraphics),
      DisplayMode(
        ioModeID: cgsID, logicalWidth: logicalWidth, logicalHeight: logicalHeight,
        pixelWidth: logicalWidth * 2, pixelHeight: logicalHeight * 2, refreshHz: 175,
        isNative: false, provenance: .coreGraphicsServices),
    ]
  }

  /// The defect this suite exists for: curation tie-broke on the lower ioModeID, and
  /// CoreGraphics ids are lower than revealed ones, so the blurry 1x mode won its size
  /// group and the revealed 2x mode never reached the picker.
  @Test func aRevealedHiDPIModeBeatsTheOneXModeAtTheSameSize() throws {
    let rows = DisplayModeCatalog.curated(
      collidingPair(logicalWidth: 1920, logicalHeight: 804, cgID: 57, cgsID: 101),
      nativePixelWidth: nativeW, nativePixelHeight: nativeH)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.mode.isHiDPI)
    #expect(row.mode.ioModeID == 101)
    #expect(row.mode.pixelWidth == 3840)
  }

  /// Preferring HiDPI must not displace the panel's own timing: the native row is what a
  /// user reads as native resolution, and a 2x variant there makes the default 6880x2880.
  @Test func theNativeModeKeepsItsOwnSizeGroup() throws {
    let modes = [
      DisplayMode(
        ioModeID: 69, logicalWidth: 3440, logicalHeight: 1440,
        pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175,
        isNative: true, provenance: .coreGraphics),
      DisplayMode(
        ioModeID: 109, logicalWidth: 3440, logicalHeight: 1440,
        pixelWidth: 6880, pixelHeight: 2880, refreshHz: 120,
        isNative: false, provenance: .coreGraphicsServices),
    ]
    let rows = DisplayModeCatalog.curated(
      modes, nativePixelWidth: nativeW, nativePixelHeight: nativeH)
    let row = try #require(rows.first { $0.mode.logicalWidth == 3440 })
    #expect(row.mode.isNative)
    #expect(row.mode.ioModeID == 69)
  }

  /// HiDPI preference outranks refresh, because sharpness is the reason the
  /// feature exists and the full list remains the escape hatch for the rest.
  @Test func hiDPIOutranksAFasterOneXMode() throws {
    let modes = [
      DisplayMode(
        ioModeID: 57, logicalWidth: 1920, logicalHeight: 804,
        pixelWidth: 1920, pixelHeight: 804, refreshHz: 175,
        isNative: false, provenance: .coreGraphics),
      DisplayMode(
        ioModeID: 104, logicalWidth: 1920, logicalHeight: 804,
        pixelWidth: 3840, pixelHeight: 1608, refreshHz: 60,
        isNative: false, provenance: .coreGraphicsServices),
    ]
    let rows = DisplayModeCatalog.curated(
      modes, nativePixelWidth: nativeW, nativePixelHeight: nativeH)
    #expect(try #require(rows.first).mode.isHiDPI)
  }

  /// Among equally-HiDPI modes the fastest still wins, and ties are still
  /// broken deterministically on id.
  @Test func amongHiDPIModesTheFastestStillWins() throws {
    let modes = [
      DisplayMode(
        ioModeID: 104, logicalWidth: 1920, logicalHeight: 804,
        pixelWidth: 3840, pixelHeight: 1608, refreshHz: 60,
        isNative: false, provenance: .coreGraphicsServices),
      DisplayMode(
        ioModeID: 101, logicalWidth: 1920, logicalHeight: 804,
        pixelWidth: 3840, pixelHeight: 1608, refreshHz: 175,
        isNative: false, provenance: .coreGraphicsServices),
    ]
    let rows = DisplayModeCatalog.curated(
      modes, nativePixelWidth: nativeW, nativePixelHeight: nativeH)
    #expect(try #require(rows.first).mode.refreshHz == 175)
  }
}
