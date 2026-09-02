import AppKit
import CandelaKit

/// Executes routed media-key actions (spec Appendix A).
@MainActor
final class KeyActionExecutor {
  private let model: AppModel
  private let hud: (any BrightnessHUDPresenting)?
  private let feedback = VolumeFeedbackSound()

  init(model: AppModel, hud: (any BrightnessHUDPresenting)?) {
    self.model = model
    self.hud = hud
  }

  /// `isFresh` separates a fresh press from key-repeat: mute toggling and the
  /// mirror-toggle fallback consume it, brightness stepping does not.
  func execute(_ action: KeyAction, isFresh: Bool = true) {
    switch action {
    case let .stepBrightness(isUp, isFine, scope):
      switch scope {
      case .affected:
        // Fork parity (DisplayManager.getAffectedDisplays): an unmodified
        // press acts on the display under the pointer, plus every display
        // mirroring it, since the set shows one picture and stepping the master
        // alone leaves it visibly mismatched. `multiKeyboardBrightness`, read
        // live per press, redirects that target.
        let mode = DisplayPrefs(persistenceKey: "app").multiKeyboardBrightness
        if mode == .allScreens {
          // Fork getAffectedDisplays(.allScreens): every display, built-in
          // included, so this is NOT the `.allExternal` scope.
          //
          // Both step paths announce TOGETHER, in one call: a built-in
          // mirroring an external shares that master's pill, so two calls would
          // let the second overwrite the first.
          var stepped = model.stepBrightnessAllExternal(isUp: isUp, isFine: isFine)
          if let builtInStep = model.stepBrightnessBuiltIn(isUp: isUp, isFine: isFine) {
            stepped.append(builtInStep)
          }
          showBrightnessHUDs(for: stepped)
          return
        }
        // Focus mode falls back to the pointer when no window resolves:
        // losing the targeting beats losing the keypress. That is
        // `keyTargets`' nil-anchor case.
        let focused = mode == .focusInsteadOfMouse
          ? FocusedDisplay.frontmostWindowDisplayID()
          : nil
        let affected = keyTargets(anchoredOn: focused)
        let stepped = model.stepBrightness(
          displayIDs: affected, isUp: isUp, isFine: isFine
        )
        if !stepped.isEmpty {
          showBrightnessHUDs(for: stepped)
        } else if !model.controlsAnyDisplay(in: affected) {
          // Nothing resolved AT ALL, so step every external: losing the
          // targeting beats losing the keypress. A resolved-but-disabled
          // display does NOT come here; it swallows the press by design.
          stepEveryControlledDisplay(isUp: isUp, isFine: isFine)
        }
      case .allExternal:
        stepEveryControlledDisplay(isUp: isUp, isFine: isFine)
      case .builtInOnly:
        // Ctrl-directed steps drive the built-in panel through its
        // native-path controller.
        if let builtInStep = model.stepBrightnessBuiltIn(isUp: isUp, isFine: isFine) {
          showBrightnessHUDs(for: [builtInStep])
        }
      }
    case let .toggleMirroringOrStepDown(isFine):
      // Fork fall-through, PRESERVED: with a single display,
      // Cmd+BrightnessDown is a plain brightness-down step (`.affected`).
      // `.onlyOneDisplay` is the only refusal that falls through; every other
      // refusal reports on screen instead.
      //
      // The coordinator answers this one question SYNCHRONOUSLY and queues the
      // rest: a keypress cannot wait on a task chain to learn what it was.
      if !model.mirroring.toggleUnlessSingleDisplay() {
        execute(.stepBrightness(isUp: false, isFine: isFine, scope: .affected), isFresh: isFresh)
      }
    case let .stepVolume(isUp, isFine):
      // No feedback sound here: it plays on key RELEASE (.volumeKeyUp), fork
      // parity.
      var stepped: [(state: AppModel.DisplayState, value: Double)] = []
      for state in resolveVolumeTargets() {
        guard let newValue = state.volume.step(isUp: isUp, isFine: isFine) else { continue }
        stepped.append((state, newValue))
      }
      showVolumeHUDs(stepped)
    case .toggleMute:
      // Fresh-press only, twice over: the router swallows repeats and the
      // controller consumes isFresh.
      var playedOnce = false
      var toggled: [(state: AppModel.DisplayState, value: Double)] = []
      // Mute targets, not volume targets: the mute key writes VCP 0x8D under
      // the dedicated-command strategy, and the two registers carry their own
      // verdicts.
      for state in resolveMuteTargets() {
        let muted = state.volume.toggleMute(isFresh: isFresh)
        guard state.volume.isAvailable else { continue }
        toggled.append((state, muted ? 0 : state.volume.value))
        // Fork rule: mute plays feedback on key DOWN, once per event, only
        // when the result is unmuted. Inside the loop because it answers the
        // writes, which every target takes, not the pills, which a set shares.
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
      // Contrast targets `.affected` like plain brightness (fork parity), with
      // the fallback BEFORE the isDisabled filter, so a resolved-but-disabled
      // display swallows the press instead of triggering it.
      let affected = keyTargets()
      var targets = affected.compactMap { id in model.displays.first { $0.id == id } }
      if targets.isEmpty { targets = model.displays }
      var stepped: [(state: AppModel.DisplayState, value: Double)] = []
      for state in model.keyEnabledStates(targets) {
        guard let newValue = state.contrast.step(isUp: isUp, isFine: isFine) else { continue }
        stepped.append((state, newValue))
      }
      // Contrast uses the BRIGHTNESS position: it is a picture control stepped
      // by the brightness keys, and only volume and mute get their own place.
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
  /// `MediaKeyEventTap.process` commits the swallow on its own thread, from
  /// `config.watchedKeys`, before anything knows what the press would act on.
  /// That config refreshes AFTER `await model.refresh()`, so for the length of a
  /// refresh (a dock cycle, a replug) keys are swallowed against the old config
  /// while `model.displays` is already empty and the key is simply dead.
  /// Stepping the built-in is the last resort against that, and all three
  /// bottom-out routes meet here so no site can go dead on its own.
  ///
  /// Deliberately NOT pushed into `stepBrightness`'s loop body: the
  /// keyboard-disable rule holds that a resolved-but-keyboard-disabled display
  /// SWALLOWS its press, and this must fire only where nothing resolved at all.
  ///
  /// A machine with no built-in and no controlled external is still dead here.
  /// Only tap-side pass-through reaches that, and the tap was left alone: an
  /// active head-insert tap froze the machine twice.
  private func stepEveryControlledDisplay(isUp: Bool, isFine: Bool) {
    let stepped = model.stepBrightnessAllExternal(isUp: isUp, isFine: isFine)
    showBrightnessHUDs(for: stepped)
    guard stepped.isEmpty,
          let builtInStep = model.stepBrightnessBuiltIn(isUp: isUp, isFine: isFine)
    else { return }
    showBrightnessHUDs(for: [builtInStep])
  }

  /// Volume-key targets: the candidates below, filtered by the capabilities probe's verdict on
  /// VCP 0x62. A panel that denies the register takes no volume key, the same
  /// way its slider takes no drag.
  private func resolveVolumeTargets() -> [AppModel.DisplayState] {
    model.volumeKeyEnabledStates(volumeKeyCandidates())
  }

  /// Mute-key targets: the same candidates, filtered against the register the
  /// mute key actually WRITES. That is VCP 0x8D under the dedicated-command
  /// strategy, so a mute-capable panel that denies volume keeps its mute key.
  private func resolveMuteTargets() -> [AppModel.DisplayState] {
    model.muteKeyEnabledStates(volumeKeyCandidates())
  }

  /// Volume/mute candidate set per multiKeyboardVolume, before any
  /// per-display filter.
  ///
  /// The fallbacks live HERE and the filters at the two call sites above, which
  /// is the keyboard-disable ordering: a display that resolves and then refuses swallows the
  /// press, only one that never resolved reaches a fallback. Folding a filter in
  /// here would hand a refusing display's keypress to every other panel.
  private func volumeKeyCandidates() -> [AppModel.DisplayState] {
    switch model.volumeMode {
    case .allScreens:
      return model.displays
    case .audioDeviceNameMatching:
      // Zero matches never falls back (fork parity). Either the tap released
      // the keys to macOS, or the keys stay watched with a nil default output
      // (indistinguishable from "not yet routed") and the press is swallowed.
      return model.audioMatchingDisplays()
    case .mouse:
      let resolved = keyTargets().compactMap { id in model.displays.first { $0.id == id } }
      // DIVERGENCE from the fork (planner flag 6, endorsed): the fork
      // SWALLOWS the press when the pointer resolves no external, its tap
      // having already eaten the event with no fallback. Candela extends its
      // own brightness rule: losing the targeting beats losing the keypress.
      return resolved.isEmpty ? model.displays : resolved
    }
  }

  private func showVolumeHUDs(_ stepped: [(state: AppModel.DisplayState, value: Double)]) {
    // Fork hideOsd parity: the pref gates VOLUME/MUTE pills only, never
    // brightness or contrast, and the write itself still lands.
    //
    // Filtered BEFORE grouping so it stays per display: a suppressed display
    // shows no pill and is not counted among the others sharing one.
    showStateHUDs(
      stepped.filter { !DisplayPrefs(persistenceKey: $0.state.display.persistenceKey).hideOsd },
      position: appPrefs.hudPositionVolume
    ) { $0.volume.isMuted ? .volumeMuted : .volume }
  }

  /// ONE pill per placement display, not one per stepped display.
  ///
  /// Every member of a mirror set draws on the master and `BrightnessHUD` keys
  /// its windows by that ID, so announcing members one at a time wrote the same
  /// window repeatedly and the last write won. `HUDGrouping` decides which
  /// display each pill reports; its count keeps a pill from implying the members
  /// it cannot name stood still.
  ///
  /// The HDR marker follows the badge's LIVENESS predicate
  /// (`isHDREngaged`), not the policy (`hdrMode`). One predicate, both surfaces.
  ///
  /// Placement resolves HERE, not inside the island, which holds no judgement:
  /// a mirrored panel is absent from `NSScreen.screens`, so an
  /// unresolved ID makes the island show nothing at all, silently, while the DDC
  /// write lands and the panel visibly changes.
  ///
  /// ONE topology sample serves the whole announcement, so one keypress's pills
  /// cannot disagree about the rig. A sample that lags a mirror BREAKING puts
  /// the pill on the ex-master until the next screen-parameters notification,
  /// which is the cheapest place in the app to pay for the store's
  /// one-directional guarantee.
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

  /// The volume/contrast half of the same rule. These pills carry no HDR marker
  /// (it reports a brightness-path fact), so only the set count reaches the
  /// suffix.
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

  /// Re-read at every announcement, never cached: the indicator position and
  /// style fan out to `.refreshUI` alone, so a pill drawn after either
  /// picker moves has to pick the new value up here.
  private var appPrefs: DisplayPrefs { DisplayPrefs(persistenceKey: "app") }

  /// What the HUD calls a display. Step paths carry the RAW hardware name, so
  /// the user's rename is applied here, through `DisplayOrdering.title` so the
  /// pill and the panel never name one display two ways.
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
  /// false)`). Nil when no screen holds the pointer, or that screen carries no
  /// `NSScreenNumber`.
  private static func pointerDisplayID() -> CGDirectDisplayID? {
    let location = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) else {
      return nil
    }
    return screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }

  /// THE resolution every pointer-targeted key path shares: which displays a
  /// press acts on. `anchoredOn` is the focused-window display when that
  /// preference is on and a window resolved; nil asks the pointer, which is both
  /// the default and the focus mode's fallback. Empty when nothing resolves, and
  /// each caller answers that case differently.
  ///
  /// The anchor is expanded rather than used directly, and the expansion is
  /// where a synthesized size is answered. While one is engaged the
  /// physical panel has NO `NSScreen` and no entry in the active display list,
  /// so the pointer and `FocusedDisplay` both answer with the virtual display:
  /// the panel being pointed at is unreachable from AppKit geometry.
  /// `MirrorTopology.expand` reads the engine's pairing table before anything
  /// CoreGraphics reports and hands back BOTH ends, the only route to the
  /// panel's controller and the DDC bus the step is written over. The virtual
  /// display carries no controller, so callers drop it by failing to resolve it.
  ///
  /// The same call covers an ordinary mirror set (fork: the expansion inside
  /// `getAffectedDisplays`): the set shows one picture, so stepping only the
  /// master would leave it visibly mismatched. A display in no set expands to
  /// itself.
  ///
  /// Reads ONE sample from the topology store rather than re-querying
  /// CoreGraphics per call site, and that store is where the synthesis
  /// pairing is stamped, so topology and pairing cannot come from two instants.
  ///
  /// These are STEP targets, so they stay RAW: no master is ever SUBSTITUTED
  /// for the panel the user asked for. It remains UNVERIFIED whether a
  /// slave's DDC is suppressed, and dropping the panel as unavailable would put
  /// VCP 0x8D out of reach and strand a hardware-muted display with no way
  /// back.
  private func keyTargets(anchoredOn anchor: CGDirectDisplayID? = nil) -> [CGDirectDisplayID] {
    guard let target = anchor ?? Self.pointerDisplayID() else { return [] }
    return model.mirrorTopology.topology().expand(target)
  }

}
