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
