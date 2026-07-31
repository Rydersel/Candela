import CandelaKit
import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
final class AppModel {
  struct DisplayState: Identifiable {
    let display: ExternalDisplay
    let controller: BrightnessController
    let volume: DDCValueController
    let contrast: DDCValueController
    var id: CGDirectDisplayID { display.id }
  }

  private(set) var displays: [DisplayState] = []

  /// The built-in panel, in its own slot — deliberately NOT inside `displays`
  /// (re-review T10-A): `stepBrightnessAllExternal`, `tapConfig`, and the
  /// panel's external iteration all walk `displays` and must stay
  /// external-only — those three are about *externals* specifically (Shift-Cmd
  /// "all external" steps, the fork's disengage rule, the external display
  /// list), not about sparing the MacBook panel. A plain brightness press does
  /// step the built-in when the pointer is on it (fork parity, `.affected`);
  /// it reaches it through `stepBrightness(displayIDs:)`, which resolves both
  /// slots. `DisplayState.display` reuses `ExternalDisplay` as a plain
  /// id/name/persistenceKey value carrier despite the name — renaming the
  /// struct is M4 cleanup.
  private(set) var builtIn: DisplayState?

  /// Epoch authority for reconfiguration/sleep/wake. Owned here so refresh
  /// can wire every controller's epoch pair; StatusItemController activates
  /// it and consumes its topology stream.
  let displayManager = DisplayManager()

  /// One HDR service shared by every display's controller (MPDisplayMgr
  /// enumeration + its 2 s state cache live behind one actor).
  let hdrToggling: any HDRToggling

  /// Default-output questions + change signal (D4). Injected so a future app
  /// test target can fake it; production uses CoreAudio.
  let audioDevices: any AudioDeviceProviding

  /// App-level M4 prefs (startupAction, multiKeyboardVolume, showContrast)
  /// read through one DisplayPrefs like the engine does; the persistence key
  /// is irrelevant for unsuffixed accessors.
  @ObservationIgnored private let appPrefs = DisplayPrefs(persistenceKey: "app")

  var volumeMode: MultiKeyboardVolume { appPrefs.multiKeyboardVolume }

  /// Bumped by the propagation seam on any pref write that a view renders.
  /// The panel and every settings pane reference it in `body` so external
  /// writes (drag-remove, another pane, `defaults write` + reset) re-render
  /// them. `DisplayPrefs` is plain UserDefaults and not observable, so this is
  /// the ONLY invalidation signal the settings UI has.
  private(set) var prefsRevision = 0

  func notePrefsChanged() {
    prefsRevision &+= 1
  }

  /// Software-dimming islands (AppKit lives in the app target behind
  /// CandelaKit protocols). Constructed by StatusItemController and injected
  /// here — implementer's choice per the Task 6 brief, so tests can hand the
  /// model fakes (or nil for "feature degraded").
  @ObservationIgnored private let shade: (any ShadeRendering)?
  @ObservationIgnored private let gamma: (any GammaApplying)?

  /// Accessibility grant state, owned here so the panel banner observes it
  /// through the model already in the SwiftUI environment (and clears live
  /// when the grant appears while the panel is open).
  let accessibility = AccessibilityPermission()

  var accessibilityGranted: Bool { accessibility.isGranted }

  init(
    shade: (any ShadeRendering)? = nil,
    gamma: (any GammaApplying)? = nil,
    hdrToggling: (any HDRToggling)? = nil,
    audioDevices: (any AudioDeviceProviding)? = nil
  ) {
    self.shade = shade
    self.gamma = gamma
    self.hdrToggling = hdrToggling ?? MonitorPanelService()
    self.audioDevices = audioDevices ?? CoreAudioDeviceProvider()
  }

  /// Every controlled display, built-in first (its `isNativeActive()` is
  /// constitutively true for role .builtIn, so CC-sync polls the MacBook
  /// panel from the very first tick). Computed, never stored (backlog #6):
  /// callers must read the display set at call time — a refresh between
  /// poller ticks must not replicate onto a departed controller.
  var allControlledStates: [DisplayState] {
    (builtIn.map { [$0] } ?? []) + displays
  }

