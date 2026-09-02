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

  /// Provenance must NOT reach the on-disk format.
  @Test func descriptorIsIdenticalAcrossProvenances() {
    #expect(
      mode(provenance: .coreGraphics).descriptor
        == mode(provenance: .coreGraphicsServices).descriptor)
  }

  /// A synthesized row comes from neither enumeration: it is a size we
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

/// The routing half of the synthesized-mode rule, against the real configurator: the CoreGraphics apply path
/// refuses a synthesized mode rather than routing it anywhere.
///
/// Safe on an attached display, structurally: the `.synthesized` arm throws before
/// `beginDisplayConfiguration`, and a mutation routing to the published path throws
/// too, since a negative sentinel `ioModeID` resolves to no `CGDisplayMode`. A
/// mutation routing to the REVEALED path is not covered by that argument and is not
/// tested here: `applyRevealedMode` would hand the sentinel to
/// `CGSConfigureDisplayMode`, and what that private call does with a negative mode
/// number is an expectation, not a measurement.
///
/// The expected error is spelled exactly rather than `DisplayConfigError.self`: a
/// wrong routing throws something, so a type-only expectation would pass against a
/// configurator that had stopped refusing.
@Suite("Synthesized apply refusal")
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

  /// The refusal code has to stay distinguishable from the published path's stale-ID
  /// failure, or the expectations above cannot tell a refusal from a wrong routing
  /// that happened to fail. Read from what `apply` actually throws rather than a
  /// second literal, which would only be a statement about this test file.
  @Test func theRefusalCodeIsNotTheCodeAStaleIDProduces() {
    let configurator = CoreGraphicsDisplayConfigurator()
    let unresolvable = DisplayMode(
      ioModeID: .max, logicalWidth: 2580, logicalHeight: 1080,
      pixelWidth: 5160, pixelHeight: 2160, refreshHz: 60,
      isNative: false, provenance: .coreGraphics
    )
    var staleCode: Int32?
    do {
      try configurator.apply(unresolvable, to: CGMainDisplayID(), scope: .preview)
    } catch let error as DisplayConfigError {
      staleCode = error.cgErrorCode
    } catch {}
    #expect(staleCode != nil, "an unresolvable published mode must still throw")
    #expect(staleCode != refusal.cgErrorCode)
  }
}

/// The pickers ask one thing about provenance: did our own enumeration add this
/// option? Answered from the recorded provenance and nothing else. Two wrong answers
/// are pinned shut here: sharpness is not provenance
/// (`kCGDisplayShowDuplicateLowResolutionModes` puts HiDPI modes in the CoreGraphics
/// list), and it is a fact about one mode, not about the list it arrived in.
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

  /// The MAG's measured collision: CoreGraphics and our revelation both offer
  /// 1920×804, and curation hands the row to the sharp one. Otherwise the mark has
  /// nothing to attach to and the feature is invisible where it delivers.
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

  /// One framebuffer can hold both provenances at once, so a curated row cannot be
  /// marked from its representative. Measured on the MAG after adoption: once
  /// 1920×804 was engaged at 175 Hz, CoreGraphics published that rate while the
  /// other rates at the same framebuffer stayed ours, so the representative is
  /// published and a display at 120 Hz applies the mode we added. Pinned so a later
  /// "simplify this to `row.mode`" reads the case first.
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
