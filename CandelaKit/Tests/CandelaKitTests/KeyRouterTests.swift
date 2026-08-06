import Testing
@testable import CandelaKit

@Suite("KeyRouter — Appendix A matrix")
struct KeyRouterTests {
  private func route(
    _ key: MediaKey, pressed: Bool = true, isRepeat: Bool = false,
    _ modifiers: KeyModifiers = [], fineScalePref: Bool = false
  ) -> KeyAction {
    KeyRouter.route(
      MediaKeyPress(key: key, isPressed: pressed, isRepeat: isRepeat, modifiers: modifiers),
      config: KeyRouterConfig(useFineScaleBrightness: fineScalePref)
    )
  }

  // Plain steps
  @Test func plainBrightnessUp() {
    #expect(route(.brightnessUp) == .stepBrightness(isUp: true, isFine: false, scope: .affected))
  }
  @Test func plainBrightnessDown() {
    #expect(route(.brightnessDown) == .stepBrightness(isUp: false, isFine: false, scope: .affected))
  }
  @Test func repeatStillSteps() {
    #expect(route(.brightnessUp, isRepeat: true) == .stepBrightness(isUp: true, isFine: false, scope: .affected))
  }
  @Test func keyUpDoesNothing() {
    #expect(route(.brightnessUp, pressed: false) == .none)
  }

