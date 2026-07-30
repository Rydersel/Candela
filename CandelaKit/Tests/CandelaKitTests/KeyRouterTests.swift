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
    #expect(route(.brightnessUp) == .stepBrightness(isUp: true, isFine: false, scope: .allExternal))
  }
  @Test func plainBrightnessDown() {
    #expect(route(.brightnessDown) == .stepBrightness(isUp: false, isFine: false, scope: .allExternal))
  }
  @Test func repeatStillSteps() {
    #expect(route(.brightnessUp, isRepeat: true) == .stepBrightness(isUp: true, isFine: false, scope: .allExternal))
  }
  @Test func keyUpDoesNothing() {
    #expect(route(.brightnessUp, pressed: false) == .none)
  }

  // Fine steps + inversion pref
  @Test func optShiftIsFine() {
    #expect(route(.brightnessUp, [.option, .shift]) == .stepBrightness(isUp: true, isFine: true, scope: .allExternal))
  }
  @Test func fineScalePrefInvertsPlain() {
    #expect(route(.brightnessUp, fineScalePref: true) == .stepBrightness(isUp: true, isFine: true, scope: .allExternal))
  }
  @Test func fineScalePrefInvertsOptShift() {
    #expect(route(.brightnessUp, [.option, .shift], fineScalePref: true)
      == .stepBrightness(isUp: true, isFine: false, scope: .allExternal))
  }

  // Mirroring (rule 1)
  @Test func cmdBrightnessDownFreshTogglesMirroring() {
    #expect(route(.brightnessDown, [.command]) == .toggleMirroringOrStepDown(isFine: false))
  }
  @Test func cmdBrightnessDownRepeatDoesNothing() {
    #expect(route(.brightnessDown, isRepeat: true, [.command]) == .none)
  }
  @Test func cmdBrightnessUpIsNotMirroring() {
    #expect(route(.brightnessUp, [.command]) == .stepBrightness(isUp: true, isFine: false, scope: .allExternal))
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
      == .stepBrightness(isUp: false, isFine: true, scope: .allExternal))
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

  // Volume keys must be inert in M2
  @Test func volumeKeysRouteToNone() {
    #expect(route(.volumeUp) == .none)
    #expect(route(.volumeDown, [.option, .shift]) == .none)
    #expect(route(.mute) == .none)
  }
}
