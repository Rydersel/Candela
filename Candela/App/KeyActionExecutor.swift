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
          //
          // Both step paths are announced TOGETHER, in one call. A built-in
          // mirroring an external shares that master's pill, so announcing the
          // two paths separately would let the second overwrite the first
          // (#123, the same collapse the loops below avoid).
          var stepped = model.stepBrightnessAllExternal(isUp: isUp, isFine: isFine)
          if let builtInStep = model.stepBrightnessBuiltIn(isUp: isUp, isFine: isFine) {
            stepped.append(builtInStep)
          }
          showBrightnessHUDs(for: stepped)
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
          showBrightnessHUDs(for: stepped)
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
        if let builtInStep = model.stepBrightnessBuiltIn(isUp: isUp, isFine: isFine) {
          showBrightnessHUDs(for: [builtInStep])
        }
      }
    case let .toggleMirroringOrStepDown(isFine):
      // Fork fall-through, PRESERVED: when mirroring is not applicable (a
      // single display), Cmd+BrightnessDown acts as a normal brightness-down
      // step — and a plain step is `.affected`, same as rule 6.
      //
      // `.onlyOneDisplay` is the ONE refusal that falls through. The other seven
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
      var stepped: [(state: AppModel.DisplayState, value: Double)] = []
      for state in resolveVolumeTargets() {
        guard let newValue = state.volume.step(isUp: isUp, isFine: isFine) else { continue }
        stepped.append((state, newValue))
      }
      showVolumeHUDs(stepped)
    case .toggleMute:
      // Fresh-press only, twice over: the router swallows repeats and the
      // controller consumes isFresh (backlog #12b).
      var playedOnce = false
      var toggled: [(state: AppModel.DisplayState, value: Double)] = []
      // Mute targets, not volume targets: the mute key writes 0x8D under the
      // dedicated-command strategy, and a display's two registers carry their
      // own verdicts.
      for state in resolveMuteTargets() {
        let muted = state.volume.toggleMute(isFresh: isFresh)
        guard state.volume.isAvailable else { continue }
        toggled.append((state, muted ? 0 : state.volume.value))
        // Fork rule: mute plays feedback on key DOWN, once per event, only
        // when the resulting state is unmuted. It stays inside this loop: it
        // answers the WRITES, which every target takes, and not the pills,
        // which a mirror set shares.
        if !playedOnce, !muted {
          feedback.play()
          playedOnce = true
        }
      }
      showVolumeHUDs(toggled)
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
      var stepped: [(state: AppModel.DisplayState, value: Double)] = []
      for state in model.keyEnabledStates(targets) {
        guard let newValue = state.contrast.step(isUp: isUp, isFine: isFine) else { continue }
        stepped.append((state, newValue))
      }
      // Contrast follows the BRIGHTNESS position, the same line `hideOsd`
      // already draws: it is a picture control, stepped by the brightness key
      // family, and volume and mute are the pair that gets its own place.
      showStateHUDs(stepped, position: appPrefs.hudPositionBrightness) { _ in .contrast }
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
    showBrightnessHUDs(for: stepped)
    guard stepped.isEmpty,
          let builtInStep = model.stepBrightnessBuiltIn(isUp: isUp, isFine: isFine)
    else { return }
    showBrightnessHUDs(for: [builtInStep])
  }

  /// Volume-key targets: the candidates below, filtered by D24's verdict for
  /// VCP 0x62. A display whose own capabilities deny that register takes no
  /// volume key, exactly as its slider takes no drag.
  private func resolveVolumeTargets() -> [AppModel.DisplayState] {
    model.volumeKeyEnabledStates(volumeKeyCandidates())
  }

  /// Mute-key targets: the same candidates, filtered against the register the
  /// mute key would actually WRITE. That is VCP 0x8D under the dedicated-command
  /// strategy and the volume register without it, so the two families can
  /// legitimately disagree about one display, and a mute-capable panel that
  /// denies volume keeps its mute key.
  private func resolveMuteTargets() -> [AppModel.DisplayState] {
    model.muteKeyEnabledStates(volumeKeyCandidates())
  }

  /// Volume/mute candidate set per multiKeyboardVolume (D4), before any
  /// per-display filter.
  ///
  /// The fallbacks live HERE and the filters live at the two call sites above,
  /// which is the whole R1 ordering (fork loop-body parity): a display that
  /// resolves and then refuses swallows the press, while only a display that
  /// never resolved at all reaches a fallback. Folding either filter into this
  /// function would hand a refusing display's keypress to every other panel.
  private func volumeKeyCandidates() -> [AppModel.DisplayState] {
    switch model.volumeMode {
    case .allScreens:
      return model.displays
    case .audioDeviceNameMatching:
      // Zero matches never falls back (fork parity). Two states reach here:
      // the tap released the keys to macOS (default output can set its own
      // volume), OR the keys stay watched with a nil default output — the
      // tap rule can't distinguish that from "not yet routed" — and the
      // empty match set swallows the press.
      return model.audioMatchingDisplays()
    case .mouse:
      let ids = Self.pointerDisplayID().map(expandToMirrorSet) ?? []
      let resolved = ids.compactMap { id in model.displays.first { $0.id == id } }
      // DIVERGENCE from the fork (planner flag 6, endorsed): the fork
      // SWALLOWS the press when the pointer resolves no external (its tap
      // already ate the event and it has no fallback — the dossier calls
      // that a defect). Candela extends its own M2 brightness rule: losing
      // the targeting beats losing the keypress.
      return resolved.isEmpty ? model.displays : resolved
    }
  }

  private func showVolumeHUDs(_ stepped: [(state: AppModel.DisplayState, value: Double)]) {
    // Fork hideOsd parity (R1): per-display volume-OSD suppression gates the
    // VOLUME/MUTE pills only — brightness/contrast pills ignore it (the fork
    // consults it solely on the volume paths). The write itself still lands.
    //
    // Filtered BEFORE the grouping, so the pref keeps exactly the meaning it
    // had per display: a suppressed display shows no pill and is not counted
    // among the others sharing one.
    showStateHUDs(
      stepped.filter { !DisplayPrefs(persistenceKey: $0.state.display.persistenceKey).hideOsd },
      position: appPrefs.hudPositionVolume
    ) { $0.volume.isMuted ? .volumeMuted : .volume }
  }

  /// ONE pill per placement display, not one per stepped display (#123).
  ///
  /// Every member of a mirror set draws on the master, and `BrightnessHUD` keys
  /// its windows by that ID, so announcing members one at a time wrote the same
  /// window repeatedly and the last write won. `HUDGrouping` decides which
  /// display each pill reports; the count it returns is what keeps a pill from
  /// implying the members it cannot name stood still.
  ///
  /// Backlog #11 (D6): the HDR marker mirrors the badge's LIVENESS predicate
  /// (`isHDREngaged`, HDR live however it got there), not the policy
  /// (`hdrMode`). One predicate for both surfaces, decided deliberately.
  ///
  /// Placement is resolved HERE rather than inside the island, which holds no
  /// judgement (DT16): a mirrored panel is absent from `NSScreen.screens`, so
  /// an unresolved ID makes the island show nothing at all, silently, while the
  /// DDC write lands and the panel visibly changes.
  ///
  /// ONE topology sample serves the whole announcement, so the pills of a
  /// single keypress cannot disagree about the rig. A sample that lags a mirror
  /// BREAKING resolves an ex-slave to its ex-master, which is a real screen:
  /// the pill lands on the wrong display for the moment before the next
  /// screen-parameters notification. That is the one-directional half of the
  /// store's guarantee, and a misplaced pill is the cheapest place in the app
  /// to pay it.
  private func showBrightnessHUDs(
    for stepped: [(id: CGDirectDisplayID, name: String, newValue: Double)]
  ) {
    let topology = model.mirrorTopology.topology()
    for pill in HUDGrouping.pills(forStepped: stepped.map { $0.id }, topology: topology) {
      guard let named = stepped.first(where: { $0.id == pill.named }) else { continue }
      hud?.showBrightness(
        displayID: pill.placement,
        name: hudName(id: named.id, hardwareName: named.name),
        value: named.newValue,
        nameSuffix: HUDGrouping.nameSuffix(
          isHDREngaged: isHDREngaged(named.id), othersInSet: pill.othersInSet
        ),
        position: appPrefs.hudPositionBrightness,
        style: appPrefs.hudStyle
      )
    }
  }

  /// The volume/contrast half of the same rule. These pills have never carried
  /// the HDR marker (it reports a brightness-path fact), so only the set count
  /// reaches their suffix.
  private func showStateHUDs(
    _ stepped: [(state: AppModel.DisplayState, value: Double)],
    position: HUDPosition,
    type: (AppModel.DisplayState) -> HUDType
  ) {
    let topology = model.mirrorTopology.topology()
    for pill in HUDGrouping.pills(forStepped: stepped.map { $0.state.id }, topology: topology) {
      guard let named = stepped.first(where: { $0.state.id == pill.named }) else { continue }
      hud?.showHUD(
        displayID: pill.placement,
        type: type(named.state),
        name: hudName(for: named.state),
        value: Float(named.value),
        maxValue: 1,
        nameSuffix: HUDGrouping.nameSuffix(isHDREngaged: false, othersInSet: pill.othersInSet),
        position: position,
        style: appPrefs.hudStyle
      )
    }
  }

  /// The app-level defaults, re-read at every announcement rather than cached:
  /// the indicator positions and style (KMR-A3) fan out to `.refreshUI` alone,
  /// so a pill drawn after either picker moves has to pick the new value up
  /// here; the island rebuilds its cached window on a style mismatch.
  private var appPrefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

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

  private func isHDREngaged(_ id: CGDirectDisplayID) -> Bool {
    let controller = model.displays.first(where: { $0.id == id })?.controller
      ?? (model.builtIn?.id == id ? model.builtIn?.controller : nil)
    return controller?.isHDREngaged == true
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

}
