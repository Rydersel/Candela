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

  /// `isFresh` distinguishes a fresh keypress from key-repeat (review I18);
  /// mute toggling and the mirror-toggle fallback consume it — brightness
  /// stepping deliberately does not.
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
        //
        // `multiKeyboardBrightness` (read live, per press) redirects which
        // display that is: every screen at once, or the one owning the focused
        // window instead of the pointer.
        let mode = DisplayPrefs(persistenceKey: "app").multiKeyboardBrightness
        if mode == .allScreens {
          // Fork getAffectedDisplays(.allScreens): every display, built-in
          // included — so this is NOT the same as the `.allExternal` scope.
          stepAllExternal(isUp: isUp, isFine: isFine)
          if let (id, name, newValue) = model.stepBrightnessBuiltIn(
            isUp: isUp, isFine: isFine
          ) {
            showHUD(id: id, name: name, value: newValue)
          }
          return
        }
        // Focus mode falls back to the pointer when no window resolves (a
        // full-screen-less desktop, a frontmost app with no on-screen window):
        // losing the targeting refinement beats losing the keypress.
        let anchor: CGDirectDisplayID? = (mode == .focusInsteadOfMouse
          ? FocusedDisplay.frontmostWindowDisplayID()
          : nil) ?? Self.pointerDisplayID()
        let affected = anchor.map(expandToMirrorSet) ?? []
        let stepped = model.stepBrightness(
          displayIDs: affected, isUp: isUp, isFine: isFine
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
          stepEveryControlledDisplay(isUp: isUp, isFine: isFine)
        }
      case .allExternal:
        stepEveryControlledDisplay(isUp: isUp, isFine: isFine)
      case .builtInOnly:
        // Ctrl-directed steps drive the built-in panel through its
        // native-path controller. HUD on the built-in display.
        if let (id, name, newValue) = model.stepBrightnessBuiltIn(
          isUp: isUp, isFine: isFine
        ) {
          showHUD(id: id, name: name, value: newValue)
        }
      }
    case let .toggleMirroringOrStepDown(isFine):
      // Fork fall-through, PRESERVED: when mirroring is not applicable (a
      // single display), Cmd+BrightnessDown acts as a normal brightness-down
      // step — and a plain step is `.affected`, same as rule 6.
      //
      // `.onlyOneDisplay` is the ONE refusal that falls through. The other six
      // become a report on screen rather than a silent `false`, which is what
      // the bare `Bool` this replaced could not express.
      //
      // The coordinator answers SYNCHRONOUSLY for exactly this question and
      // queues everything else: a keypress cannot wait for a task chain to
      // learn whether it was a keypress about brightness.
      if !model.mirroring.toggleUnlessSingleDisplay() {
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
      let affected = Self.pointerDisplayID().map(expandToMirrorSet) ?? []
      var targets = affected.compactMap { id in model.displays.first { $0.id == id } }
      if targets.isEmpty { targets = model.displays }
      for state in model.keyEnabledStates(targets) {
        guard let newValue = state.contrast.step(isUp: isUp, isFine: isFine) else { continue }
        hud?.showHUD(
          displayID: hudDisplayID(state.id), type: .contrast,
          name: hudName(for: state), value: Float(newValue)
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

  private func stepAllExternal(isUp: Bool, isFine: Bool) {
    for (id, name, newValue) in model.stepBrightnessAllExternal(isUp: isUp, isFine: isFine) {
      showHUD(id: id, name: name, value: newValue)
    }
  }

  /// The BOTTOM of the brightness fallback chain: every external, and the
  /// built-in only if that stepped nothing.
  ///
  /// #72. The tap commits the swallow on its own thread, from
  /// `config.watchedKeys`, before anything knows what the press would act on
  /// (`MediaKeyEventTap.process`). That config is refreshed AFTER
  /// `await model.refresh()` (`StatusItemController`), so for the duration of a
  /// refresh — a dock cycle, a replug — brightness keys are still swallowed
  /// against the old config while `model.displays` is already empty. The press
  /// is consumed and then has nothing left to act on: the key is simply dead.
  ///
  /// Stepping the built-in is the last resort that keeps that from happening.
  /// It is where all three bottom-out routes meet — `.allExternal`, a stale
  /// pointer ID, and a nil anchor — so no site can acquire the dead-key
  /// behaviour again on its own.
  ///
  /// Deliberately NOT pushed down into `stepBrightness`'s loop body: R1 rules
  /// that a resolved-but-keyboard-disabled display SWALLOWS its press, and this
  /// must fire only where nothing resolved at all. `.allScreens` keeps calling
  /// `stepAllExternal` plus its own unconditional built-in step — it steps both
  /// every time by definition, which is not a fallback.
  ///
  /// A machine with no built-in and no controlled external is still dead here;
  /// only tap-side pass-through reaches that, and #72 records why the tap was
  /// left alone (#59: an active head-insert tap froze the machine twice).
  private func stepEveryControlledDisplay(isUp: Bool, isFine: Bool) {
    let stepped = model.stepBrightnessAllExternal(isUp: isUp, isFine: isFine)
    for (id, name, newValue) in stepped {
      showHUD(id: id, name: name, value: newValue)
    }
    guard stepped.isEmpty,
          let (id, name, newValue) = model.stepBrightnessBuiltIn(isUp: isUp, isFine: isFine)
    else { return }
    showHUD(id: id, name: name, value: newValue)
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
      // Zero matches never falls back (fork parity). Two states reach here:
      // the tap released the keys to macOS (default output can set its own
      // volume), OR the keys stay watched with a nil default output — the
      // tap rule can't distinguish that from "not yet routed" — and the
      // empty match set swallows the press.
      return model.keyEnabledStates(model.audioMatchingDisplays())
    case .mouse:
      let ids = Self.pointerDisplayID().map(expandToMirrorSet) ?? []
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
      displayID: hudDisplayID(state.id),
      type: state.volume.isMuted ? .volumeMuted : .volume,
      name: hudName(for: state),
      value: Float(value)
    )
  }

  private func showHUD(id: CGDirectDisplayID, name: String, value: Double) {
    // Backlog #11 (D6): the HUD mirrors the badge's LIVENESS predicate
    // (isHDREngaged — HDR live however it got there), not the policy
    // (hdrMode). One predicate for both surfaces, decided deliberately.
    //
    // The NAME and the HDR suffix stay keyed on the display that was STEPPED;
    // only the placement resolves. A pill on the master naming the panel whose
    // brightness moved is the honest reading of a mirror set.
    hud?.showBrightness(
      displayID: hudDisplayID(id),
      name: hudName(id: id, hardwareName: name),
      value: value,
      nameSuffix: hdrSuffix(for: id)
    )
  }

  /// What the HUD calls a display. The model hands every step path the RAW
  /// hardware name, so the rename the user made in the Displays pane has to be
  /// applied here — through `DisplayOrdering.title`, the same rule the panel
  /// uses, or the same display would be named two different things depending on
  /// whether it was opened or pressed at.
  private func hudName(for state: AppModel.DisplayState) -> String {
    DisplayOrdering.title(
      friendlyName: DisplayPrefs(persistenceKey: state.display.persistenceKey).friendlyName,
      hardwareName: state.display.name
    )
  }

  /// Same rule, from an ID: the step results carry `(id, hardwareName, value)`
  /// and not the state. An unresolvable ID keeps the hardware name.
  private func hudName(id: CGDirectDisplayID, hardwareName: String) -> String {
    let state = model.displays.first { $0.id == id }
      ?? model.builtIn.flatMap { $0.id == id ? $0 : nil }
    guard let state else { return hardwareName }
    return hudName(for: state)
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

  /// `displayID` plus, when it is the master of a mirror set, every display
  /// mirroring it (fork: the mirror-set expansion inside `getAffectedDisplays`).
  /// A mirrored member is never the pointer's display in practice, but the
  /// master's ID is what the pointer resolves to, and the members need the same
  /// step — the set shows one picture, so stepping only the master would leave
  /// it visibly mismatched. Non-mirrored displays expand to themselves.
  ///
  /// Reads ONE sample from the topology store rather than re-querying
  /// CoreGraphics per call site (DT13). The three call sites here each used to
  /// take a fresh `CGGetOnlineDisplayList` plus N `CGDisplayMirrorsDisplay`
  /// calls, so two presses a frame apart could disagree about the topology —
  /// and the predicate they used was one of the three disagreeing definitions
  /// of "mirrored" this app used to carry.
  ///
  /// These are STEP targets, so they stay RAW: what comes back is fed to
  /// `model.stepBrightness(displayIDs:)` and to the volume/contrast
  /// controllers, which write DDC to the panel the user asked for. Nothing on
  /// this path resolves to a master — D29 leaves it UNVERIFIED whether a
  /// slave's DDC is suppressed, and treating it as unavailable would put VCP
  /// 0x8D out of reach and strand a hardware-muted panel with no way back.
  private func expandToMirrorSet(_ displayID: CGDirectDisplayID) -> [CGDirectDisplayID] {
    model.mirrorTopology.topology().expand(displayID)
  }

  /// Where this display's HUD belongs: its own screen, or its mirror MASTER's.
  ///
  /// A mirrored panel is absent from `NSScreen.screens`, so `BrightnessHUD`'s
  /// lookup returns nil and it shows nothing at all — silently, while the DDC
  /// write lands and the panel visibly changes. Resolving here rather than
  /// inside the island keeps the island free of judgement (DT16).
  ///
  /// A stepped set therefore shows ONE pill, on the master: every member
  /// resolves to the same ID, and `BrightnessHUD` keys its windows by ID. Only
  /// the PLACEMENT resolves — the name and the HDR suffix stay keyed on the
  /// display that was stepped.
  ///
  /// A sample that lags a mirror BREAKING resolves an ex-slave to its
  /// ex-master, which is a real screen: the pill lands on the wrong display for
  /// the moment before the next screen-parameters notification. That is the
  /// one-directional half of the store's guarantee, and a misplaced pill is the
  /// cheapest place in the app to pay it.
  private func hudDisplayID(_ displayID: CGDirectDisplayID) -> CGDirectDisplayID {
    model.mirrorTopology.drawableDisplayID(for: displayID)
  }
}
