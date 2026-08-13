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

  /// The anti-drift pin. It pins DELEGATION, not independent correctness: what
  /// it proves is that `acceptsVolumeKeys` reaches its capability verdict by
  /// calling `isEnabled` rather than restating it, so the keys and the slider
  /// are structurally incapable of disagreeing. Whether that shared verdict is
  /// itself right is D24's own table, pinned by the suite above.
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

/// The mute key writes a DIFFERENT register from the volume keys, and which one
/// depends on the display's mute strategy: `enableMuteUnmute` sends VCP 0x8D,
/// and without it mute is a volume-register write of 0. The denial that refuses
/// a key is therefore per command, so the mute key asks about the register it
/// would actually write.
@Suite("The mute key gates on the register it writes")
struct MuteKeyAcceptanceTests {
  /// The dedicated-command strategy sends 0x8D and nothing else, so 0x62's
  /// verdict cannot speak for it in either direction.
  @Test func theDedicatedCommandGatesOnTheMuteRegister() {
    #expect(!VolumeSliderPolicy.acceptsMuteKey(
      isKeyboardDisabled: false, override: .auto,
      volumeSupport: .supported, muteSupport: .unsupported, usesDedicatedMuteCommand: true))
    // The case a single 0x62 gate would get wrong: a display that advertises
    // mute but no volume still takes the mute key.
    #expect(VolumeSliderPolicy.acceptsMuteKey(
      isKeyboardDisabled: false, override: .auto,
      volumeSupport: .unsupported, muteSupport: .supported, usesDedicatedMuteCommand: true))
  }

  /// The default strategy never sends 0x8D: silence is a volume-register write
  /// of 0. A display that denies 0x8D is therefore irrelevant here, and one
  /// that denies 0x62 refuses the mute key along with the volume keys.
  @Test func theDefaultStrategyGatesOnTheVolumeRegister() {
    #expect(VolumeSliderPolicy.acceptsMuteKey(
      isKeyboardDisabled: false, override: .auto,
      volumeSupport: .supported, muteSupport: .unsupported, usesDedicatedMuteCommand: false))
    #expect(!VolumeSliderPolicy.acceptsMuteKey(
      isKeyboardDisabled: false, override: .auto,
      volumeSupport: .unsupported, muteSupport: .supported, usesDedicatedMuteCommand: false))
  }

  /// The MAG rule on the second register: a write-only panel can never read
  /// better than `.unknown` for 0x8D either, and D24 never greys on absence of
  /// evidence. Both strategies must keep taking the key.
  @Test func noEvidenceIsNotADenialOnEitherRegister() {
    for dedicated in [true, false] {
      #expect(VolumeSliderPolicy.acceptsMuteKey(
        isKeyboardDisabled: false, override: .auto,
        volumeSupport: .unknown, muteSupport: .unknown, usesDedicatedMuteCommand: dedicated),
        "dedicated mute command \(dedicated)")
    }
  }

  /// The two gates that are not about a register at all keep ruling the mute
  /// key, whichever register it would write.
  @Test func theKeyboardPrefAndTheOverrideStillRuleTheMuteKey() {
    for dedicated in [true, false] {
      #expect(!VolumeSliderPolicy.acceptsMuteKey(
        isKeyboardDisabled: true, override: .forcePresent,
        volumeSupport: .supported, muteSupport: .supported, usesDedicatedMuteCommand: dedicated))
      #expect(!VolumeSliderPolicy.acceptsMuteKey(
        isKeyboardDisabled: false, override: .forceNone,
        volumeSupport: .supported, muteSupport: .supported, usesDedicatedMuteCommand: dedicated))
      // The escape hatch reaches the mute key too, on a display that denies
      // both registers.
      #expect(VolumeSliderPolicy.acceptsMuteKey(
        isKeyboardDisabled: false, override: .forcePresent,
        volumeSupport: .unsupported, muteSupport: .unsupported, usesDedicatedMuteCommand: dedicated))
    }
  }

  /// The delegation pin again, one register over: with the keyboard enabled and
  /// the dedicated command in force, the mute key's verdict IS `isEnabled` read
  /// against 0x8D's support, for every input. Same structure, so the same
  /// single copy of D24's rule.
  @Test func theMuteKeyReachesD24sVerdictOnItsOwnRegister() {
    for override in [AudioSinkOverride.auto, .forceNone, .forcePresent] {
      for support in [VCPSupport.supported, .unsupported, .unknown] {
        #expect(
          VolumeSliderPolicy.acceptsMuteKey(
            isKeyboardDisabled: false, override: override,
            volumeSupport: .unsupported, muteSupport: support, usesDedicatedMuteCommand: true)
            == VolumeSliderPolicy.isEnabled(override: override, volumeSupport: support),
          "override \(override), mute support \(support)")
      }
    }
  }
}

