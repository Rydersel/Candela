import Foundation
import Testing

@testable import CandelaKit

/// A revealed mode is scaled by definition, so the display controller binds it
/// to some real wire timing. When the panel advertises no native-width timing
/// at that refresh it gets bound to an arbitrary same-refresh timing instead,
/// and the desktop scans out pillarboxed and cropped while every software
/// readout reports success. Measured on the MAG 341C, 2026-08-07:
/// docs/spikes/2026-08-07-exact-2to1-camera-gate.md §1.
///
/// Ground truth for the whole suite:
/// docs/spikes/exact-2to1-first-engagement/01-mag-modes.txt.
@Suite("Wire-timing guard")
struct WireTimingGuardTests {
  private let magW = CGSModeFixtures.magNativePixels.0
  private let magH = CGSModeFixtures.magNativePixels.1

  private func revealMag(
    _ cgs: [CGSModeDescriptor], guarded: Bool = true
  ) -> CGSModeRevelation.RevelationResult {
    CGSModeRevelation.reveal(
      cgs: cgs,
      existing: RevealedModeFixtures.magExistingCG(),
      nativePixelWidth: magW, nativePixelHeight: magH,
      guardsWireTiming: guarded)
  }

  /// One member of the MAG's exact-2:1 family. Geometry is identical across it;
  /// only the refresh differs.
  private func magRung(id: Int32, refresh: Int) -> CGSModeDescriptor {
    CGSModeDescriptor(
      modeNumber: id, flags: 0x0020_0001,
      logicalWidth: 3440, logicalHeight: 1440,
      pixelWidth: 6880, pixelHeight: 2880, refreshHz: refresh, density: 2.0)
  }

  /// The panel's whole revealed 2:1 ladder, with the verdict for each rung.
  /// `measured` marks the four that were engaged on hardware and judged on the
  /// glass; the rest are the rule's predictions.
  private static let magLadder:
    [(id: Int32, refresh: Int, admitted: Bool, measured: Bool)] = [
      (109, 120, false, true),  // OSD read 2560x1440: pillarboxed + cropped
      (110, 100, true, true),  // OSD read 3440x1440 @ 100: correct
      (111, 75, false, true),  // OSD read 1280x1024: broken
      (112, 72, false, false),
      (113, 70, false, false),
      (114, 60, true, true),  // correct, full panel
      (115, 56, false, false),
      (116, 50, false, false),
    ]

  @Test func theMagLadderAdmitsExactlyTheRungsWithANativeWidthParent() {
    let result = revealMag(Self.magLadder.map { magRung(id: $0.id, refresh: $0.refresh) })

    let admitted = Set(result.modes.map(\.ioModeID))
    let expected = Set(Self.magLadder.filter(\.admitted).map(\.id))
    #expect(admitted == expected)
    #expect(admitted == [110, 114])

    #expect(result.dropped.noNativeParentTiming == 6)
    // Nothing else rejected them: the ladder is uniform in every other respect,
    // so a drop under any other heading would mean a different gate fired and
    // this suite was measuring the wrong thing.
    #expect(result.dropped.total == 6)
  }

  /// The counterpart that makes the test above able to fail for its stated
  /// reason: unguarded, every one of those six is otherwise perfectly
  /// acceptable and reaches the picker.
  @Test func everyWithheldRungIsAdmittedWhenTheGuardIsOff() {
    let ladder = Self.magLadder.map { magRung(id: $0.id, refresh: $0.refresh) }
    let unguarded = revealMag(ladder, guarded: false)

    #expect(unguarded.modes.count == 8)
    #expect(unguarded.dropped.total == 0)
  }

  /// The pass-through case the issue requires: a refresh that DOES have a
  /// native-width parent is untouched, at 2:1 and at every other revealed size.
  @Test func revealedModesAtAParentRefreshPassThrough() {
    let result = revealMag([
      CGSModeFixtures.magRevealedNativeAt2x100,  // 100: parent id 71
      CGSModeFixtures.magRevealedNativeAt2x60,  // 60: parent id 72
      CGSModeFixtures.magRevealed1920x804,  // 175: parent id 69
      CGSModeFixtures.magRevealed2048x858,  // 175: parent id 69
    ])
    #expect(result.modes.count == 4)
    #expect(result.dropped.noNativeParentTiming == 0)
  }