  /// Fork `!display.isDisabled` (per-display "disable keyboard control",
  /// review R1): every key loop skips a disabled display's BODY, but the tap
  /// still swallows the event — fork parity; spec Appendix A's pass-through
  /// parenthetical is wrong about the fork. Read live per call.
  func keyEnabledStates(_ states: [DisplayState]) -> [DisplayState] {
    states.filter { !DisplayPrefs(persistenceKey: $0.display.persistenceKey).isDisabled }
  }

  func stepBrightnessAllExternal(isUp: Bool, isFine: Bool, isFresh: Bool) -> [(id: CGDirectDisplayID, name: String, newValue: Double)] {
    keyEnabledStates(displays).map { state in
      (state.id, state.display.name, state.controller.step(isUp: isUp, isFine: isFine, isFresh: isFresh))
    }
  }

  /// Steps the given displays, resolving each ID against either slot (an
  /// external, or the built-in in its own slot). Backs the `.affected` scope —
  /// the display the user is working on plus, when it drives a mirror set, the
  /// set's members (the executor does that expansion). IDs we don't control are
  /// skipped, so the result may be shorter than the input (empty when none
  /// resolve).
  ///
  /// Resolving-by-pointer is the fork's default; picking the *focused* display
  /// instead (fork `useFocusInsteadOfMouse`) is an M5 preference, and lands in
  /// the executor's resolution step, not here.
  func stepBrightness(displayIDs: [CGDirectDisplayID], isUp: Bool, isFine: Bool, isFresh: Bool) -> [(id: CGDirectDisplayID, name: String, newValue: Double)] {
    displayIDs.compactMap { displayID in
      let slot = displays.first { $0.id == displayID } ?? builtIn.flatMap { $0.id == displayID ? $0 : nil }
      // isDisabled filters the loop body (R1): a resolved-but-disabled
      // display steps nothing and shows no HUD; the executor's empty-result
      // fallback path itself re-runs through keyEnabledStates.
      guard let slot, !keyEnabledStates([slot]).isEmpty else { return nil }
      return (slot.id, slot.display.name,
              slot.controller.step(isUp: isUp, isFine: isFine, isFresh: isFresh))
    }
  }

  /// Steps the built-in panel (Ctrl-directed keys only — plain presses target
  /// the pointer's display, which may well be the built-in). Returns nil when
  /// no built-in display is online.
  func stepBrightnessBuiltIn(isUp: Bool, isFine: Bool, isFresh: Bool) -> (id: CGDirectDisplayID, name: String, newValue: Double)? {
    guard let builtIn, !keyEnabledStates([builtIn]).isEmpty else { return nil }
    return (builtIn.id, builtIn.display.name,
            builtIn.controller.step(isUp: isUp, isFine: isFine, isFresh: isFresh))
  }

  /// Watch brightness keys only when an EXTERNAL display is present (fork:
  /// updateMediaKeyTap's disengage rule). Volume/mute keys additionally obey
  /// the audio-routing rule: released to the system whenever the default
  /// output can set its own volume (or name-matching finds no display).
  var tapConfig: MediaKeyEventTap.WatchConfig {
    var watched: Set<MediaKey> = displays.isEmpty ? [] : [.brightnessUp, .brightnessDown]
    // One snapshot of the default output for both consumers: read twice, a
    // device change landing between them could arm the tap on an inconsistent
    // pair (match count from one device, routing verdict from another).
    let device = audioDevices.defaultOutputDevice()
    if AudioRoutingPolicy.shouldWatchVolumeKeys(
      mode: volumeMode,
      // Fork getDdcCapableDisplays (= !isSw(), review R5): forceSoftware
      // displays don't count — a rig whose only external is forceSoftware
      // releases the volume keys to macOS.
      ddcDisplaysExist: !ddcCapableStates().isEmpty,
      matchingDisplayCount: audioMatchingDisplays(for: device).count,
      defaultOutput: device
    ) {
      watched.formUnion([.volumeUp, .volumeDown, .mute])
    }
    return .init(
      watchedKeys: watched,
      interceptAlternateBrightnessKeys: appPrefs.interceptAlternateBrightnessKeys
    )
  }

