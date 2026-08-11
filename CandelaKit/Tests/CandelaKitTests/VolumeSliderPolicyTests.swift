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

  // MARK: - The tooltip (Checkpoint 1 item 81)

  /// The bug this pins: one hardcoded sentence blamed the DISPLAY for every
  /// grey. A user who set the slider to always off was told their monitor
  /// reports no volume control, which sends them to check a cable.
  @Test func aUserSetGreyBlamesTheSettingAndNotTheDisplay() {
    let reason = VolumeSliderPolicy.disabledReason(
      displayName: "MAG 341C OLED", override: .forceNone, volumeSupport: .unknown)
    #expect(reason == "The volume slider for MAG 341C OLED is set to always off.")
  }

  @Test func aDisplayDeniedGreyBlamesTheDisplay() {
    let reason = VolumeSliderPolicy.disabledReason(
      displayName: "DELL U2725QE", override: .auto, volumeSupport: .unsupported)
    #expect(reason == "DELL U2725QE lists no volume command in its description.")
  }

  /// The two greys must never share a sentence. This is the whole defect.
  @Test func theTwoCausesNeverProduceTheSameSentence() {
    let setting = VolumeSliderPolicy.disabledReason(
      displayName: "Same Display", override: .forceNone, volumeSupport: .unsupported)
    let display = VolumeSliderPolicy.disabledReason(
      displayName: "Same Display", override: .auto, volumeSupport: .unsupported)
    #expect(setting != display)
    #expect(setting != nil && display != nil)
  }

  /// An enabled slider explains nothing, and the invariant that keeps the
  /// tooltip from outliving its cause: `disabledReason` is non-nil exactly when
  /// `isEnabled` is false, across every combination.
  @Test func aReasonExistsExactlyWhenTheSliderIsDisabled() {
    for override in [AudioSinkOverride.auto, .forceNone, .forcePresent] {
      for support in [VCPSupport.supported, .unsupported, .unknown] {
        let enabled = VolumeSliderPolicy.isEnabled(override: override, volumeSupport: support)
        let reason = VolumeSliderPolicy.disabledReason(
          displayName: "D", override: override, volumeSupport: support)
        #expect(enabled == (reason == nil), "override \(override), support \(support)")
      }
    }
  }

  /// SO14: hardware is always "display" in copy, never "panel".
  @Test func noReasonCallsTheHardwareAPanel() {
    for override in [AudioSinkOverride.auto, .forceNone, .forcePresent] {
      for support in [VCPSupport.supported, .unsupported, .unknown] {
        let reason = VolumeSliderPolicy.disabledReason(
          displayName: "D", override: override, volumeSupport: support) ?? ""
        #expect(!reason.lowercased().contains("panel"))
        #expect(!reason.contains("\u{2014}"))
      }
    }
  }

  // MARK: - The menu bar's short form (#130)

  /// The panel draws this directly under the display's own name header in a
  /// 280 pt column, so it must NOT name the display: that word is already on
  /// screen one row up, and repeating it wraps a one-line caption onto three.
  @Test func theCompactReasonNeverNamesTheDisplay() {
    for override in [AudioSinkOverride.auto, .forceNone, .forcePresent] {
      for support in [VCPSupport.supported, .unsupported, .unknown] {
        let reason = VolumeSliderPolicy.compactDisabledReason(
          override: override, volumeSupport: support) ?? ""
        #expect(!reason.contains("DELL"))
        #expect(!reason.lowercased().contains("panel"))
        #expect(!reason.contains("\u{2014}"))
      }
    }
  }

  /// The whole point of the long form carries over: the two greys must not
  /// share a sentence just because the short form is shorter.
  @Test func theCompactFormStillSeparatesTheTwoCauses() {
    let setting = VolumeSliderPolicy.compactDisabledReason(
      override: .forceNone, volumeSupport: .unsupported)
    let display = VolumeSliderPolicy.compactDisabledReason(
      override: .auto, volumeSupport: .unsupported)
    #expect(setting == "Volume slider set to always off.")
    #expect(display == "This display lists no volume command.")
    #expect(setting != display)
  }

  /// Same invariant as the long form, and the reason the panel can bind its
  /// hover caption's very EXISTENCE to this call: non-nil exactly when the
  /// slider is disabled, so a reason can never outlive its grey.
  @Test func aCompactReasonExistsExactlyWhenTheSliderIsDisabled() {
    for override in [AudioSinkOverride.auto, .forceNone, .forcePresent] {
      for support in [VCPSupport.supported, .unsupported, .unknown] {
        let enabled = VolumeSliderPolicy.isEnabled(override: override, volumeSupport: support)
        let reason = VolumeSliderPolicy.compactDisabledReason(
          override: override, volumeSupport: support)
        #expect(enabled == (reason == nil), "override \(override), support \(support)")
      }
    }
  }

  /// The two forms must stay in step about WHICH cause applied, even though
  /// they word it differently: same inputs, same nil-ness, always.
  @Test func theTwoFormsAgreeOnWhenThereIsAReason() {
    for override in [AudioSinkOverride.auto, .forceNone, .forcePresent] {
      for support in [VCPSupport.supported, .unsupported, .unknown] {
        let long = VolumeSliderPolicy.disabledReason(
          displayName: "D", override: override, volumeSupport: support)
        let short = VolumeSliderPolicy.compactDisabledReason(
          override: override, volumeSupport: support)
        #expect((long == nil) == (short == nil), "override \(override), support \(support)")
      }
    }
  }
}
