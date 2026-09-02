import Testing
@testable import CandelaKit

/// The full 3 × 3 of the volume-denial rule's resolution table, written exhaustively so every cell
/// is an explicit assertion rather than an implication.
@Suite("Volume slider enablement")
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
    // The MAG 341C's permanent state: a write-only panel, so the probe never
    // does better than .unknown, while its 3.5 mm jack works.
    #expect(VolumeSliderPolicy.isEnabled(override: .auto, volumeSupport: .unknown))
  }

  @Test func notProbedYetIsIndistinguishableFromAFailedProbe() {
    // AppModel passes `.unknown` for an absent cache entry, so the panel is
    // usable before the first probe lands and nothing about it waits on DDC.
    #expect(VolumeSliderPolicy.isEnabled(override: .auto, volumeSupport: .unknown))
  }

  // MARK: - The tooltip

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

  /// Hardware is always "display" in copy, never "panel".
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

  // MARK: - The menu bar's short form

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
/// capabilities string parses cleanly with no 0x62 and whose slider the volume-denial rule therefore
/// greys. The HUD reported a rising volume that existed only in the pref.
@Suite("Volume and mute keys obey the same denial as the slider")
struct VolumeKeyAcceptanceTests {
  /// The bug. A display that lists no volume command takes no volume key.
  @Test func aParsedDenialSwallowsVolumeKeys() {
    #expect(!VolumeSliderPolicy.acceptsVolumeKeys(
      isKeyboardDisabled: false, override: .auto, volumeSupport: .unsupported))
  }

  /// Every DDC read on the MAG returns zeros, so its capabilities never resolve
  /// better than `.unknown` while its 3.5 mm jack works. The volume-denial rule greys on a clean
  /// denial only, so a gate keyed on "no positive evidence" kills its keys.
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

  /// Pins DELEGATION, not correctness: `acceptsVolumeKeys` reaches its verdict
  /// by calling `isEnabled` rather than restating it, so the keys and the slider
  /// cannot disagree. Whether that verdict is right is the suite above.
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
  /// better than `.unknown` for 0x8D either, and the volume-denial rule never greys on absence of
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
  /// single copy of the volume-denial rule.
  @Test func theMuteKeyReachesTheCapabilitiesVerdictOnItsOwnRegister() {
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

/// Which register a mute lands on. The pref asks for the display's own mute
/// command; the display's capabilities string can refuse it, and a refusal
/// degrades the display to the volume-register 0 every display without a
/// dedicated mute command already uses.
@Suite("The mute strategy in force")
struct DedicatedMuteCommandTests {
  @Test func thePrefIsTheFirstWord() {
    for support in [VCPSupport.supported, .unsupported, .unknown] {
      #expect(!VolumeSliderPolicy.usesDedicatedMuteCommand(
        prefEnabled: false, override: .auto, muteSupport: support),
        "mute support \(support)")
    }
  }

  /// The defect this exists for: a display advertising volume and denying mute
  /// took an ungated 0x8D write from the volume path.
  @Test func aCleanDenialOfTheMuteRegisterRetiresTheDedicatedCommand() {
    #expect(!VolumeSliderPolicy.usesDedicatedMuteCommand(
      prefEnabled: true, override: .auto, muteSupport: .unsupported))
  }

  /// The volume-denial rule's other half, and the MAG's whole case: absence of evidence never
  /// takes a command away.
  @Test func noEvidenceKeepsTheDedicatedCommand() {
    #expect(VolumeSliderPolicy.usesDedicatedMuteCommand(
      prefEnabled: true, override: .auto, muteSupport: .unknown))
    #expect(VolumeSliderPolicy.usesDedicatedMuteCommand(
      prefEnabled: true, override: .auto, muteSupport: .supported))
  }

  @Test func theOverrideOutranksTheDisplayOnThisRegisterToo() {
    #expect(VolumeSliderPolicy.usesDedicatedMuteCommand(
      prefEnabled: true, override: .forcePresent, muteSupport: .unsupported))
    #expect(!VolumeSliderPolicy.usesDedicatedMuteCommand(
      prefEnabled: true, override: .forceNone, muteSupport: .supported))
  }

  /// One copy of the volume-denial rule: with the pref on, the strategy IS `isEnabled`
  /// read against 0x8D's verdict, for every input.
  @Test func theStrategyReachesTheCapabilitiesVerdictOnTheMuteRegister() {
    for override in [AudioSinkOverride.auto, .forceNone, .forcePresent] {
      for support in [VCPSupport.supported, .unsupported, .unknown] {
        #expect(
          VolumeSliderPolicy.usesDedicatedMuteCommand(
            prefEnabled: true, override: override, muteSupport: support)
            == VolumeSliderPolicy.isEnabled(override: override, volumeSupport: support),
          "override \(override), mute support \(support)")
      }
    }
  }
}

