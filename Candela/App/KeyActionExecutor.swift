import AppKit
import CandelaKit
import os

/// Executes routed media-key actions (spec Appendix A): steps brightness
/// through the controllers, presents the HUD, toggles mirroring, and opens
/// Displays settings. The M3/M4 actions (built-in brightness, contrast) log
/// and no-op for now.
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
          hud?.showBrightness(displayID: id, name: name, value: newValue)
        }
      case .builtInOnly:
        log.log("directed built-in brightness arrives with Milestone 3")
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
