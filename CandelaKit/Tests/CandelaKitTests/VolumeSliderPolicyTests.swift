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

/// The keyboard half of the same verdict. Measured 2026-08-11: four volume-up
/// presses with the pointer on the DELL U2725QE walked its stored volume 0.5 to
/// 0.75 and sent four DDC 0x62 writes, all ACKed, to a display whose own
/// capabilities string parses cleanly with no 0x62 and whose slider D24 therefore
/// greys. The HUD reported a rising volume that existed only in the pref.
@Suite("Volume and mute keys obey the same denial as the slider (D24)")
struct VolumeKeyAcceptanceTests {
  /// The bug. A display that lists no volume command takes no volume key.
  @Test func aParsedDenialSwallowsVolumeKeys() {
    #expect(!VolumeSliderPolicy.acceptsVolumeKeys(
      isKeyboardDisabled: false, override: .auto, volumeSupport: .unsupported))
  }

  /// The MAG 341C's permanent state, and the regression that would hurt most:
  /// every DDC read on it returns zeros, so its capabilities can never resolve
  /// better than `.unknown`, while its 3.5 mm jack works. D24 greys on a clean
  /// denial only, never on absence of evidence, and the keys inherit that.
  /// A gate keyed on "no positive evidence" would kill the keys on this panel.
  @Test func noEvidenceIsNotADenial() {
    #expect(VolumeSliderPolicy.acceptsVolumeKeys(
      isKeyboardDisabled: false, override: .auto, volumeSupport: .unknown))
    #expect(VolumeSliderPolicy.acceptsVolumeKeys(
      isKeyboardDisabled: false, override: .auto, volumeSupport: .supported))
  }

  /// The per-display keyboard pref keeps working on its own: a display with a
  /// perfectly good volume register still takes no key while its keyboard
  /// control is off.
  @Test func theKeyboardPrefStillRefusesOnItsOwn() {
    for support in [VCPSupport.supported, .unsupported, .unknown] {
      #expect(!VolumeSliderPolicy.acceptsVolumeKeys(
        isKeyboardDisabled: true, override: .forcePresent, volumeSupport: support),
        "keyboard off with \(support)")
    }
  }

  /// The escape hatch reaches the keys, not just the slider: a user who
  /// overrides a display the app believes has no volume command gets both back.
  @Test func theOverrideReachesTheKeysToo() {
    #expect(VolumeSliderPolicy.acceptsVolumeKeys(
      isKeyboardDisabled: false, override: .forcePresent, volumeSupport: .unsupported))
    #expect(!VolumeSliderPolicy.acceptsVolumeKeys(
      isKeyboardDisabled: false, override: .forceNone, volumeSupport: .supported))
  }

  /// The anti-drift pin, and the reason this lives beside `isEnabled` rather
  /// than in the key path: wherever the keyboard is enabled for a display, the
  /// keys and the slider reach exactly the same verdict, for every input. The
  /// settings page already tells the user they move together.
  @Test func theKeysAndTheSliderNeverDisagree() {
    for override in [AudioSinkOverride.auto, .forceNone, .forcePresent] {
      for support in [VCPSupport.supported, .unsupported, .unknown] {
        #expect(
          VolumeSliderPolicy.acceptsVolumeKeys(
            isKeyboardDisabled: false, override: override, volumeSupport: support)
            == VolumeSliderPolicy.isEnabled(override: override, volumeSupport: support),
          "override \(override), support \(support)")
      }
    }
  }
}