  // Fine steps + inversion pref
  @Test func optShiftIsFine() {
    #expect(route(.brightnessUp, [.option, .shift]) == .stepBrightness(isUp: true, isFine: true, scope: .affected))
  }
  @Test func fineScalePrefInvertsPlain() {
    #expect(route(.brightnessUp, fineScalePref: true) == .stepBrightness(isUp: true, isFine: true, scope: .affected))
  }
  @Test func fineScalePrefInvertsOptShift() {
    #expect(route(.brightnessUp, [.option, .shift], fineScalePref: true)
      == .stepBrightness(isUp: true, isFine: false, scope: .affected))
  }

  // Mirroring (rule 1)
  @Test func cmdBrightnessDownFreshTogglesMirroring() {
    #expect(route(.brightnessDown, [.command]) == .toggleMirroringOrStepDown(isFine: false))
  }
  @Test func cmdBrightnessDownRepeatDoesNothing() {
    #expect(route(.brightnessDown, isRepeat: true, [.command]) == .none)
  }
  @Test func cmdBrightnessUpIsNotMirroring() {
    #expect(route(.brightnessUp, [.command]) == .stepBrightness(isUp: true, isFine: false, scope: .affected))
  }
  @Test func ctrlCmdBrightnessDownIsDirectedNotMirroring() {
    #expect(route(.brightnessDown, [.control, .command])
      == .stepBrightness(isUp: false, isFine: false, scope: .allExternal))
  }

  // Deep link (rule 2)
  @Test func optionOnlyOpensDisplaysSettings() {
    #expect(route(.brightnessUp, [.option]) == .openDisplaysSettings)
  }
  @Test func optionOnlyRepeatDoesNothing() {
    #expect(route(.brightnessUp, isRepeat: true, [.option]) == .none)
  }
  @Test func optionShiftIsFineStepNotDeepLink() {
    #expect(route(.brightnessDown, [.option, .shift])
      == .stepBrightness(isUp: false, isFine: true, scope: .affected))
  }

  // Directed (rule 4)
  @Test func ctrlBrightnessTargetsBuiltIn() {
    #expect(route(.brightnessUp, [.control]) == .stepBrightness(isUp: true, isFine: false, scope: .builtInOnly))
  }
  @Test func ctrlCmdBrightnessTargetsAllExternal() {
    #expect(route(.brightnessUp, [.control, .command])
      == .stepBrightness(isUp: true, isFine: false, scope: .allExternal))
  }

  // Contrast (rule 5)
  @Test func ctrlOptCmdIsContrast() {
    #expect(route(.brightnessUp, [.control, .option, .command]) == .stepContrast(isUp: true, isFine: false))
  }
  @Test func contrastHonorsFine() {
    #expect(route(.brightnessDown, [.control, .option, .command, .shift])
      == .stepContrast(isUp: false, isFine: true))
  }

  private func routeVol(
    _ key: MediaKey, pressed: Bool = true, isRepeat: Bool = false,
    _ modifiers: KeyModifiers = [], fineVolumePref: Bool = false
  ) -> KeyAction {
    KeyRouter.route(
      MediaKeyPress(key: key, isPressed: pressed, isRepeat: isRepeat, modifiers: modifiers),
      config: KeyRouterConfig(useFineScaleVolume: fineVolumePref)
    )
  }

  // Volume steps (Appendix A)
  @Test func plainVolumeUp() {
    #expect(routeVol(.volumeUp) == .stepVolume(isUp: true, isFine: false))
  }
  @Test func plainVolumeDown() {
    #expect(routeVol(.volumeDown) == .stepVolume(isUp: false, isFine: false))
  }
  @Test func volumeRepeatStillSteps() {
    #expect(routeVol(.volumeUp, isRepeat: true) == .stepVolume(isUp: true, isFine: false))
  }
  @Test func optShiftVolumeIsFine() {
    #expect(routeVol(.volumeUp, [.option, .shift]) == .stepVolume(isUp: true, isFine: true))
  }
  @Test func fineScaleVolumePrefInverts() {
    #expect(routeVol(.volumeUp, fineVolumePref: true) == .stepVolume(isUp: true, isFine: true))
    #expect(routeVol(.volumeUp, [.option, .shift], fineVolumePref: true)
      == .stepVolume(isUp: true, isFine: false))
  }
  @Test func brightnessFinePrefDoesNotLeakIntoVolume() {
    let action = KeyRouter.route(
      MediaKeyPress(key: .volumeUp, isPressed: true, isRepeat: false, modifiers: []),
      config: KeyRouterConfig(useFineScaleBrightness: true, useFineScaleVolume: false)
    )
    #expect(action == .stepVolume(isUp: true, isFine: false))
  }

  // Key-up: feedback-sound trigger for volume, nothing for mute
  @Test func volumeKeyUpRoutesTheFeedbackTrigger() {
    #expect(routeVol(.volumeUp, pressed: false) == .volumeKeyUp)
    #expect(routeVol(.volumeDown, pressed: false) == .volumeKeyUp)
  }
  @Test func muteKeyUpDoesNothing() {
    // "The mute key should not respond to press + hold or keyup" (fork).
    #expect(routeVol(.mute, pressed: false) == .none)
  }
  // Mute
  @Test func muteFreshPressToggles() {
    #expect(routeVol(.mute) == .toggleMute)
  }
  @Test func muteRepeatDoesNothing() {
    #expect(routeVol(.mute, isRepeat: true) == .none)
  }

  // Option-only deep link → Sound settings
  @Test func optionOnlyVolumeOpensSoundSettings() {
    #expect(routeVol(.volumeUp, [.option]) == .openSoundSettings)
    #expect(routeVol(.mute, [.option]) == .openSoundSettings)
  }
  @Test func optionOnlyVolumeRepeatDoesNothing() {
    #expect(routeVol(.volumeDown, isRepeat: true, [.option]) == .none)
  }
  @Test func optionShiftVolumeIsFineStepNotDeepLink() {
    #expect(routeVol(.volumeDown, [.option, .shift]) == .stepVolume(isUp: false, isFine: true))
  }

  // Fork-parity pins (review T6-Q1): the cells future edits would most
  // plausibly break — key-up routes regardless of modifiers (the fork plays
  // the feedback sound on an Option-only release too), only EXACT Option is
  // the deep link, and brightness-family chords mean nothing to volume.
  @Test func modifiedVolumeKeyUpStillRoutesTheRelease() {
    #expect(routeVol(.volumeUp, pressed: false, [.option]) == .volumeKeyUp)
  }
  @Test func optionShiftMuteTogglesNotDeepLink() {
    #expect(routeVol(.mute, [.option, .shift]) == .toggleMute)
  }
  @Test func controlCommandVolumeIsAPlainStep() {
    #expect(routeVol(.volumeUp, [.control, .command]) == .stepVolume(isUp: true, isFine: false))
  }
}
