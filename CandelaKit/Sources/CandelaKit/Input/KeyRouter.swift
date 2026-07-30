/// Pure routing of media-key presses to actions, implementing the fork's
/// modifier semantics (spec Appendix A). Transplanted decision order from
/// MonitorControl's MediaKeyTapManager.handle.
//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

/// Which displays a brightness step targets.
public enum BrightnessScope: Sendable, Equatable {
  case allExternal // default, and Ctrl+Cmd directed
  case builtInOnly // Ctrl directed (executor no-ops until M3)
}

/// What the executor (Task 5) should do for a routed media-key press.
public enum KeyAction: Sendable, Equatable {
  /// Cmd+BrightnessDown fresh press. Executor tries to toggle mirroring;
  /// if mirroring is not applicable (single display) it falls back to a
  /// normal brightness-down step — that is the fork's fall-through.
  case toggleMirroringOrStepDown(isFine: Bool)
  case openDisplaysSettings // Option-only, fresh press
  case stepBrightness(isUp: Bool, isFine: Bool, scope: BrightnessScope)
  case stepContrast(isUp: Bool, isFine: Bool) // Ctrl+Opt+Cmd (executor no-ops until M4)
  case none // swallowed, nothing to do (keyups, repeats of one-shot combos)
}

public enum KeyRouter {
  public static func route(_ press: MediaKeyPress, config: KeyRouterConfig) -> KeyAction {
    let isBrightnessKey = press.key == .brightnessUp || press.key == .brightnessDown
    guard isBrightnessKey else { return .none } // volume/mute inert until M4
    guard press.isPressed else { return .none }
    let isUp = press.key == .brightnessUp

    // Rule 3 (fine-step computation, hoisted — no earlier rule consumes it
    // in the fork; `.toggleMirroringOrStepDown(isFine:)` only carries it for
    // the executor's fall-through step):
    var isFine = press.modifiers.isSuperset(of: [.option, .shift])
    if config.useFineScaleBrightness { isFine.toggle() }

    // Rule 1: mirroring — Cmd (without Ctrl) + BrightnessDown. Fresh press
    // only; a repeat matching this pattern is swallowed, never re-fired and
    // never allowed to fall through to a plain step.
    if press.modifiers.isSuperset(of: [.command]),
       !press.modifiers.contains(.control),
       press.key == .brightnessDown
    {
      return press.isRepeat ? .none : .toggleMirroringOrStepDown(isFine: isFine)
    }

    // Rule 2: settings deep-link — exactly Option, nothing else. Fresh press
    // opens Displays settings; a repeat is swallowed.
    if press.modifiers == [.option] {
      return press.isRepeat ? .none : .openDisplaysSettings
    }

    // Rule 4: directed brightness — Ctrl without Option. Cmd widens the
    // target from the built-in display to all external displays.
    if press.modifiers.isSuperset(of: [.control]), !press.modifiers.contains(.option) {
      let scope: BrightnessScope = press.modifiers.isSuperset(of: [.command]) ? .allExternal : .builtInOnly
      return .stepBrightness(isUp: isUp, isFine: isFine, scope: scope)
    }

    // Rule 5: contrast — Ctrl+Opt+Cmd. Cannot collide with rule 4 (which
    // requires Option absent).
    if press.modifiers.isSuperset(of: [.control, .option, .command]) {
      return .stepContrast(isUp: isUp, isFine: isFine)
    }

    // Rule 6: plain brightness step. Repeats DO fire here — holding the key
    // steps repeatedly.
    return .stepBrightness(isUp: isUp, isFine: isFine, scope: .allExternal)
  }
}
