import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

@Suite("Mode provenance")
struct DisplayModeProvenanceTests {
  private func mode(provenance: ModeProvenance) -> DisplayMode {
    DisplayMode(
      ioModeID: 101, logicalWidth: 1920, logicalHeight: 804,
      pixelWidth: 3840, pixelHeight: 1608, refreshHz: 175,
      isNative: false, provenance: provenance
    )
  }

  @Test func provenanceDefaultsToCoreGraphics() {
    let m = DisplayMode(
      ioModeID: 69, logicalWidth: 3440, logicalHeight: 1440,
      pixelWidth: 3440, pixelHeight: 1440, refreshHz: 175, isNative: true
    )
    #expect(m.provenance == .coreGraphics)
  }

  @Test func provenanceIsCarriedAndComparable() {
    #expect(mode(provenance: .coreGraphicsServices).provenance == .coreGraphicsServices)
    #expect(mode(provenance: .coreGraphics) != mode(provenance: .coreGraphicsServices))
  }

  /// CR3 — provenance must NOT reach the on-disk format.
  @Test func descriptorIsIdenticalAcrossProvenances() {
    #expect(
      mode(provenance: .coreGraphics).descriptor
        == mode(provenance: .coreGraphicsServices).descriptor)
  }

  /// SS5. A synthesized row comes from neither enumeration: it is a size we
  /// render through a virtual display, so it is not "revealed" and its
  /// `ioModeID` is a sentinel that must never reach CoreGraphics.
  @Test func synthesizedIsNeitherRevealedNorCoreGraphics() {
    let m = DisplayMode(
      ioModeID: DisplayMode.syntheticIoModeID(stopIndex: 2),
      logicalWidth: 2580, logicalHeight: 1080,
      pixelWidth: 5160, pixelHeight: 2160,
      refreshHz: 0, isNative: false, provenance: .synthesized)
    #expect(m.isSynthesized)
    #expect(!m.isRevealed)
    #expect(m.ioModeID == -1002)
    #expect(m.isHiDPI)
  }
}

/// SS5's routing half, against the REAL configurator: a synthesized mode is
/// refused by the CoreGraphics apply path rather than routed anywhere in it.
///
/// Safe on this machine, and the safety is structural rather than lucky: the
/// `.synthesized` arm throws before `beginDisplayConfiguration`, so no
/// transaction is opened. It stays safe under the mutation these tests exist to
/// catch, because a sentinel `ioModeID` is negative and therefore resolves to no
/// `CGDisplayMode` on any display, and the published path's lookup also throws
/// before opening a transaction.
///
/// The expected error is spelled exactly, not merely `DisplayConfigError.self`.
/// Both wrong routings throw SOMETHING (the published path fails to resolve the
/// sentinel; the revealed path stages it and fails), so a type-only expectation
/// would pass against a configurator that had stopped refusing entirely.
@Suite("Synthesized apply refusal (SS5)")
struct SynthesizedApplyRefusalTests {
  private let refusal = DisplayConfigError(cgErrorCode: CGError.invalidOperation.rawValue)

  private func synthesizedMode() -> DisplayMode {
    DisplayMode(
      ioModeID: DisplayMode.syntheticIoModeID(stopIndex: 2),
      logicalWidth: 2580, logicalHeight: 1080,
      pixelWidth: 5160, pixelHeight: 2160,
      refreshHz: 0, isNative: false, provenance: .synthesized
    )
  }

  /// A real, attached display: the refusal is keyed on provenance, not on the
  /// display being bogus. This is the one that would catch a caller wiring a
  /// synthesized row into the ordinary apply path.
  @Test func applyRefusesASynthesizedModeOnAnAttachedDisplay() {
    let configurator = CoreGraphicsDisplayConfigurator()
    #expect(throws: refusal) {
      try configurator.apply(synthesizedMode(), to: CGMainDisplayID(), scope: .preview)
    }
  }

  @Test func applyRefusesASynthesizedModeForANonexistentDisplayToo() {
    let configurator = CoreGraphicsDisplayConfigurator()
    #expect(throws: refusal) {
      try configurator.apply(synthesizedMode(), to: 0xDEAD_BEEF, scope: .preview)
    }
  }

  /// The refusal code must stay distinguishable from the published path's
  /// stale-ID failure, which is the only reason the expectations above can tell
  /// a refusal from a wrong routing that happened to fail.
  @Test func theRefusalCodeIsNotTheStaleIDCode() {
    #expect(refusal.cgErrorCode != CGError.illegalArgument.rawValue)
  }
}

