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
  /// offer 1920×804, and curation hands the row to the sharp one. The row must
  /// then report itself as ours, or the feature is invisible at the exact point
  /// it delivers.
  @Test func aCuratedRowReportsTheProvenanceOfTheModeItWouldApply() {
    let modes = [
      mode(69, logical: (3440, 1440), pixels: (3440, 1440), native: true),
      mode(70, logical: (1920, 804), pixels: (1920, 804)),
      mode(101, logical: (1920, 804), pixels: (3840, 1608),
           provenance: .coreGraphicsServices),
    ]
    let rows = DisplayModeCatalog.curated(modes, nativePixelWidth: 3440, nativePixelHeight: 1440)

    let row = rows.first { $0.mode.logicalWidth == 1920 }
    #expect(row?.mode.ioModeID == 101)
    #expect(row?.isRevealed == true)
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

    #expect(rows.first { $0.mode.ioModeID == 69 }?.isRevealed == false)
    #expect(rows.first { $0.mode.ioModeID == 101 }?.isRevealed == true)
  }
}
