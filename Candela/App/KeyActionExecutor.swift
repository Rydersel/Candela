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
        // one under the pointer — not on every external at once. That display
        // steps, plus (same as the fork) every display mirroring it when it
        // drives a mirror set: the members show the same picture, so stepping
        // only the master would leave the set visibly mismatched. Each stepped
        // display shows its own HUD.
        let affected = Self.pointerDisplayID().map(Self.expandToMirrorSet) ?? []
        let stepped = model.stepBrightness(
          displayIDs: affected, isUp: isUp, isFine: isFine, isFresh: isFresh
        )
        if !stepped.isEmpty {
          for (id, name, newValue) in stepped {
            showHUD(id: id, name: name, value: newValue)
          }
        } else {
          // Nothing resolved: the pointer sits on a display we don't control
          // (and neither is anything mirroring it), or no screen claimed the
          // pointer / it reported no display ID. Rather than swallow the
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
    case .stepContrast, .stepVolume, .toggleMute, .volumeKeyUp:
      log.log("volume/contrast execution arrives later in Milestone 4 (task 10)")
    case .openSoundSettings:
      NSWorkspace.shared.open(
        URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!
      )
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

  /// `displayID` plus, when it is the master of a mirror set, every online
  /// display mirroring it (fork: the mirror-set expansion inside
  /// `getAffectedDisplays`). A mirrored member is never the pointer's display
  /// in practice, but the master's ID is what the pointer resolves to, and the
  /// members need the same step. Non-mirrored displays expand to themselves.
  private static func expandToMirrorSet(_ displayID: CGDirectDisplayID) -> [CGDirectDisplayID] {
    guard CGDisplayIsInHWMirrorSet(displayID) != 0 || CGDisplayIsInMirrorSet(displayID) != 0,
          CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay
    else {
      return [displayID]
    }
    var onlineDisplayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &onlineDisplayIDs, &displayCount) == .success else {
      return [displayID]
    }
    let members = onlineDisplayIDs.prefix(Int(displayCount))
      .filter { CGDisplayMirrorsDisplay($0) == displayID }
    return [displayID] + members
  }
}