  /// Fork getDdcCapableDisplays (= !isSw(), review R5): the audio/tap pool
  /// excludes forceSoftware displays — the pref exists because the display's
  /// DDC wire is broken. Brightness keys are NOT gated on this (their
  /// software leg still works on a forceSoftware display).
  private func ddcCapableStates() -> [DisplayState] {
    displays.filter { !DisplayPrefs(persistenceKey: $0.display.persistenceKey).forceSoftware }
  }

  /// Displays whose (override or raw) name matches the default output device.
  /// Recomputed at every call — key time, not tap-arm time — which fixes the
  /// fork's stale audioControlTargetDisplays cache (D4). Pool = DDC-capable
  /// only (fork getDdcCapableDisplays, R5).
  func audioMatchingDisplays() -> [DisplayState] {
    audioMatchingDisplays(for: audioDevices.defaultOutputDevice())
  }

  /// Whether this display can play sound at all: it enumerates as a CoreAudio
  /// output device (EDID-declared audio sink), unless `audioSinkOverride` says
  /// otherwise. False greys out the panel's volume slider — the row stays
  /// visible, because "this display has no audio" is information, whereas
  /// `hideVolumeSlider` is the user saying they never want to see it.
  ///
  /// PANEL ONLY. The volume keys never consult this: their targets come from
  /// `resolveVolumeTargets`, and a display whose speakers CoreAudio cannot see
  /// still takes DDC volume writes. A wrong verdict here costs a slider, never
  /// the keys.
  ///
  /// Reads the provider's change-refreshed name snapshot, so this stays a
  /// cheap MainActor call (no HAL round-trip on menu open).
  func hasAudioOutput(_ state: DisplayState) -> Bool {
    let prefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)
    switch prefs.audioSinkOverride {
    case .forceNone: return false
    case .forcePresent: return true
    case .auto:
      return AudioRoutingPolicy.displayHasAudioSink(
        rawDisplayName: state.display.name,
        nameOverride: prefs.audioDeviceNameOverride,
        outputDeviceNames: audioDevices.outputDeviceNames()
      )
    }
  }

  /// Same rule against a caller-supplied device snapshot — lets `tapConfig`
  /// evaluate the match count and the routing verdict against one and the
  /// same default output.
  private func audioMatchingDisplays(for device: AudioOutputDevice?) -> [DisplayState] {
    guard let device else { return [] }
    return ddcCapableStates().filter { state in
      AudioRoutingPolicy.displayMatchesDevice(
        deviceName: device.name,
        rawDisplayName: state.display.name,
        nameOverride: DisplayPrefs(persistenceKey: state.display.persistenceKey).audioDeviceNameOverride
      )
    }
  }

  /// True when any of the IDs is a display we control (either slot),
  /// regardless of isDisabled. The executor's brightness fallback-to-all
  /// consults this: a resolved-but-keyboard-disabled display is NOT a
  /// targeting failure — the fork skips it in the loop body and swallows the
  /// press (R1), so the fallback must not fire for it.
  func controlsAnyDisplay(in displayIDs: [CGDirectDisplayID]) -> Bool {
    displayIDs.contains { id in
      displays.contains { $0.id == id } || builtIn?.id == id
    }
  }

  /// One D5 write-restore pass: every duplicate memo reset FIRST, then
  /// re-write — brightness DDC leg, contrast, volume (+ the mute companion
  /// inside restoreToHardware). ALL THREE legs restore only ever-touched
  /// commands (D5's "stored (= ever-touched)"; fork isTouched — planner
  /// flag 4 OVERTURNED, review R4): a fresh display publishes the ASSUMED
  /// default (brightness 1.0) over an empty store, and writing that would
  /// blast an OLED to 100% at first restore. Volume/contrast carry their own
  /// gate inside restoreToHardware; brightness checks `hasStoredValue`
  /// (never reach into the store from here).
  func performRestorePass() {
    for state in displays {
      if state.controller.hasStoredValue {
        state.controller.resetWriteMemo()
        state.controller.reassertHardware()
      }
      state.contrast.resetWriteMemo()
      state.contrast.restoreToHardware()
      state.volume.resetWriteMemo()
      state.volume.restoreToHardware()
    }
  }

  /// The in-flight refresh, if any. Overlapping callers piggyback on it
  /// instead of starting a second pass: each pass runs discovery, and two
  /// concurrent passes would each hold a *different* DDC-service actor for
  /// the same IOAVService, letting their I2C transactions interleave on the
  /// wire (e.g. a discarded coalescer's tail-write racing a fresh read).
  @ObservationIgnored private var refreshTask: Task<[CGDirectDisplayID], Never>?

  /// The CC-sync poll job. Cancelled and recreated after every refresh: its
  /// targets capture a fixed controller set, so a departed display's target
  /// must never outlive the pass that dropped it.
  @ObservationIgnored private var pollerTask: Task<Void, Never>?

  deinit {
    pollerTask?.cancel()
  }

  /// Returns the IDs of displays that departed in this pass (for HUD panel
  /// cleanup). A piggybacked caller — one that joined an already-running
  /// pass — gets `[]`, not that pass's result: only the caller that started
  /// the pass sees its departures. `@discardableResult` keeps the two bare
  /// launch/menu-close call sites warning-free.
  @discardableResult
  func refresh() async -> [CGDirectDisplayID] {
    if let refreshTask {
      _ = await refreshTask.value
      return []
    }
    let task = Task { await performRefresh() }
    refreshTask = task
    let departed = await task.value
    refreshTask = nil
    return departed
  }

  /// Reconciles `displays` against discovery, keyed by `CGDirectDisplayID`:
  /// still-present displays keep their existing `BrightnessController` (and
  /// its writer/coalescer), so controller identity is stable across refreshes
  /// and long-lived references (Milestone 2 media keys) never go stale —
  /// but they are rebound to the writer discovery just created (a replug can
  /// hand out a fresh IOAVService; keeping the old one risks writing into a
  /// stale service, and rebind also resets the coalescer's duplicate memo,
  /// review I10). Only newly appeared displays get a fresh controller.
  /// Departed displays are dropped and their IDs returned — the controller's
  /// deinit finishes its coalescer, which lands any pending write before the
  /// drain task exits, so no explicit `waitForPendingWrites()` is needed.
  private func performRefresh() async -> [CGDirectDisplayID] {
    var existing = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
    var appeared: [DisplayState] = []
    var kept: [DisplayState] = []
    displays = DisplayDiscovery.discover().map { entry in
      if let previous = existing.removeValue(forKey: entry.display.id) {
        // Fresh DisplayState (name may change), reused controllers, fresh
        // writer for all three (rebind also resets each duplicate memo).
        previous.controller.rebind(writer: entry.writer)
        previous.volume.rebind(writer: entry.writer)
        previous.contrast.rebind(writer: entry.writer)
        let state = DisplayState(
          display: entry.display, controller: previous.controller,
          volume: previous.volume, contrast: previous.contrast
        )
        kept.append(state)
        return state
      }
      let persistenceKey = entry.display.persistenceKey
      let prefs = DisplayPrefs(persistenceKey: persistenceKey)
      let controller = BrightnessController(
        writer: entry.writer,
        backends: BrightnessBackends(
          // T3 handoff: the applier's closure runs inside the coalescer's
          // single drain, which already serializes per display — pass the
          // shim directly, no extra queue.
          applierNative: NativeBrightnessApplier(
            displayID: entry.display.id, apply: DisplayServices.setBrightness
          ),
          hdr: hdrToggling,
          shade: shade,
          gamma: gamma
        ),
        prefs: prefs,
        displayID: entry.display.id,
        store: UserDefaultsBrightnessStore(),
        // M3 key; the M2 key is read once for migration, then ignored.
        storageKey: "combinedBrightness.\(persistenceKey)",
        legacyKey: "brightness.\(persistenceKey)"
      )
      let volume = DDCValueController(
        writer: entry.writer, command: .volume, prefs: prefs,
        displayID: entry.display.id,
        store: UserDefaultsBrightnessStore(), storageKey: "volume.\(persistenceKey)"
      )
      let contrast = DDCValueController(
        writer: entry.writer, command: .contrast, prefs: prefs,
        displayID: entry.display.id,
        store: UserDefaultsBrightnessStore(), storageKey: "contrast.\(persistenceKey)"
      )
      let state = DisplayState(
        display: entry.display, controller: controller, volume: volume, contrast: contrast
      )
      appeared.append(state)
      return state
    }
    refreshBuiltIn()
    // Every controller — kept and appeared — gets the live epoch pair, so
    // each submit is stamped with the current epoch and the drain refuses
    // targets stamped before a reconfiguration/sleep.
    for state in displays {
      state.controller.setEpochProvider(
        { [displayManager] in displayManager.currentEpoch() },
        isCurrent: { [displayManager] in displayManager.isEpochCurrent($0) }
      )
      state.volume.setEpochProvider(
        { [displayManager] in displayManager.currentEpoch() },
        isCurrent: { [displayManager] in displayManager.isEpochCurrent($0) }
      )
      state.contrast.setEpochProvider(
        { [displayManager] in displayManager.currentEpoch() },
        isCurrent: { [displayManager] in displayManager.isEpochCurrent($0) }
      )
    }
    builtIn?.controller.setEpochProvider(
      { [displayManager] in displayManager.currentEpoch() },
      isCurrent: { [displayManager] in displayManager.isEpochCurrent($0) }
    )
    for state in appeared {
      await state.controller.refreshFromHardware()
      await state.volume.refreshFromHardware() // no-op unless startupAction == .read (validated)
      await state.contrast.refreshFromHardware()
    }
    for state in kept {
      // Let any coalesced tail-write land before reading back, then resync
      // from hardware. Harmless no-op on write-only panels (MAG341C): the
      // read fails its guard and the last-written state stands.
      await state.controller.waitForPendingWrites()
      await state.controller.refreshFromHardware()
      // Kept displays re-read volume/contrast too (spec-coverage F2 — the
      // fork re-reads every command on every display rebuild); both are
      // gated no-ops unless startupAction == .read. Same drain-before-read
      // shape as the brightness leg above — a queued coalescer write must not
      // land after the read has already adopted the pre-write hardware value.
      await state.volume.waitForPendingWrites()
      await state.volume.refreshFromHardware()
      await state.contrast.waitForPendingWrites()
      await state.contrast.refreshFromHardware()
    }
    // Resync the built-in from its native read (cheap; a freshly created
    // controller already seeded from the same read at init).
    await builtIn?.controller.refreshFromHardware()
    restartPoller()
    return Array(existing.keys)
  }

  /// Reconciles the built-in slot against discovery. Same identity rule as
  /// externals: a still-present built-in keeps its controller (fresh
  /// DisplayState for the name); no writer rebind — there is no DDC wire, the
  /// writer is a permanent `NoopDDCWriter`.
  private func refreshBuiltIn() {
    guard let found = BuiltInDisplayDiscovery.discover() else {
      builtIn = nil
      return
    }
    let display = ExternalDisplay(id: found.id, name: found.name, persistenceKey: "builtIn")
    if let existing = builtIn, existing.id == found.id {
      builtIn = DisplayState(
        display: display, controller: existing.controller,
        volume: existing.volume, contrast: existing.contrast
      )
      return
    }
    let controller = BrightnessController(
      writer: NoopDDCWriter(), // no DDC wire; always-fails stub (re-review T10-D)
      backends: BrightnessBackends(
        applierNative: NativeBrightnessApplier(
          displayID: found.id, apply: DisplayServices.setBrightness
        ),
        // No HDR/shade/gamma backends: role .builtIn never routes HDR or the
        // software leg, and `handleReconfigure` correctly no-ops on nils.
        hdr: nil,
        shade: nil,
        gamma: nil,
        readNative: DisplayServices.getBrightness(for:)
      ),
      prefs: DisplayPrefs(persistenceKey: "builtIn"), // role .builtIn ignores prefs
      displayID: found.id,
      role: .builtIn
      // store/storageKey/legacyKey stay nil (re-review T10-E): macOS owns
      // built-in brightness across launches; the controller seeds from a
      // native read at init.
    )
    // Inert value controllers: the built-in has no DDC wire, so their
    // `isAvailable` stays true but every write no-ops on `NoopDDCWriter`.
    // Nothing renders them — the panel shows volume/contrast for `displays`
    // only — they exist so `DisplayState` has one shape for both slots.
    builtIn = DisplayState(
      display: display, controller: controller,
      volume: DDCValueController(
        writer: NoopDDCWriter(), command: .volume,
        prefs: DisplayPrefs(persistenceKey: "builtIn"), displayID: found.id
      ),
      contrast: DDCValueController(
        writer: NoopDDCWriter(), command: .contrast,
        prefs: DisplayPrefs(persistenceKey: "builtIn"), displayID: found.id
      )
    )
  }

  /// Rebuilds the native-brightness poll job for the current display set
  /// (spec §5 CC-sync: Control Center and ambient changes bypass us entirely,
  /// so the only way to stay in sync on the native path is to look).
  private func restartPoller() {
    pollerTask?.cancel()
    guard !displays.isEmpty || builtIn != nil else {
      pollerTask = nil
      return
    }
    let states = allControlledStates
    let targets = states.map { state -> BrightnessPoller.Target in
      let controller = state.controller
      return BrightnessPoller.Target(
        displayID: state.id,
        expected: { controller.expectedNative() },
        isNativeActive: { controller.isNativeActive() },
        // A starved adoption Task that fires late is discarded by
        // adoptExternal's generation check (review I9).
        // Parked T6-minor-2: after an HDR settle the expected-native slot and
        // the hardware can briefly disagree. The poller does NOT recover the
        // interim input — it CONVERGES PUBLISHED STATE ONTO THE RE-ASSERTED
        // value, i.e. anything the user typed inside the settle window is
        // ratified over, not restored. Confirm against hardware verification
        // item 7 before deciding whether that is acceptable.
        adopt: { [weak self] value, generation in
          Task { @MainActor in
            let delta = controller.adoptExternal(value, generation: generation)
            guard let self else { return }
            // Display set read at fan-out time, not at target-build time: a
            // refresh between ticks must not replicate onto a departed
            // controller — which is why `allControlledStates` is computed.
            // The built-in is in the list (its own slot, outside `displays`,
            // re-review T10-A); it moves from last to first, behaviorally
            // irrelevant (`task-11-report.md:49`).
            BrightnessSync.fanOut(
              delta: delta,
              from: controller,
              to: self.allControlledStates.map(\.controller),
              isEnabled: self.appPrefs.enableBrightnessSync
            )
          }
        },
        isConverging: { controller.isConvergingFromExternal() }
      )
    }
    let poller = BrightnessPoller(
      targets: targets,
      read: { id in DisplayServices.getBrightness(for: id).map(Double.init) },
      // Current-epoch-against-itself is false exactly while the manager is
      // suspended (mid-reconfigure burst or asleep) — the poller's skip rule.
      isEpochCurrent: { [displayManager] in
        displayManager.isEpochCurrent(displayManager.currentEpoch())
      }
    )
    pollerTask = Task { await poller.run() }
  }
}
