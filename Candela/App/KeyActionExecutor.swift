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

  /// `isFresh` distinguishes a fresh keypress from key-repeat (review I18) and
  /// is plumbed down to `step` for the media-key semantics that separate the
  /// two.
  func execute(_ action: KeyAction, isFresh: Bool = true) {
    switch action {
    case let .stepBrightness(isUp, isFine, scope):
      switch scope {
      case .affected:
        // Fork parity (DisplayManager.getAffectedDisplays): an unmodified
        // brightness press acts on the display the user is working on — the
        // one under the pointer — not on every external at once. Only that
        // display steps, and only it shows a HUD.
        if let displayID = Self.pointerDisplayID(),
           let (id, name, newValue) = model.stepBrightness(
             displayID: displayID, isUp: isUp, isFine: isFine, isFresh: isFresh
           )
        {
          showHUD(id: id, name: name, value: newValue)
        } else {
          // The pointer sits on a display we don't control (or no screen
          // claimed it / it reported no display ID). Rather than swallow the
          // press, fall back to the previous behavior and step every external
          // — losing the targeting is better than losing the keypress.
          stepAllExternal(isUp: isUp, isFine: isFine, isFresh: isFresh)
        }
      case .allExternal:
        stepAllExternal(isUp: isUp, isFine: isFine, isFresh: isFresh)
      case .builtInOnly:
        // M2 deferral closed (Task 10): Ctrl-directed steps drive the
        // built-in panel through its native-path controller. HUD on the
        // built-in display.
        if let (id, name, newValue) = model.stepBrightnessBuiltIn(
          isUp: isUp, isFine: isFine, isFresh: isFresh
        ) {
          hud?.showBrightness(displayID: id, name: name, value: newValue)
        }
      }
    case let .toggleMirroringOrStepDown(isFine):
      // Fork fall-through: when mirroring is not applicable (single display),
      // Cmd+BrightnessDown acts as a normal brightness-down step — and a plain
      // step is `.affected`, same as rule 6.
      if !Mirroring.engageMirror() {
        execute(.stepBrightness(isUp: false, isFine: isFine, scope: .affected), isFresh: isFresh)
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

  private func stepAllExternal(isUp: Bool, isFine: Bool, isFresh: Bool) {
    for (id, name, newValue) in model.stepBrightnessAllExternal(isUp: isUp, isFine: isFine, isFresh: isFresh) {
      showHUD(id: id, name: name, value: newValue)
    }
  }

  private func showHUD(id: CGDirectDisplayID, name: String, value: Double) {
    hud?.showBrightness(displayID: id, name: name, value: value)
  }

  /// The display under the mouse pointer (fork: `getCurrentDisplay(byFocus:
  /// false)`). Nil when no screen contains the pointer, or the screen that
  /// does carries no `NSScreenNumber`. Targeting the *focused* display instead
  /// is an M5 preference (fork's `useFocusInsteadOfMouse`), and belongs here.
  private static func pointerDisplayID() -> CGDirectDisplayID? {
    let location = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) else {
      return nil
    }
    return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }
}
