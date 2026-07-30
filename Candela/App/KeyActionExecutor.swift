import AppKit
import CandelaKit
import os

/// Executes routed media-key actions (spec Appendix A): steps brightness
/// through the controllers (external or Ctrl-directed built-in), presents the
/// HUD, toggles mirroring, and opens Displays settings. The M4 action
/// (contrast) logs and no-ops for now.
@MainActor
final class KeyActionExecutor {
  private let model: AppModel
  private let hud: (any BrightnessHUDPresenting)?
  private let log = Logger(subsystem: "com.rydersel.Candela", category: "keys")

  init(model: AppModel, hud: (any BrightnessHUDPresenting)?) {
    self.model = model
    self.hud = hud
  }

  /// `isFresh` distinguishes a fresh keypress from key-repeat (review I18):
  /// the HDR boost state machine toggles only on fresh presses at the range
  /// ends, never on repeats.
  func execute(_ action: KeyAction, isFresh: Bool = true) {
    switch action {
    case let .stepBrightness(isUp, isFine, scope):
      switch scope {
      case .allExternal:
        for (id, name, newValue) in model.stepBrightnessAllExternal(isUp: isUp, isFine: isFine, isFresh: isFresh) {
          // Read after the step: the engaging keypress already reports boost
          // active, so the HUD it triggers is the one that gets the rainbow.
          let boosted = model.displays.first { $0.id == id }?.controller.hdrBoostActive ?? false
          hud?.showBrightness(
            displayID: id, name: name, value: newValue,
            nameSuffix: boosted ? " · HDR" : nil, rainbow: boosted
          )
        }
      case .builtInOnly:
        // M2 deferral closed (Task 10): Ctrl-directed steps drive the
        // built-in panel through its native-path controller. HUD on the
        // built-in display; no HDR suffix/rainbow — the built-in never
        // routes boost.
        if let (id, name, newValue) = model.stepBrightnessBuiltIn(
          isUp: isUp, isFine: isFine, isFresh: isFresh
        ) {
          hud?.showBrightness(displayID: id, name: name, value: newValue)
        }
      }
    case let .toggleMirroringOrStepDown(isFine):
      // Fork fall-through: when mirroring is not applicable (single display),
      // Cmd+BrightnessDown acts as a normal brightness-down step.
      if !Mirroring.engageMirror() {
        execute(.stepBrightness(isUp: false, isFine: isFine, scope: .allExternal), isFresh: isFresh)
      }
    case .stepContrast:
      log.log("contrast keys arrive with Milestone 4")
    case .openDisplaysSettings:
      NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!
      )
    case .none:
      break
    }
  }
}
