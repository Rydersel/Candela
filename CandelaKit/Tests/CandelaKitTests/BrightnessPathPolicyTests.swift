import Foundation
import Testing
@testable import CandelaKit

@Suite("Brightness path selection (B1)")
struct BrightnessPathPolicyTests {
  private func inputs(
    role: DisplayRole = .external,
    hdrMode: HDRMode = .off,
    isHDRActive: Bool = false,
    forceSoftware: Bool = false,
    avoidGamma: Bool = false,
    disableCombinedBrightness: Bool = false,
    unavailableDDC: Bool = false,
    switchingValue: Double = 0.47
  ) -> BrightnessPathPolicy.Inputs {
    BrightnessPathPolicy.Inputs(
      role: role, hdrMode: hdrMode, isHDRActive: isHDRActive,
      forceSoftware: forceSoftware, avoidGamma: avoidGamma,
      disableCombinedBrightness: disableCombinedBrightness,
      unavailableDDC: unavailableDDC, switchingValue: switchingValue
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

  /// Both halves are load-bearing. With HDR OFF the MAG341C answers
  /// `DisplayServicesSetBrightness` with SUCCESS and changes nothing, so an
  /// HDR *mode* alone must never route native.
  @Test func nativeNeedsAnHDRModeAndLiveHDRTogether() {
    #expect(BrightnessPathPolicy.usesNative(role: .external, hdrMode: .alwaysOn, isHDRActive: true))
    #expect(!BrightnessPathPolicy.usesNative(role: .external, hdrMode: .alwaysOn, isHDRActive: false))
    #expect(!BrightnessPathPolicy.usesNative(role: .external, hdrMode: .off, isHDRActive: true))
    #expect(BrightnessPathPolicy.usesNative(role: .builtIn, hdrMode: .off, isHDRActive: false))
  }

  @Test func liveHDROnAnExternalDisplayIsTheNativePath() {
    #expect(BrightnessPathPolicy.path(
      inputs(hdrMode: .alwaysOn, isHDRActive: true)
    ) == .native)
  }

  /// Native OUTRANKS force-software: under live HDR the software leg is torn
  /// down, and reporting `.software` there would describe a gamma table that
  /// HDR ignores.
  @Test func nativeWinsOverForceSoftware() {
    #expect(BrightnessPathPolicy.path(
      inputs(hdrMode: .alwaysOn, isHDRActive: true, forceSoftware: true)
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
      for hdrMode in HDRMode.allCases {
        for isHDRActive in bools {
          for forceSoftware in bools {
            for avoidGamma in bools {
              for disableCombined in bools {
                for switchingValue in [0, 0.47, 0.9375] {
                  let candidate = inputs(
                    role: role, hdrMode: hdrMode, isHDRActive: isHDRActive,
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
  }

  /// The native gate is the one branch that outranks every pref, so its
  /// agreement with the standalone predicate is pinned over the whole input
  /// space too: `usesNative` is what the hot paths call without building an
  /// `Inputs`, and a divergence between the two would put the drag path on one
  /// leg while the pane described another.
  @Test func theStandalonePredicateAgreesWithTheTableEverywhere() {
    let bools = [false, true]
    for role in [DisplayRole.external, .builtIn] {
      for hdrMode in HDRMode.allCases {
        for isHDRActive in bools {
          for forceSoftware in bools {
            for disableCombined in bools {
              for unavailableDDC in bools {
                let candidate = inputs(
                  role: role, hdrMode: hdrMode, isHDRActive: isHDRActive,
                  forceSoftware: forceSoftware,
                  disableCombinedBrightness: disableCombined,
                  unavailableDDC: unavailableDDC
                )
                let isNative = BrightnessPathPolicy.path(candidate) == .native
                #expect(isNative == BrightnessPathPolicy.usesNative(
                  role: role, hdrMode: hdrMode, isHDRActive: isHDRActive
                ))
              }
            }
          }
        }
      }
    }
  }
}
