import AppKit
import CandelaKit

/// Executes routed media-key actions (spec Appendix A): steps brightness,
/// volume, mute and contrast through the controllers (external or
/// Ctrl-directed built-in), presents the HUD, plays the system volume
/// feedback blip, toggles mirroring, and opens Displays/Sound settings.
@MainActor
final class KeyActionExecutor {
  private let model: AppModel
  private let hud: (any BrightnessHUDPresenting)?
  private let feedback = VolumeFeedbackSound()

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
        } else if !model.controlsAnyDisplay(in: affected) {
          // Nothing resolved AT ALL: pointer on an uncontrolled display, or
          // no screen claimed it — fall back to stepping every external
          // (losing the targeting is better than losing the keypress, M2
          // rule). A resolved-but-keyboard-disabled display does NOT take
          // this branch: the fork skips it in the loop body and swallows
          // the press (R1).
          stepAllExternal(isUp: isUp, isFine: isFine, isFresh: isFresh)
        }
      case .allExternal:
        stepAllExternal(isUp: isUp, isFine: isFine, isFresh: isFresh)
      case .builtInOnly:
        // Ctrl-directed steps drive the built-in panel through its
        // native-path controller. HUD on the built-in display.
        if let (id, name, newValue) = model.stepBrightnessBuiltIn(
          isUp: isUp, isFine: isFine, isFresh: isFresh
        ) {
          showHUD(id: id, name: name, value: newValue)
        }
      }
    case let .toggleMirroringOrStepDown(isFine):
      // Fork fall-through: when mirroring is not applicable (single display),
      // Cmd+BrightnessDown acts as a normal brightness-down step — and a plain
      // step is `.affected`, same as rule 6.
      if !Mirroring.engageMirror() {
        execute(.stepBrightness(isUp: false, isFine: isFine, scope: .affected), isFresh: isFresh)
      }
    case let .stepVolume(isUp, isFine):
      // Feedback sound deliberately absent here — it plays on key RELEASE
      // (.volumeKeyUp), fork parity.
      for state in resolveVolumeTargets() {
        guard let newValue = state.volume.step(isUp: isUp, isFine: isFine) else { continue }
        showVolumeHUD(state: state, value: newValue)
      }
    case .toggleMute:
      // Fresh-press only, twice over: the router swallows repeats and the
      // controller consumes isFresh (backlog #12b).
      var playedOnce = false
      for state in resolveVolumeTargets() {
        let muted = state.volume.toggleMute(isFresh: isFresh)
        guard state.volume.isAvailable else { continue }
        showVolumeHUD(state: state, value: muted ? 0 : state.volume.value)
        // Fork rule: mute plays feedback on key DOWN, once per event, only
        // when the resulting state is unmuted.
        if !playedOnce, !muted {
          feedback.play()
          playedOnce = true
        }
      }
    case .volumeKeyUp:
      // Fork rule: volume steps play feedback on key release, once per event,
      // only when some affected display has volume enabled.
      if resolveVolumeTargets().contains(where: { $0.volume.isAvailable }) {
        feedback.play()
      }
    case let .stepContrast(isUp, isFine):
      // Contrast targets `.affected` like plain brightness (fork: contrast
      // follows the brightness mouse policy), with the same fall-back-to-all
      // — fallback BEFORE the isDisabled filter, so a resolved-but-disabled
      // display swallows the press instead of triggering the fallback (R1).
      let affected = Self.pointerDisplayID().map(Self.expandToMirrorSet) ?? []
      var targets = affected.compactMap { id in model.displays.first { $0.id == id } }
      if targets.isEmpty { targets = model.displays }
      for state in model.keyEnabledStates(targets) {
        guard let newValue = state.contrast.step(isUp: isUp, isFine: isFine) else { continue }
        hud?.showHUD(
          displayID: state.id, type: .contrast, name: state.display.name, value: Float(newValue)
        )
      }
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

  /// Volume-key target set per multiKeyboardVolume (D4). Every branch runs
  /// through the isDisabled key filter LAST (R1, fork loop-body parity) — so
  /// a resolved-but-disabled display swallows the press rather than
  /// triggering the fallback.
  private func resolveVolumeTargets() -> [AppModel.DisplayState] {
    switch model.volumeMode {
    case .allScreens:
      return model.keyEnabledStates(model.displays)
    case .audioDeviceNameMatching:
      // Zero matches never falls back — the tap rule already released the
      // keys to macOS in that state (fork parity).
      return model.keyEnabledStates(model.audioMatchingDisplays())
    case .mouse:
      let ids = Self.pointerDisplayID().map(Self.expandToMirrorSet) ?? []
      let resolved = ids.compactMap { id in model.displays.first { $0.id == id } }
      // DIVERGENCE from the fork (planner flag 6, endorsed): the fork
      // SWALLOWS the press when the pointer resolves no external (its tap
      // already ate the event and it has no fallback — the dossier calls
      // that a defect). Candela extends its own M2 brightness rule: losing
      // the targeting beats losing the keypress.
      let targets = resolved.isEmpty ? model.displays : resolved
      return model.keyEnabledStates(targets)
    }
  }

  private func showVolumeHUD(state: AppModel.DisplayState, value: Double) {
    // Fork hideOsd parity (R1): per-display volume-OSD suppression gates the
    // VOLUME/MUTE pills only — brightness/contrast pills ignore it (the fork
    // consults it solely on the volume paths). The write itself still lands.
    guard !DisplayPrefs(persistenceKey: state.display.persistenceKey).hideOsd else { return }
    hud?.showHUD(
      displayID: state.id,
      type: state.volume.isMuted ? .volumeMuted : .volume,
      name: state.display.name,
      value: Float(value)
    )
  }

  private func showHUD(id: CGDirectDisplayID, name: String, value: Double) {
    // Backlog #11 (D6): the HUD mirrors the badge's LIVENESS predicate
    // (isHDREngaged — HDR live however it got there), not the policy
    // (hdrMode). One predicate for both surfaces, decided deliberately.
    hud?.showBrightness(displayID: id, name: name, value: value, nameSuffix: hdrSuffix(for: id))
  }

  private func hdrSuffix(for id: CGDirectDisplayID) -> String? {
    let controller = model.displays.first(where: { $0.id == id })?.controller
      ?? (model.builtIn?.id == id ? model.builtIn?.controller : nil)
    return controller?.isHDREngaged == true ? " · HDR" : nil
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