/// The settings row's status caption. The row is a picture of the PREF, and on
/// a display that denies 0x8D the engine sends a different mute than the one the
/// pref names, so the row overstates the strategy in force with no way for the
/// reader to tell.
@Suite("The mute row says when the strategy in force is not the pref")
struct DegradedMuteReasonTests {
  /// The invariant that keeps the caption from outliving its cause, the same one
  /// `disabledReason` holds for the greyed slider: a reason exists in exactly the
  /// cells where the strategy in force differs from the pref, and the strategy is
  /// read from `usesDedicatedMuteCommand` rather than restated here.
  @Test func aReasonExistsExactlyWhereTheStrategyDiffersFromThePref() {
    for available in [true, false] {
      for prefEnabled in [true, false] {
        for override in AudioSinkOverride.allCases {
          for support in VCPSupport.allCases {
            let strategy = VolumeSliderPolicy.usesDedicatedMuteCommand(
              prefEnabled: prefEnabled, override: override, muteSupport: support)
            let reason = VolumeSliderPolicy.degradedMuteReason(
              commandIsAvailable: available, prefEnabled: prefEnabled,
              override: override, muteSupport: support)
            #expect(
              (reason != nil) == (available && prefEnabled && !strategy),
              "available \(available), pref \(prefEnabled), override \(override), support \(support)")
          }
        }
      }
    }
  }

  /// The bug: the pref is on, the display's own description denies 0x8D,
  /// and the engine degrades the mute to the volume register while the row still
  /// reads On.
  @Test func aDisplayDeniedDegradeBlamesTheDisplay() {
    #expect(
      VolumeSliderPolicy.degradedMuteReason(
        commandIsAvailable: true, prefEnabled: true, override: .auto, muteSupport: .unsupported)
        == "This display lists no mute command in its description, so muting turns its volume all the way down.")
  }

  /// The consequence names the LEVEL, never the register value: the degrade
  /// writes `rawValue(for: 0)`, so a volume floor sends that floor and Invert
  /// sends the top of the range. "Zero" was falsifiable by exactly the person
  /// who set a floor, and both fields have real UI in the command grid.
  @Test func theConsequenceSurvivesAVolumeFloorAndInvert() {
    for override in AudioSinkOverride.allCases {
      for support in VCPSupport.allCases {
        let reason = VolumeSliderPolicy.degradedMuteReason(
          commandIsAvailable: true, prefEnabled: true, override: override, muteSupport: support)
        guard let reason else { continue }
        #expect(!reason.contains("zero"), "override \(override), support \(support)")
        #expect(reason.hasSuffix("turns its volume all the way down."))
      }
    }
  }

  /// Kept apart for the reason the slider's tooltip was split: "Always disabled"
  /// demotes the strategy too, and telling that user their monitor refused sends
  /// them to check a cable.
  @Test func aUserSetDegradeBlamesTheSettingAndNotTheDisplay() {
    let reason = VolumeSliderPolicy.degradedMuteReason(
      commandIsAvailable: true, prefEnabled: true, override: .forceNone, muteSupport: .supported)
    #expect(
      reason == "The volume slider for this display is set to always off, so muting turns its volume all the way down.")
    #expect(reason?.contains("lists no") == false)
  }

  /// The two causes must never share a sentence, including where both are true
  /// at once: the user's own choice is the one that decided it, so it is the one
  /// named.
  @Test func theTwoCausesNeverProduceTheSameSentence() {
    let setting = VolumeSliderPolicy.degradedMuteReason(
      commandIsAvailable: true, prefEnabled: true, override: .forceNone, muteSupport: .unsupported)
    let display = VolumeSliderPolicy.degradedMuteReason(
      commandIsAvailable: true, prefEnabled: true, override: .auto, muteSupport: .unsupported)
    #expect(
      setting
        == "The volume slider for this display is set to always off, so muting turns its volume all the way down.")
    #expect(setting != display)
    #expect(display != nil)
  }

  /// The MAG 341C, and the reason the caption cannot key off the verdict alone:
  /// every read on that panel returns zeros, so its mute verdict is permanently
  /// `.unknown`, the volume-denial rule keeps the dedicated command, and 0x8D really does carry the
  /// mute. A caption here would be false.
  @Test func noEvidenceLeavesTheRowAloneOnTheOverrideToo() {
    #expect(VolumeSliderPolicy.degradedMuteReason(
      commandIsAvailable: true, prefEnabled: true, override: .auto, muteSupport: .unknown) == nil)
    #expect(VolumeSliderPolicy.degradedMuteReason(
      commandIsAvailable: true, prefEnabled: true, override: .forcePresent,
      muteSupport: .unsupported) == nil)
  }

  /// With the pref off the row and the engine already agree: mute IS the volume
  /// register, which is what Off means. Nothing to report in any cell.
  @Test func aPrefThatIsOffIsNeverOverstated() {
    for override in AudioSinkOverride.allCases {
      for support in VCPSupport.allCases {
        #expect(
          VolumeSliderPolicy.degradedMuteReason(
            commandIsAvailable: true, prefEnabled: false,
            override: override, muteSupport: support) == nil,
          "override \(override), support \(support)")
      }
    }
  }

  /// With the volume command switched off nothing mutes at all, and the row
  /// already carries its own sentence saying so. A caption promising that
  /// muting writes the volume register would contradict it one line down.
  @Test func anUnavailableCommandSaysNothingAboutWhereAMuteLands() {
    for override in AudioSinkOverride.allCases {
      for support in VCPSupport.allCases {
        #expect(
          VolumeSliderPolicy.degradedMuteReason(
            commandIsAvailable: false, prefEnabled: true,
            override: override, muteSupport: support) == nil,
          "override \(override), support \(support)")
      }
    }
  }

  /// House copy rules: one consequence, so one sentence. The word "panel" is retired
  /// from visible copy, and no em dashes anywhere a person can read.
  @Test func everyStatusIsOneSentenceInTheHouseVoice() {
    for override in AudioSinkOverride.allCases {
      for support in VCPSupport.allCases {
        let reason = VolumeSliderPolicy.degradedMuteReason(
          commandIsAvailable: true, prefEnabled: true, override: override, muteSupport: support)
        guard let reason else { continue }
        #expect(reason.filter { $0 == "." }.count == 1, "override \(override), support \(support)")
        #expect(reason.hasSuffix("."))
        #expect(!reason.lowercased().contains("panel"))
        #expect(!reason.contains("\u{2014}"))
      }
    }
  }
}