/// The one question the pickers ask about provenance: is this an option our own
/// enumeration added?
///
/// It is answered from the recorded provenance and from nothing else. Two wrong
/// answers were available and both are pinned shut here: sharpness is not
/// provenance (`kCGDisplayShowDuplicateLowResolutionModes` puts HiDPI modes in
/// the CoreGraphics list, so a flag derived that way is a synonym for
/// `!isHiDPI`), and it is a fact about ONE mode rather than about the list it
/// arrived in.
@Suite("Revealed-mode marking")
struct RevealedModeMarkingTests {
  private func mode(
    _ id: Int32, logical: (Int, Int), pixels: (Int, Int), hz: Double = 175,
    native: Bool = false, provenance: ModeProvenance = .coreGraphics
  ) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: logical.0, logicalHeight: logical.1,
      pixelWidth: pixels.0, pixelHeight: pixels.1, refreshHz: hz,
      isNative: native, provenance: provenance
    )
  }

  @Test func sharpnessIsNotProvenance() {
    let publishedHiDPI = mode(1, logical: (1720, 720), pixels: (3440, 1440))
    let published1x = mode(2, logical: (1920, 804), pixels: (1920, 804))
    let revealed = mode(3, logical: (1920, 804), pixels: (3840, 1608),
                        provenance: .coreGraphicsServices)

    #expect(publishedHiDPI.isHiDPI)
    #expect(publishedHiDPI.isRevealed == false)
    #expect(published1x.isRevealed == false)
    #expect(revealed.isRevealed)
  }

  /// The MAG's measured collision (S6): CoreGraphics and our revelation both
  /// offer 1920×804, and curation hands the row to the sharp one. Unless it
  /// does, the mark has nothing to attach to and the feature stays invisible at
  /// the exact point it delivers.
  @Test func curationHandsACollidedSizeToTheModeWeAdded() {
    let modes = [
      mode(69, logical: (3440, 1440), pixels: (3440, 1440), native: true),
      mode(70, logical: (1920, 804), pixels: (1920, 804)),
      mode(101, logical: (1920, 804), pixels: (3840, 1608),
           provenance: .coreGraphicsServices),
    ]
    let rows = DisplayModeCatalog.curated(modes, nativePixelWidth: 3440, nativePixelHeight: 1440)

    let row = rows.first { $0.mode.logicalWidth == 1920 }
    #expect(row?.mode.ioModeID == 101)
    #expect(row?.mode.isRevealed == true)
  }

  /// A mode's own provenance, never the list's. A published size sharing a list
  /// with a revealed one is still a published size.
  @Test func aPublishedRowIsUnmarkedEvenBesideARevealedOne() {
    let modes = [
      mode(69, logical: (3440, 1440), pixels: (3440, 1440), native: true),
      mode(101, logical: (1920, 804), pixels: (3840, 1608),
           provenance: .coreGraphicsServices),
    ]
    let rows = DisplayModeCatalog.curated(modes, nativePixelWidth: 3440, nativePixelHeight: 1440)

    #expect(rows.first { $0.mode.ioModeID == 69 }?.mode.isRevealed == false)
    #expect(rows.first { $0.mode.ioModeID == 101 }?.mode.isRevealed == true)
  }

  /// Why a curated row cannot be marked from its representative: one framebuffer
  /// can hold both provenances at once, so the representative and the mode a
  /// press would apply disagree.
  ///
  /// This is the MAG's measured post-adoption state (S6, after the dock cycle):
  /// once 1920×804 was engaged at 175 Hz, CoreGraphics began publishing THAT
  /// rate while the other rates at the same framebuffer stayed ours. The
  /// representative is the size's fastest, so it is now the published one, and
  /// a display running 120 Hz applies the mode we added.
  ///
  /// The pickers therefore ask `modeKeepingCurrentRefreshRate` (app target,
  /// no test target). What is pinned here is that the two answers really do
  /// diverge, so a later "simplify this to `row.mode`" reads the case first.
  @Test func theRepresentativeAndTheAppliedSiblingCanDisagree() {
    let modes = [
      mode(101, logical: (1920, 804), pixels: (3840, 1608), hz: 175),
      mode(102, logical: (1920, 804), pixels: (3840, 1608), hz: 120,
           provenance: .coreGraphicsServices),
    ]
    let rows = DisplayModeCatalog.curated(modes, nativePixelWidth: 3440, nativePixelHeight: 1440)

    let representative = rows.first { $0.mode.logicalWidth == 1920 }?.mode
    #expect(representative?.ioModeID == 101)
    #expect(representative?.isRevealed == false)

    // What a display running 120 Hz would land on at that size and framebuffer.
    let applied = modes.first { $0.refreshHz == 120 }
    #expect(applied?.isRevealed == true)
  }
}
