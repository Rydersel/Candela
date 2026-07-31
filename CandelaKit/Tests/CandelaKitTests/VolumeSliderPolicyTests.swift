import Testing
@testable import CandelaKit

/// The full 3 × 3 of D24's resolution table. Written exhaustively on purpose:
/// this replaces behavior already shipped to `main` (7b5be00 / 1f117b3), so
/// every cell is an explicit assertion rather than an implication.
@Suite("Volume slider enablement (D24)")
struct VolumeSliderPolicyTests {
  @Test func overrideWinsOverEveryCapabilityVerdict() {
    for support in [VCPSupport.supported, .unsupported, .unknown] {
      #expect(!VolumeSliderPolicy.isEnabled(override: .forceNone, volumeSupport: support),
              "forceNone with \(support)")
      #expect(VolumeSliderPolicy.isEnabled(override: .forcePresent, volumeSupport: support),
              "forcePresent with \(support)")
    }
  }

  @Test func onlyAParsedDenialGreysTheSlider() {
    #expect(!VolumeSliderPolicy.isEnabled(override: .auto, volumeSupport: .unsupported))
  }

  @Test func supportedAndUnknownBothStayEnabled() {
    #expect(VolumeSliderPolicy.isEnabled(override: .auto, volumeSupport: .supported))
    // The MAG 341C's permanent state: write-only panel, every read returns
    // zeros, so the probe can never do better than .unknown — and its 3.5 mm
    // jack works, so the slider must stay live.
    #expect(VolumeSliderPolicy.isEnabled(override: .auto, volumeSupport: .unknown))
  }

  @Test func notProbedYetIsIndistinguishableFromAFailedProbe() {
    // AppModel passes `.unknown` for an absent cache entry, so the panel is
    // fully usable before the first probe lands — nothing about opening the
    // panel waits on DDC.
    #expect(VolumeSliderPolicy.isEnabled(override: .auto, volumeSupport: .unknown))
  }
}