/// The tap decides what to WATCH before it knows what a press would act on, and
/// a watched key is CONSUMED: it reaches neither the app's displays nor macOS.
/// So the arming question is not the acting question. It asks everything that
/// makes a press IMPOSSIBLE on this display (the capability verdict, and the
/// engine's own availability switch for the register) and nothing that merely
/// makes the press a deliberate no-op (the per-display keyboard switch).
@Suite("Arming the volume keys asks what makes a press impossible")
struct VolumeKeyArmingTests {
  /// The whole point: a rig whose every display denies the register must let the
  /// keys through to macOS, because nothing here can ever take them.
  @Test func aParsedDenialDoesNotArmTheKeys() {
    #expect(!VolumeSliderPolicy.armsVolumeKeys(commandIsAvailable: true, override: .auto, volumeSupport: .unsupported))
    #expect(!VolumeSliderPolicy.armsMuteKey(
      commandIsAvailable: true, override: .auto, volumeSupport: .unsupported, muteSupport: .unsupported,
      usesDedicatedMuteCommand: false))
  }

  /// The MAG rule, one layer up: absence of evidence keeps the keys armed, so a
  /// write-only panel never loses them.
  @Test func noEvidenceStillArms() {
    #expect(VolumeSliderPolicy.armsVolumeKeys(commandIsAvailable: true, override: .auto, volumeSupport: .unknown))
    #expect(VolumeSliderPolicy.armsMuteKey(
      commandIsAvailable: true, override: .auto, volumeSupport: .unknown, muteSupport: .unknown,
      usesDedicatedMuteCommand: true))
  }

  /// The user's override reaches the arming decision as well: turning a display's
  /// volume slider off is a statement that no key should act on it either, and if
  /// it is the only display the keys belong to macOS.
  @Test func theOverrideRulesTheArmingDecisionToo() {
    #expect(!VolumeSliderPolicy.armsVolumeKeys(commandIsAvailable: true, override: .forceNone, volumeSupport: .supported))
    #expect(VolumeSliderPolicy.armsVolumeKeys(commandIsAvailable: true, override: .forcePresent, volumeSupport: .unsupported))
  }

  /// R1, and the reason arming is not simply `acceptsVolumeKeys`. A display
  /// whose keyboard control the user switched off SWALLOWS its press, exactly as
  /// it does for brightness, so it must keep the keys watched even though it
  /// will act on nothing. Handing that press to macOS instead would make the
  /// switch mean something it has never meant. The two verdicts DISAGREE here,
  /// on purpose, and that disagreement is the whole difference between them.
  @Test func aKeyboardDisabledDisplayStillArmsTheKeys() {
    #expect(VolumeSliderPolicy.armsVolumeKeys(commandIsAvailable: true, override: .auto, volumeSupport: .supported))
    #expect(!VolumeSliderPolicy.acceptsVolumeKeys(
      isKeyboardDisabled: true, override: .auto, volumeSupport: .supported))
    #expect(VolumeSliderPolicy.armsMuteKey(
      commandIsAvailable: true, override: .auto, volumeSupport: .supported, muteSupport: .supported,
      usesDedicatedMuteCommand: false))
    #expect(!VolumeSliderPolicy.acceptsMuteKey(
      isKeyboardDisabled: true, override: .auto, volumeSupport: .supported,
      muteSupport: .supported, usesDedicatedMuteCommand: false))
  }

  /// The mute key arms on the register it would WRITE, same as it acts on it: a
  /// display that lists 0x8D but not 0x62 keeps the mute key armed under the
  /// dedicated strategy while the volume keys go to macOS.
  @Test func theMuteKeyArmsOnTheRegisterItWrites() {
    #expect(!VolumeSliderPolicy.armsVolumeKeys(commandIsAvailable: true, override: .auto, volumeSupport: .unsupported))
    #expect(VolumeSliderPolicy.armsMuteKey(
      commandIsAvailable: true, override: .auto, volumeSupport: .unsupported, muteSupport: .supported,
      usesDedicatedMuteCommand: true))
    // Without the dedicated command mute is a volume-register write, so it
    // follows the volume keys out.
    #expect(!VolumeSliderPolicy.armsMuteKey(
      commandIsAvailable: true, override: .auto, volumeSupport: .unsupported, muteSupport: .supported,
      usesDedicatedMuteCommand: false))
  }

  /// Dead-key rig (a): a single external whose Volume row On switch is off. That
  /// writes the per-command availability pref, which the tap's DDC-capable pool
  /// does not filter on, so the keys armed on a display whose every volume write
  /// the engine refuses. The press then died between the two: the tap consumed
  /// it, and `DDCValueController.isAvailable` dropped it.
  ///
  /// It outranks the capability verdict and the override alike, because it is not
  /// an opinion about what the display can do: it switches the wire off.
  @Test func theEnginesOwnAvailabilitySwitchRefusesToArm() {
    for volume in VCPSupport.allCases {
      for override in AudioSinkOverride.allCases {
        #expect(
          !VolumeSliderPolicy.armsVolumeKeys(
            commandIsAvailable: false, override: override, volumeSupport: volume),
          "override \(override), support \(volume)")
      }
    }
    // The mute key rides the SAME controller and so the same switch, under either
    // strategy: `toggleMute` guards on the volume command's availability even
    // when the wire it would write is 0x8D.
    for dedicated in [true, false] {
      #expect(!VolumeSliderPolicy.armsMuteKey(
        commandIsAvailable: false, override: .forcePresent,
        volumeSupport: .supported, muteSupport: .supported,
        usesDedicatedMuteCommand: dedicated), "dedicated \(dedicated)")
    }
  }

  /// Dead-key rig (b): two externals, one forced to software dimming and one that
  /// denies the register. The software-dimmed display is where the pool went
  /// wrong twice over, because its capabilities can still read `.unknown` and D24
  /// resolves that to enabled: it armed the whole rig on its own account and then
  /// refused every press. Its DDC volume traffic is switched off, so it arms
  /// nothing, which leaves only the denying display and sends the keys to macOS.
  @Test func aSoftwareDimmedDisplayWithNoVerdictArmsNothing() {
    #expect(!VolumeSliderPolicy.armsVolumeKeys(
      commandIsAvailable: false, override: .auto, volumeSupport: .unknown))
    #expect(!VolumeSliderPolicy.armsVolumeKeys(
      commandIsAvailable: true, override: .auto, volumeSupport: .unsupported))
  }

  /// The anti-drift pin: with the register available, arming IS the acting
  /// verdict with the keyboard switch held off, delegated rather than restated,
  /// so the two can never disagree about a capability. Every input, both key
  /// families, with the case lists derived so a new case cannot slip in
  /// under-covered.
  @Test func armingIsTheActingVerdictWithoutTheKeyboardSwitch() {
    for override in AudioSinkOverride.allCases {
      for volume in VCPSupport.allCases {
        #expect(
          VolumeSliderPolicy.armsVolumeKeys(
            commandIsAvailable: true, override: override, volumeSupport: volume)
            == VolumeSliderPolicy.acceptsVolumeKeys(
              isKeyboardDisabled: false, override: override, volumeSupport: volume),
          "override \(override), support \(volume)")
        for mute in VCPSupport.allCases {
          for dedicated in [true, false] {
            #expect(
              VolumeSliderPolicy.armsMuteKey(
                commandIsAvailable: true, override: override,
                volumeSupport: volume, muteSupport: mute,
                usesDedicatedMuteCommand: dedicated)
                == VolumeSliderPolicy.acceptsMuteKey(
                  isKeyboardDisabled: false, override: override, volumeSupport: volume,
                  muteSupport: mute, usesDedicatedMuteCommand: dedicated),
              "override \(override), volume \(volume), mute \(mute), dedicated \(dedicated)")
          }
        }
      }
    }
  }
}
