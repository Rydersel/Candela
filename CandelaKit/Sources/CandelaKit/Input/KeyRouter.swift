/// Pure routing of media-key presses to actions, implementing the fork's
/// modifier semantics (spec Appendix A). Transplanted decision order from
/// MonitorControl's MediaKeyTapManager.handle.
//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

/// Which displays a brightness step targets.
public enum BrightnessScope: Sendable, Equatable {
  /// The display the user is working on, resolved app-side because the engine
  /// has no window server. Fork parity with `getAffectedDisplays`: the current
  /// display by default, not every screen.
  case affected
  case allExternal // Ctrl+Cmd directed, and the app-side fallback when no display resolves
  case builtInOnly // Ctrl directed
}

/// What the executor should do for a routed media-key press.
public enum KeyAction: Sendable, Equatable {
  /// Cmd+BrightnessDown fresh press. When mirroring is not applicable (single
  /// display) the executor falls back to a brightness-down step, as the fork does.
  case toggleMirroringOrStepDown(isFine: Bool)
  case openDisplaysSettings // Option-only, fresh press
  case stepBrightness(isUp: Bool, isFine: Bool, scope: BrightnessScope)
  case stepContrast(isUp: Bool, isFine: Bool) // Ctrl+Opt+Cmd directed
  case stepVolume(isUp: Bool, isFine: Bool)
  case toggleMute // fresh press only; repeats swallowed
  case openSoundSettings // Option-only on a volume/mute key, fresh press
  /// Volume up/down released: the executor plays the feedback sound (fork:
  /// key-up only, once per event).
  case volumeKeyUp
  case none // swallowed, nothing to do (keyups, repeats of one-shot combos)
}

public enum KeyRouter {
  public static func route(_ press: MediaKeyPress, config: KeyRouterConfig) -> KeyAction {
    let isVolumeKey = press.key == .volumeUp || press.key == .volumeDown
    if isVolumeKey || press.key == .mute {
      return routeVolume(press, config: config, isVolumeKey: isVolumeKey)
    }
    guard press.isPressed else { return .none }
    let isUp = press.key == .brightnessUp

    // Rule 3, hoisted: no earlier rule consumes it, and
    // `.toggleMirroringOrStepDown` carries it only for the fall-through step.
    var isFine = press.modifiers.isSuperset(of: [.option, .shift])
    if config.useFineScaleBrightness { isFine.toggle() }

    // Rule 1: mirroring. A repeat is swallowed, never re-fired and never
    // allowed to fall through to a plain step.
    if press.modifiers.isSuperset(of: [.command]),
       !press.modifiers.contains(.control),
       press.key == .brightnessDown
    {
      return press.isRepeat ? .none : .toggleMirroringOrStepDown(isFine: isFine)
    }

    // Rule 2: settings deep-link, exactly Option and nothing else.
    if press.modifiers == [.option] {
      return press.isRepeat ? .none : .openDisplaysSettings
    }

    // Rule 4: directed brightness. Cmd widens the target from the built-in
    // panel to every external.
    if press.modifiers.isSuperset(of: [.control]), !press.modifiers.contains(.option) {
      let scope: BrightnessScope = press.modifiers.isSuperset(of: [.command]) ? .allExternal : .builtInOnly
      return .stepBrightness(isUp: isUp, isFine: isFine, scope: scope)
    }

    // Rule 5: contrast. Cannot collide with rule 4, which requires Option absent.
    if press.modifiers.isSuperset(of: [.control, .option, .command]) {
      return .stepContrast(isUp: isUp, isFine: isFine)
    }

    // Rule 6: plain brightness step. Repeats DO fire here, so holding the key
    // steps. Ctrl+Cmd (rule 4) stays the explicit "every external" gesture.
    return .stepBrightness(isUp: isUp, isFine: isFine, scope: .affected)
  }

  /// Volume and mute rules (spec Appendix A). Target resolution is app-side:
  /// the router decides WHAT, never WHICH display.
  private static func routeVolume(
    _ press: MediaKeyPress, config: KeyRouterConfig, isVolumeKey: Bool
  ) -> KeyAction {
    guard press.isPressed else {
      // Key release fires the feedback sound, for volume steps only: the mute
      // key does not respond to press-and-hold or keyup.
      return isVolumeKey ? .volumeKeyUp : .none
    }
    if press.modifiers == [.option] {
      return press.isRepeat ? .none : .openSoundSettings
    }
    if press.key == .mute {
      return press.isRepeat ? .none : .toggleMute
    }
    var isFine = press.modifiers.isSuperset(of: [.option, .shift])
    if config.useFineScaleVolume { isFine.toggle() }
    return .stepVolume(isUp: press.key == .volumeUp, isFine: isFine)
  }
}
