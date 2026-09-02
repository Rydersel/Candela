import Foundation
import Testing
@testable import CandelaKit

@Suite("Brightness path selection")
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

  /// The built-in panel has no DDC wire, so it is native whatever any pref says. The
  /// shipped "Control method" row reads `forceSoftware` and so lies about the built-in.
  @Test func theBuiltInPanelIsAlwaysNativeWhateverThePrefsSay() {
    #expect(BrightnessPathPolicy.path(inputs(role: .builtIn)) == .native)
    #expect(BrightnessPathPolicy.path(
      inputs(role: .builtIn, forceSoftware: true, avoidGamma: true,
             disableCombinedBrightness: true, unavailableDDC: true)
    ) == .native)
  }

  /// Live HDR is the condition; Candela's own HDR mode is not an input, since System
  /// Settings can engage HDR with our mode `.off`, where DDC writes cannot land, and
  /// requiring the mode routed `.combined`: a locked wire captioned as live control.
  /// Measured the other way too: with HDR off the MAG341C answers
  /// `DisplayServicesSetBrightness` with success and changes nothing.
  @Test func nativeFollowsLiveHDRWhoeverEngagedIt() {
    #expect(BrightnessPathPolicy.usesNative(role: .external, isHDRActive: true))
    #expect(!BrightnessPathPolicy.usesNative(role: .external, isHDRActive: false))
    #expect(BrightnessPathPolicy.usesNative(role: .builtIn, isHDRActive: false))
  }

  /// The mode is not an input, so an HDR engage from outside Candela cannot diverge
  /// from what this reports.
  @Test func liveHDROnAnExternalDisplayIsTheNativePath() {
    #expect(BrightnessPathPolicy.path(inputs(isHDRActive: true)) == .native)
  }

  /// Native outranks force-software: under live HDR the software leg is torn down, and
  /// `.software` would describe a gamma table HDR ignores.
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

  /// Combined is the default path and carries its split point, so the pane can state it
  /// in the user's terms rather than re-deriving it from an internal pref name.
  @Test func theDefaultPathIsCombinedAndCarriesItsSplitPoint() {
    #expect(BrightnessPathPolicy.path(inputs(switchingValue: 0.47))
      == .combined(switchingValue: 0.47, backend: .gamma))
    #expect(BrightnessPathPolicy.path(inputs(avoidGamma: true, switchingValue: 0.3))
      == .combined(switchingValue: 0.3, backend: .overlay))
  }

  @Test func combinedDisabledIsPureHardware() {
    #expect(BrightnessPathPolicy.path(inputs(disableCombinedBrightness: true)) == .hardware)
  }

  /// With DDC brightness turned off and combined dimming off, `applyPaths` submits
  /// nothing: no software leg is left to carry the value. The only state where nothing
  /// moves brightness, and why `unavailable` carries a reason instead of being a bare nil.
  @Test func combinedOffPlusDDCOffIsTheOneStateWhereNothingMovesBrightness() {
    #expect(BrightnessPathPolicy.path(
      inputs(disableCombinedBrightness: true, unavailableDDC: true)
    ) == .unavailable(.ddcTurnedOffWithNoSoftwareLeg))
  }

  /// Ruling R-A, between two half-truths. In combined mode `unavailableDDC` skips only
  /// the hardware submit, so this is not `.unavailable`; hoisting that check above the
  /// combined branch reports a display that still dims as dead. It is not `.combined`
  /// either, which would caption a dead wire as hardware control. What is left is the
  /// software leg alone over `[0, s)`, since `DimmingMath.combinedSplit` returns `sw == 1`
  /// at or above `s` and the DDC portion is never submitted. `dimsBelow` is that edge.
  @Test func combinedWithDDCOffIsSoftwareOnlyAndNeverClaimsHardware() {
    #expect(BrightnessPathPolicy.path(inputs(unavailableDDC: true))
      == .softwareOnly(backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.47))
    #expect(BrightnessPathPolicy.path(inputs(avoidGamma: true, unavailableDDC: true,
                                             switchingValue: 0.3))
      == .softwareOnly(backend: .overlay, reason: .ddcTurnedOff, dimsBelow: 0.3))
  }

  /// The `s = 0` corner of the same state: `combinedSplit`'s first branch always wins, so
  /// the software band is empty and the skipped DDC submit leaves nothing. Reported as the
  /// block, since a caption reading "dims below 0%" is the same lie the other way round.
  @Test func combinedWithDDCOffAndAZeroWidthSoftwareBandMovesNothingAtAll() {
    #expect(BrightnessPathPolicy.path(inputs(unavailableDDC: true, switchingValue: 0))
      == .unavailable(.ddcTurnedOffWithNoSoftwareLeg))
  }

  /// R-A as a property over the whole input space, not one example: the defect is a
  /// caption claiming hardware control that is not happening, and one example forbids one
  /// route to it. `.combined` may not appear anywhere `unavailableDDC` is set.
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

  /// The native gate outranks every pref, and `usesNative` is what the hot paths call
  /// without building an `Inputs`. A divergence would put the drag path on one leg while
  /// the pane described another.
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

  /// `drivesDDCBrightness` is a projection of the same table: the two arms that submit a
  /// register value are exactly the two that answer true. A false answer for a path that
  /// writes hands the register back under a live DDC leg; a true one for a path that does
  /// not leaves it stuck at the floor.
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

  // MARK: - The wire stopped answering

  /// The demotion's ordinary shape: the software leg dims over `[0, s)` only, as it does
  /// when the user turns the command off. `.combined` would caption a dead wire (R-A).
  @Test func anUnresponsiveWireInCombinedModeIsSoftwareOnly() {
    #expect(BrightnessPathPolicy.path(inputs(wireUnresponsive: true))
      == .softwareOnly(backend: .gamma, reason: .ddcUnresponsive, dimsBelow: 0.47))
    #expect(BrightnessPathPolicy.path(
      inputs(avoidGamma: true, switchingValue: 0.3, wireUnresponsive: true)
    ) == .softwareOnly(backend: .overlay, reason: .ddcUnresponsive, dimsBelow: 0.3))
  }

  /// The zero-width corner: empty software band, register write going nowhere. Its own
  /// block reason, because the sentence a person needs is about the wire, not a switch.
  @Test func anUnresponsiveWireWithAZeroWidthSoftwareBandMovesNothingAtAll() {
    #expect(BrightnessPathPolicy.path(inputs(switchingValue: 0, wireUnresponsive: true))
      == .unavailable(.ddcUnresponsiveWithNoSoftwareLeg))
  }

  /// No split to respect in pure-DDC configuration, so the whole range moves to
  /// the software leg: a slider that moves nothing is what this feature ends.
  @Test func anUnresponsiveWireInPureDDCModeDimsInSoftwareOverTheFullRange() {
    #expect(BrightnessPathPolicy.path(
      inputs(disableCombinedBrightness: true, wireUnresponsive: true)
    ) == .software(.gamma))
    #expect(BrightnessPathPolicy.path(
      inputs(avoidGamma: true, disableCombinedBrightness: true, wireUnresponsive: true)
    ) == .software(.overlay))
  }

  /// The user's own switch keeps precedence in both branches: the wire's verdict
  /// is about a command nothing is sending.
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

  /// Under live HDR the DDC failures say nothing about the wire, and a display already
  /// on the software leg is where the demotion would send it.
  @Test func nativeAndForceSoftwareStillOutrankTheWire() {
    #expect(BrightnessPathPolicy.path(inputs(isHDRActive: true, wireUnresponsive: true))
      == .native)
    #expect(BrightnessPathPolicy.path(inputs(role: .builtIn, wireUnresponsive: true))
      == .native)
    #expect(BrightnessPathPolicy.path(inputs(forceSoftware: true, wireUnresponsive: true))
      == .software(.gamma))
  }

  /// Walked over the whole input space for ruling R-A's reason: a caption
  /// claiming hardware control of a dead wire is the defect being ruled out.
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
                // Native is the exception: under live HDR the register is
                // locked and macOS carries brightness.
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