/// A watched key is CONSUMED: it reaches neither the app's displays nor macOS,
/// so arming is not acting. Arming asks what makes a press IMPOSSIBLE (the
/// capability verdict, the engine's availability switch) and never what makes it
/// a deliberate no-op (the per-display keyboard switch).
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

  /// The per-display swallow rule, and why arming is not simply `acceptsVolumeKeys`. A display whose
  /// keyboard control is off SWALLOWS its press, as it does for brightness, so
  /// it keeps the keys watched while acting on nothing. The two verdicts
  /// disagree here on purpose.
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

  /// Dead-key rig (a): the Volume row's On switch writes the per-command
  /// availability pref, which the tap's DDC-capable pool does not filter on, so
  /// the tap consumed a press that `DDCValueController.isAvailable` then dropped.
  /// It outranks the capability verdict and the override: it switches the wire off.
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

  /// Dead-key rig (b): a software-dimmed display's capabilities still read
  /// `.unknown`, which the volume-denial rule resolves to enabled, so it armed the whole rig and
  /// then refused every press. Its DDC volume traffic is off, so it arms nothing.
  @Test func aSoftwareDimmedDisplayWithNoVerdictArmsNothing() {
    #expect(!VolumeSliderPolicy.armsVolumeKeys(
      commandIsAvailable: false, override: .auto, volumeSupport: .unknown))
    #expect(!VolumeSliderPolicy.armsVolumeKeys(
      commandIsAvailable: true, override: .auto, volumeSupport: .unsupported))
  }

  /// With the register available, arming IS the acting verdict with the keyboard
  /// switch held off, delegated rather than restated. Case lists are derived so a
  /// new case cannot slip in under-covered.
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

  /// Where arming and acting can part company: the display denies 0x8D and takes
  /// 0x62, so the engine degrades the mute to the volume register. Both gates
  /// need the STRATEGY; the raw pref hands the mute key to macOS on the one
  /// display whose mute the degrade just made work.
  @Test func theDegradedMuteKeyIsArmedAndAcceptedFromTheSameStrategy() {
    let strategy = VolumeSliderPolicy.usesDedicatedMuteCommand(
      prefEnabled: true, override: .auto, muteSupport: .unsupported)
    #expect(strategy == false)
    #expect(VolumeSliderPolicy.armsMuteKey(
      commandIsAvailable: true, override: .auto, volumeSupport: .supported,
      muteSupport: .unsupported, usesDedicatedMuteCommand: strategy))
    #expect(VolumeSliderPolicy.acceptsMuteKey(
      isKeyboardDisabled: false, override: .auto, volumeSupport: .supported,
      muteSupport: .unsupported, usesDedicatedMuteCommand: strategy))
    #expect(!VolumeSliderPolicy.armsMuteKey(
      commandIsAvailable: true, override: .auto, volumeSupport: .supported,
      muteSupport: .unsupported, usesDedicatedMuteCommand: true))
  }
}
