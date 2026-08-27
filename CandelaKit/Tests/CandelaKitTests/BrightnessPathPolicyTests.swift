import Foundation
import Testing
@testable import CandelaKit

@Suite("Brightness path selection (B1)")
struct BrightnessPathPolicyTests {
  private func inputs(
    role: DisplayRole = .external,
    isHDRActive: Bool = false,
    forceSoftware: Bool = false,
    avoidGamma: Bool = false,
    disableCombinedBrightness: Bool = false,
    unavailableDDC: Bool = false,
    switchingValue: Double = 0.47,
    wireUnresponsive: Bool = false
  ) -> BrightnessPathPolicy.Inputs {
    BrightnessPathPolicy.Inputs(
      role: role, isHDRActive: isHDRActive,
      forceSoftware: forceSoftware, avoidGamma: avoidGamma,
      disableCombinedBrightness: disableCombinedBrightness,
      unavailableDDC: unavailableDDC, switchingValue: switchingValue,
      wireUnresponsive: wireUnresponsive
    )
  }

  /// The built-in panel has no DDC wire at all, so it is constitutively native
  /// no matter what any pref says. Pinning the pref-independence is the point:
  /// the shipped "Control method" row reads `forceSoftware` and therefore lies
  /// about the built-in today.
  @Test func theBuiltInPanelIsAlwaysNativeWhateverThePrefsSay() {
    #expect(BrightnessPathPolicy.path(inputs(role: .builtIn)) == .native)
    #expect(BrightnessPathPolicy.path(
      inputs(role: .builtIn, forceSoftware: true, avoidGamma: true,
             disableCombinedBrightness: true, unavailableDDC: true)
    ) == .native)
  }

  /// Live HDR is the condition, and Candela's own HDR mode is not even an
  /// input (#52): System Settings can engage HDR with our mode still `.off`,
  /// where DDC writes cannot land, so requiring the mode routed `.combined` —
  /// a locked wire captioned as live control. The other direction stays
  /// measured fact: with HDR off the MAG341C answers
  /// `DisplayServicesSetBrightness` with SUCCESS and changes nothing, so only
  /// LIVE HDR may route an external display native.
  @Test func nativeFollowsLiveHDRWhoeverEngagedIt() {
    #expect(BrightnessPathPolicy.usesNative(role: .external, isHDRActive: true))
    #expect(!BrightnessPathPolicy.usesNative(role: .external, isHDRActive: false))
    #expect(BrightnessPathPolicy.usesNative(role: .builtIn, isHDRActive: false))
  }

  /// #52's measured scenario is now the only way to say "HDR is live": the
  /// mode is not an input, so the outside-Candela engage cannot diverge.
  @Test func liveHDROnAnExternalDisplayIsTheNativePath() {
    #expect(BrightnessPathPolicy.path(inputs(isHDRActive: true)) == .native)
  }

  /// Native OUTRANKS force-software: under live HDR the software leg is torn
  /// down, and reporting `.software` there would describe a gamma table that
  /// HDR ignores.
  @Test func nativeWinsOverForceSoftware() {
    #expect(BrightnessPathPolicy.path(
      inputs(isHDRActive: true, forceSoftware: true)
    ) == .native)
  }

  @Test func forceSoftwareSelectsTheBackendTheAvoidGammaPrefAsksFor() {
    #expect(BrightnessPathPolicy.path(inputs(forceSoftware: true)) == .software(.gamma))
    #expect(BrightnessPathPolicy.path(
      inputs(forceSoftware: true, avoidGamma: true)
    ) == .software(.overlay))
  }

  /// Combined is the DEFAULT path, and it carries its split point so the pane
  /// can state it in the user's terms ("below 47%…") rather than re-deriving
  /// it from `combinedSwitchingPoint`, which is an internal pref name.
  @Test func theDefaultPathIsCombinedAndCarriesItsSplitPoint() {
    #expect(BrightnessPathPolicy.path(inputs(switchingValue: 0.47))
      == .combined(switchingValue: 0.47, backend: .gamma))
    #expect(BrightnessPathPolicy.path(inputs(avoidGamma: true, switchingValue: 0.3))
      == .combined(switchingValue: 0.3, backend: .overlay))
  }

  @Test func combinedDisabledIsPureHardware() {
    #expect(BrightnessPathPolicy.path(inputs(disableCombinedBrightness: true)) == .hardware)
  }

  /// Branch 4 of `applyPaths` submits NOTHING when DDC brightness is turned off
  /// and combined dimming is off — there is no software leg left to carry the
  /// value. This is the only state in which nothing at all moves brightness,
  /// and the whole reason `unavailable` carries a reason rather than being a
  /// bare nil.
  @Test func combinedOffPlusDDCOffIsTheOneStateWhereNothingMovesBrightness() {
    #expect(BrightnessPathPolicy.path(
      inputs(disableCombinedBrightness: true, unavailableDDC: true)
    ) == .unavailable(.ddcTurnedOffWithNoSoftwareLeg))
  }

  /// Controller ruling R-A, and the two half-truths it sits between.
  ///
  /// In COMBINED mode `unavailableDDC` skips only the hardware submit — the
  /// software leg still runs — so this is NOT `.unavailable`. The obvious wrong
  /// simplification is to hoist the `unavailableDDC` check above the combined
  /// branch, which would report a display that still dims as dead.
  ///
  /// But it is not `.combined` either, and that is the ruling: `.combined`
  /// means "DDC carries the top of the range", which is the one thing this
  /// display is not doing. A pane that captioned this "Hardware (DDC) control"
  /// would claim hardware control of a dead wire — in a feature whose entire
  /// purpose is to say what is actually driving the display.
  ///
  /// The truth is narrower than either: the software leg alone, over `[0, s)`
  /// only, because `DimmingMath.combinedSplit` hands back `sw == 1` for every
  /// value at or above `s` and the DDC portion that was supposed to carry that
  /// band is never submitted. `dimsBelow` is that band's edge, so the pane can
  /// state the dead zone instead of implying a working full-range control.
  @Test func combinedWithDDCOffIsSoftwareOnlyAndNeverClaimsHardware() {
    #expect(BrightnessPathPolicy.path(inputs(unavailableDDC: true))
      == .softwareOnly(backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.47))
    #expect(BrightnessPathPolicy.path(inputs(avoidGamma: true, unavailableDDC: true,
                                             switchingValue: 0.3))
      == .softwareOnly(backend: .overlay, reason: .ddcTurnedOff, dimsBelow: 0.3))
  }

  /// The `s = 0` corner of the same state (pref point −8, "pure hardware"):
  /// `combinedSplit`'s first branch always wins, so the software band is empty
  /// and the skipped DDC submit leaves nothing at all. Reported as the block,
  /// not as a software leg that "dims below 0%" — a caption stating a dead zone
  /// covering the whole range is the same lie in the other direction.
  @Test func combinedWithDDCOffAndAZeroWidthSoftwareBandMovesNothingAtAll() {
    #expect(BrightnessPathPolicy.path(inputs(unavailableDDC: true, switchingValue: 0))
      == .unavailable(.ddcTurnedOffWithNoSoftwareLeg))
  }

  /// Ruling R-A pinned as a PROPERTY over the whole input space rather than as
  /// one example, because the defect it forbids is a caption claiming hardware
  /// control that is not happening — and one example only forbids one route to
  /// it. Every combination of every input is walked; `.combined` may not appear
  /// anywhere `unavailableDDC` is set.
  @Test func noInputWhateverCanProduceACombinedPathWithADeadDDCLeg() {
    let bools = [false, true]
    for role in [DisplayRole.external, .builtIn] {
      for isHDRActive in bools {
        for forceSoftware in bools {
          for avoidGamma in bools {
            for disableCombined in bools {
              for switchingValue in [0, 0.47, 0.9375] {
                let candidate = inputs(
                  role: role, isHDRActive: isHDRActive,
                  forceSoftware: forceSoftware, avoidGamma: avoidGamma,
                  disableCombinedBrightness: disableCombined,
                  unavailableDDC: true, switchingValue: switchingValue
                )
                if case .combined = BrightnessPathPolicy.path(candidate) {
                  Issue.record("combined reported for a dead DDC leg: \(candidate)")
                }
              }
            }
          }
        }
      }
    }
  }

  /// The native gate is the one branch that outranks every pref, so its
  /// agreement with the standalone predicate is pinned over the whole input
  /// space too: `usesNative` is what the hot paths call without building an
  /// `Inputs`, and a divergence between the two would put the drag path on one
  /// leg while the pane described another.
  @Test func theStandalonePredicateAgreesWithTheTableEverywhere() {
    let bools = [false, true]
    for role in [DisplayRole.external, .builtIn] {
      for isHDRActive in bools {
        for forceSoftware in bools {
          for disableCombined in bools {
            for unavailableDDC in bools {
              let candidate = inputs(
                role: role, isHDRActive: isHDRActive,
                forceSoftware: forceSoftware,
                disableCombinedBrightness: disableCombined,
                unavailableDDC: unavailableDDC
              )
              let isNative = BrightnessPathPolicy.path(candidate) == .native
              #expect(isNative == BrightnessPathPolicy.usesNative(
                role: role, isHDRActive: isHDRActive
              ))
            }
          }
        }
      }
    }
  }

  /// `drivesDDCBrightness` is a projection of the same table, so it is pinned
  /// against the table rather than described beside it: the two arms that
  /// SUBMIT a register value in `applyPaths` are exactly the two that answer
  /// true. A drift here is #143 again, in either direction: a false answer for
  /// a path that writes would hand the register back underneath a live DDC leg,
  /// and a true answer for one that does not would leave it at the floor.
  @Test func drivesDDCBrightnessNamesExactlyTheRegisterWritingArms() {
    let bools = [false, true]
    for role in [DisplayRole.external, .builtIn] {
      for isHDRActive in bools {
        for forceSoftware in bools {
          for disableCombined in bools {
            for unavailableDDC in bools {
              for switching in [0.0, 0.5, 0.9375] {
                let path = BrightnessPathPolicy.path(inputs(
                  role: role, isHDRActive: isHDRActive,
                  forceSoftware: forceSoftware,
                  disableCombinedBrightness: disableCombined,
                  unavailableDDC: unavailableDDC,
                  switchingValue: switching
                ))
                let writesRegister: Bool = switch path {
                case .combined, .hardware: true
                case .native, .software, .softwareOnly, .unavailable: false
                }
                #expect(path.drivesDDCBrightness == writesRegister)
              }
            }
          }
        }
      }
    }
  }

  // MARK: - The wire stopped answering (WD2)

  /// The demotion's ordinary shape. Combined dimming is on and the wire has
  /// stopped carrying writes, so the software leg is the only thing left
  /// dimming and it dims over `[0, s)` only, exactly as it does when the user
  /// turns the command off. `.combined` would caption a dead wire as hardware
  /// control, which is ruling R-A's whole subject.
  @Test func anUnresponsiveWireInCombinedModeIsSoftwareOnly() {
    #expect(BrightnessPathPolicy.path(inputs(wireUnresponsive: true))
      == .softwareOnly(backend: .gamma, reason: .ddcUnresponsive, dimsBelow: 0.47))
    #expect(BrightnessPathPolicy.path(
      inputs(avoidGamma: true, switchingValue: 0.3, wireUnresponsive: true)
    ) == .softwareOnly(backend: .overlay, reason: .ddcUnresponsive, dimsBelow: 0.3))
  }

  /// The zero-width corner (pref point −8, "pure hardware"): the software band
  /// is empty and the register write goes nowhere, so nothing moves. Its own
  /// block reason, because the sentence a person needs here is about the wire,
  /// not about a switch they could put back.
  @Test func anUnresponsiveWireWithAZeroWidthSoftwareBandMovesNothingAtAll() {
    #expect(BrightnessPathPolicy.path(inputs(switchingValue: 0, wireUnresponsive: true))
      == .unavailable(.ddcUnresponsiveWithNoSoftwareLeg))
  }

  /// In pure-DDC configuration the demotion has no split to respect: the whole
  /// range moves to the software leg, because a display that keeps a slider
  /// moving nothing is the state this feature exists to end.
  @Test func anUnresponsiveWireInPureDDCModeDimsInSoftwareOverTheFullRange() {
    #expect(BrightnessPathPolicy.path(
      inputs(disableCombinedBrightness: true, wireUnresponsive: true)
    ) == .software(.gamma))
    #expect(BrightnessPathPolicy.path(
      inputs(avoidGamma: true, disableCombinedBrightness: true, wireUnresponsive: true)
    ) == .software(.overlay))
  }

  /// The user's own switch keeps precedence over the wire, in both branches. A
  /// display whose brightness command the user turned off is reported as turned
  /// off: the wire's verdict is about a command nothing is sending.
  @Test func theUsersOwnSwitchOutranksTheWire() {
    #expect(BrightnessPathPolicy.path(inputs(unavailableDDC: true, wireUnresponsive: true))
      == .softwareOnly(backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.47))
    #expect(BrightnessPathPolicy.path(
      inputs(disableCombinedBrightness: true, unavailableDDC: true, wireUnresponsive: true)
    ) == .unavailable(.ddcTurnedOffWithNoSoftwareLeg))
    #expect(BrightnessPathPolicy.path(
      inputs(unavailableDDC: true, switchingValue: 0, wireUnresponsive: true)
    ) == .unavailable(.ddcTurnedOffWithNoSoftwareLeg))
  }

  /// Native and force-software still win, and both directions matter. A display
  /// under live HDR routes native and its DDC failures are not evidence about
  /// the wire at all; a display the user put on the software leg is already
  /// where the demotion would send it, so there is nothing to say about it.
  @Test func nativeAndForceSoftwareStillOutrankTheWire() {
    #expect(BrightnessPathPolicy.path(inputs(isHDRActive: true, wireUnresponsive: true))
      == .native)
    #expect(BrightnessPathPolicy.path(inputs(role: .builtIn, wireUnresponsive: true))
      == .native)
    #expect(BrightnessPathPolicy.path(inputs(forceSoftware: true, wireUnresponsive: true))
      == .software(.gamma))
  }

  /// The demotion is a PATH, so nothing that reads the table can be told the
  /// register is still being driven: walked over the whole input space for the
  /// same reason ruling R-A is, since a caption claiming hardware control of a
  /// dead wire is exactly the defect either route would produce.
  @Test func noInputWhateverKeepsTheRegisterWhileTheWireIsUnresponsive() {
    let bools = [false, true]
    for role in [DisplayRole.external, .builtIn] {
      for isHDRActive in bools {
        for forceSoftware in bools {
          for avoidGamma in bools {
            for disableCombined in bools {
              for switchingValue in [0, 0.47, 0.9375] {
                let candidate = inputs(
                  role: role, isHDRActive: isHDRActive,
                  forceSoftware: forceSoftware, avoidGamma: avoidGamma,
                  disableCombinedBrightness: disableCombined,
                  switchingValue: switchingValue, wireUnresponsive: true
                )
                let path = BrightnessPathPolicy.path(candidate)
                // Native is the exception and the reason it is one is measured:
                // under live HDR the DDC register is locked and macOS carries
                // brightness, so the wire's verdict says nothing about it.
                guard path != .native else { continue }
                #expect(!path.drivesDDCBrightness, "register kept on a dead wire: \(candidate)")
              }
            }
          }
        }
      }
    }
  }
}
