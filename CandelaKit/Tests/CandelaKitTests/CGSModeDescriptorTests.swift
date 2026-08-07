import Foundation
import Testing

@testable import CandelaKit

@Suite("CGS mode descriptor")
struct CGSModeDescriptorTests {
  @Test func usabilityReadsTheUnusableFlag() {
    #expect(CGSModeFixtures.magRevealed1920x804.isUsable)
    let unusable = CGSModeDescriptor(
      modeNumber: 900, flags: 0x4000_0001,
      logicalWidth: 1920, logicalHeight: 804,
      pixelWidth: 3840, pixelHeight: 1608, refreshHz: 175, density: 2.0
    )
    #expect(!unusable.isUsable)
  }

  @Test func aspectRatioIsLogical() {
    #expect(abs(CGSModeFixtures.magRevealed1920x804.aspectRatio - 2.388) < 0.001)
  }

  @Test func zeroHeightDoesNotTrap() {
    let degenerate = CGSModeDescriptor(
      modeNumber: 1, flags: 1, logicalWidth: 100, logicalHeight: 0,
      pixelWidth: 200, pixelHeight: 0, refreshHz: 60, density: 2.0
    )
    #expect(degenerate.aspectRatio == 0)
  }
}