  /// THE TRAP. CoreGraphics publishes 120 Hz on this panel at 2560x1440, a
  /// narrower framebuffer, so a guard asking "does the display run at this
  /// refresh at all?" admits the rung measured to crop ~880 columns off the
  /// desktop. The parent must be native-WIDTH.
  @Test func aRefreshPublishedOnlyAtANarrowerFramebufferIsNotAParent() {
    let published = RevealedModeFixtures.magExistingCG()
    // The premise: 120 Hz really is in the CoreGraphics list.
    #expect(published.contains { $0.refreshHz == 120 })

    let result = revealMag([CGSModeFixtures.magRevealedNativeAt2x])
    #expect(result.modes.isEmpty)
    #expect(result.dropped.noNativeParentTiming == 1)
  }

  @Test func nativeParentRefreshesReadsTheFramebufferNotTheLogicalSize() {
    let refreshes = CGSModeRevelation.nativeParentRefreshes(
      in: RevealedModeFixtures.magExistingCG(),
      nativePixelWidth: magW, nativePixelHeight: magH)

    #expect(refreshes == [175, 144, 100, 60])
    // id 50 is logical 1720x720 but its framebuffer IS the panel's native size,
    // so it belongs to the family; ids 67/22 are logical/framebuffer 2560-wide
    // and do not, despite 67 having the same logical shape as a native mode.
    #expect(refreshes.contains(175))
    #expect(!refreshes.contains(120))
  }

  /// Second panel, and the one the rule has NOT been measured on. The Dell's
  /// single 2:1 rung sits at 75 Hz, a refresh it advertises no timing for, so
  /// the guard withholds it as a prediction a hardware pass still has to judge.
  @Test func theDellsOnlyExact2to1RungIsWithheld() {
    let result = CGSModeRevelation.reveal(
      cgs: [CGSModeFixtures.dellRevealedNativeAt2x],
      existing: RevealedModeFixtures.dellExistingCG(),
      nativePixelWidth: CGSModeFixtures.dellNativePixels.0,
      nativePixelHeight: CGSModeFixtures.dellNativePixels.1,
      guardsWireTiming: true)

    #expect(result.modes.isEmpty)
    #expect(result.dropped.noNativeParentTiming == 1)
  }

  /// Refresh rates arrive as float noise (59.9998, not 60) and CGS truncates
  /// its own to an integer. Both sides of the comparison must be quantized, or
  /// a mode with a perfectly good parent is withheld because 59.9998 != 60.0.
  @Test func refreshNoiseDoesNotCostAModeItsParent() {
    let noisyNative = [
      DisplayMode(
        ioModeID: 1, logicalWidth: 3440, logicalHeight: 1440,
        pixelWidth: 3440, pixelHeight: 1440, refreshHz: 59.9998, isNative: true)
    ]
    let result = CGSModeRevelation.reveal(
      cgs: [magRung(id: 114, refresh: 59)],
      existing: noisyNative,
      nativePixelWidth: magW, nativePixelHeight: magH,
      guardsWireTiming: true)

    #expect(result.modes.count == 1)
    #expect(result.modes.first?.refreshHz == 60)
  }

  /// NTSC is real: the built-in offers both 59.94 and 60 at one size, so the
  /// quantization that absorbs noise must keep distinct rates apart.
  @Test func aNearbyButDistinctRefreshIsNotAParent() {
    let ntscOnly = [
      DisplayMode(
        ioModeID: 1, logicalWidth: 3440, logicalHeight: 1440,
        pixelWidth: 3440, pixelHeight: 1440, refreshHz: 59.94, isNative: true)
    ]
    let refreshes = CGSModeRevelation.nativeParentRefreshes(
      in: ntscOnly, nativePixelWidth: magW, nativePixelHeight: magH)

    #expect(refreshes == [59.9])
    #expect(!refreshes.contains(60))
  }

  /// The guard runs LAST, so a mode that is unacceptable for an older reason is
  /// still counted against that reason. Keeps the drop counts a partition of
  /// the input rather than a race between gates.
  @Test func earlierGatesStillOwnTheirDrops() {
    // 4:3 at 50 Hz: off-aspect AND at a refresh with no native-width parent.
    let offAspectAndOffTiming = CGSModeDescriptor(
      modeNumber: 900, flags: 0x0020_0001,
      logicalWidth: 1600, logicalHeight: 1200,
      pixelWidth: 3200, pixelHeight: 2400, refreshHz: 50, density: 2.0)

    let result = revealMag([offAspectAndOffTiming])
    #expect(result.dropped.offAspect == 1)
    #expect(result.dropped.noNativeParentTiming == 0)
  }
}
