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
    /// This display's live DDC wire, kept beside the controllers so an
    /// off-path transaction (the D24 capabilities probe) can reach it without
    /// re-running discovery. Replaced on every refresh — a replug hands out a
    /// fresh IOAVService and the old one must never be written to.
    let writer: any DDCWriting
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

  /// Display-mode enumeration, the preview countdown and stored-mode writes.
  /// Owned here rather than by a view because the countdown must outlive
  /// whatever window started it, and because the settings pane and the panel
  /// have to drive the same session.
  let displayModes = DisplayModeCoordinator()

  /// THE topology sample every part of the app resolves through (DT15). Handed
  /// to every `BrightnessController` so the shade and the gamma activity
  /// enforcer get an ID that is already guaranteed drawable; every reader gets
  /// a value, never a query.
  ///
  /// Its ONE writer is `MirrorTopologySampler`, which `StatusItemController`
  /// starts at launch and which then follows every screen-parameters change.
  /// Before it starts — and if `CGGetOnlineDisplayList` ever fails — this holds
  /// the empty topology, whose resolution is the identity function, i.e. exactly
  /// the behaviour that predates this seam. It degrades to the status quo, never
  /// to a guess.
  let mirrorTopology = MirrorTopologyStore()

  /// The mirror toggle, the mirror preview countdown and the published
  /// topology. Replaces the transplanted `Mirroring.engageMirror`, which the
  /// Cmd+BrightnessDown hotkey used to call directly.
  ///
  /// Lazily constructed because it names two stored properties declared above
  /// it. `@ObservationIgnored` because the Observation macro cannot wrap a
  /// `lazy var` — views observe the coordinator's own properties, not this
  /// reference.
  @ObservationIgnored private(set) lazy var mirroring = MirroringCoordinator(
    store: mirrorTopology, modes: displayModes
  )

  /// Rotation requests and the rotation countdown. Owned here for
  /// `displayModes`' reason — the countdown must outlive whatever window started
  /// it. Unlike the other two it persists nothing: a rotation is already system
  /// state the instant it applies (RT2).
  let rotation = RotationCoordinator()

  /// App-level M4 prefs (startupAction, multiKeyboardVolume, showContrast)
  /// read through one DisplayPrefs like the engine does; the persistence key
  /// is irrelevant for unsuffixed accessors. Assigned in `init` rather than
  /// inline: it needs the safe-mode flag, which arrives as an init parameter.
  @ObservationIgnored private let appPrefs: DisplayPrefs

  /// D24: per-display VCP 0x62 verdict from the capabilities string. Observable,
  /// so the panel's volume slider enables/disables live the moment a probe
  /// lands. An ABSENT entry means "not probed yet, or the probe was skipped" and
  /// reads as `.unknown` — the panel is fully usable before any DDC happens. A
  /// STORED `.unknown` means the probe ran and failed, and is cached for the
  /// session so a write-only panel (the MAG 341C) is not re-probed on every
  /// menu close.
  private(set) var volumeSupport: [String: VCPSupport] = [:]

  /// The raw MCCS capability string, keyed by persistence key, stored ONLY on
  /// a successful read (B2).
  ///
  /// Absence means "not probed, or the display did not answer" — which
  /// `volumeSupport` already distinguishes: an entry stored as `.unknown`
  /// there is "the probe ran and failed". A `[String: String?]` would encode
  /// the same two states twice, in a shape nobody reads correctly.
  ///
  /// The string was on the wire, was reassembled by a fragment loop that
  /// deliberately refuses to return a truncated result, was mapped to ONE bit
  /// for ONE VCP code, and then fell out of scope. `candela-probe caps` has
  /// printed it all along; the app did not.
  private(set) var capabilityString: [String: String] = [:]

  /// IOKit facts read on every discovery pass and, until now, discarded (B8).
  /// Keyed by persistence key so it survives a replug, and evicted through the
  /// same `performRefresh` line as `volumeSupport`.
  ///
  /// External displays only — the built-in slot never passes through
  /// `DisplayDiscovery`, so its entry is permanently absent. That is not a gap
  /// to paper over: the rows this feeds are rows about a data cable, and the
  /// built-in has none, so its pane omits them rather than reporting them
  /// unenumerated.
  private(set) var hardwareFacts: [String: DisplayHardwareFacts] = [:]

  /// The `WatchConfig` most recently ARMED, not the one most recently computed
  /// (B9). Those differ exactly when a rearm failed — which is the case the row
  /// exists for. Recorded at the arm site in `StatusItemController`, never at
  /// the compute site here.
  private(set) var lastArmedTapConfig: MediaKeyEventTap.WatchConfig?

  func noteTapArmed(_ config: MediaKeyEventTap.WatchConfig) {
    lastArmedTapConfig = config
  }

  /// The gamma-interference monitor, injected by `StatusItemController` after
  /// construction (it owns the AppKit alert island the monitor needs). Read
  /// ONLY for reporting — nothing here drives it.
  @ObservationIgnored var gammaInterference: GammaInterferenceMonitor?

  @ObservationIgnored private var capabilityProbesInFlight: Set<String> = []

  /// D11: session-only hardware gate, injected once and never re-read from
  /// UserDefaults. Also gates the brightness readback below, which the
  /// `startupAction` getter override cannot reach (`BrightnessController`'s
  /// `refreshFromHardware` carries no `startupAction` guard, unlike its
  /// `DDCValueController` sibling).
  @ObservationIgnored private let safeMode: Bool

  /// The same flag, readable by the settings UI. Safe mode is a *session*
  /// state that silently changes what the Startup picker means, and a pane
  /// that cannot see it shows the user their persisted choice while nothing is
  /// being restored — a control describing behavior that is not happening,
  /// which is the defect class D11 exists to prevent. Constant for the
  /// session, so it is deliberately not observable.
  var isSafeMode: Bool { safeMode }

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

  init(
    shade: (any ShadeRendering)? = nil,
    gamma: (any GammaApplying)? = nil,
    hdrToggling: (any HDRToggling)? = nil,
    audioDevices: (any AudioDeviceProviding)? = nil,
    safeMode: Bool = false
  ) {
    self.shade = shade
    self.gamma = gamma
    self.hdrToggling = hdrToggling ?? MonitorPanelService()
    self.audioDevices = audioDevices ?? CoreAudioDeviceProvider()
    self.safeMode = safeMode
    appPrefs = DisplayPrefs(persistenceKey: "app", safeMode: safeMode)
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
  ///
  /// The key modes are the outer gate: `.custom`/`.disabled` release that
  /// family's keys to macOS entirely (Candela improves on the fork, whose tap
  /// keeps swallowing them). Six prefs feed this — the four verified in D32
  /// plus `keyboardBrightness`/`keyboardVolume` — and every one has a
  /// `.rearmTap` row, so a mode change re-arms.
  var tapConfig: MediaKeyEventTap.WatchConfig {
    var watched: Set<MediaKey> = []
    if KeyModePolicy.watchesMediaKeys(appPrefs.keyboardBrightness), !displays.isEmpty {
      watched = [.brightnessUp, .brightnessDown]
    }
    // One snapshot of the default output for both consumers: read twice, a
    // device change landing between them could arm the tap on an inconsistent
    // pair (match count from one device, routing verdict from another).
    let device = audioDevices.defaultOutputDevice()
    if KeyModePolicy.watchesMediaKeys(appPrefs.keyboardVolume),
       AudioRoutingPolicy.shouldWatchVolumeKeys(
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

  /// Whether the panel's volume slider accepts input for this display (D24).
  ///
  /// REPLACES the CoreAudio name-match gate shipped in 7b5be00 / 1f117b3, which
  /// made absence of evidence sufficient to disable a working control — and was
  /// wrong in both directions (a panel can declare audio in its EDID with
  /// nothing to play it through; a panel with working speakers is invisible to
  /// CoreAudio when the Mac's link carries no audio). The signal is now the
  /// monitor's own capabilities string. `AudioRoutingPolicy.displayHasAudioSink`
  /// is untouched and retained under test, with no production caller in v1.
  func volumeSliderEnabled(_ state: DisplayState) -> Bool {
    VolumeSliderPolicy.isEnabled(
      override: DisplayPrefs(persistenceKey: state.display.persistenceKey).audioSinkOverride,
      volumeSupport: volumeSupport[state.display.persistenceKey] ?? .unknown
    )
  }

  /// Starts a capabilities probe for every display `CapabilityProbePolicy` says
  /// is eligible.
  ///
  /// Never awaited by a caller: a fragment round-trip is ~80 ms and a wedged bus
  /// costs ~0.5 s per fragment before it gives up, and D24 forbids the panel
  /// blocking on any of that. The cache is what keeps this from being per-open
  /// traffic — a display is probed once per session per plug.
  private func probeVolumeCapabilities() {
    for state in displays {
      let persistenceKey = state.display.persistenceKey
      // The eligibility rule lives in CandelaKit and is tested there (D21) —
      // in particular the HDR case, which SKIPS without caching, because DDC is
      // dead under HDR and a `.unknown` written now would outlive the cause.
      guard CapabilityProbePolicy.shouldProbe(
        cached: volumeSupport[persistenceKey],
        inFlight: capabilityProbesInFlight.contains(persistenceKey),
        hdrEngaged: state.controller.isHDREngaged
      ) else { continue }
      capabilityProbesInFlight.insert(persistenceKey)
      let writer = state.writer
      let manager = displayManager
      let epoch = displayManager.currentEpoch()
      Task { [weak self] in
        let capabilities = await writer.readCapabilityString()
        guard let self else { return }
        self.capabilityProbesInFlight.remove(persistenceKey)
        // A sleep or reconfiguration since the request means this answer may
        // describe a wire that no longer exists. Discard rather than cache; the
        // entry stays absent and the next pass re-probes.
        guard manager.isEpochCurrent(epoch) else { return }
        // Stored only on a SUCCESSFUL read. A nil answer leaves the entry
        // absent, and `volumeSupport`'s stored `.unknown` below is what carries
        // "the probe ran and failed" — one state, one place.
        if let capabilities { self.capabilityString[persistenceKey] = capabilities }
        self.volumeSupport[persistenceKey] = capabilities.map {
          CapabilityString.support(forVCP: VCP.audioSpeakerVolume, in: $0)
        } ?? .unknown
      }
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

  /// Identity of whatever currently occupies the single-flight slot above.
  /// `Task` is a struct, so there is no `===` to compare with; this counter is
  /// how a finished pass tells "the slot is still mine" from "someone else
  /// installed a newer pass while I was suspended".
  @ObservationIgnored private var refreshTaskGeneration: UInt64 = 0

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
    refreshTaskGeneration &+= 1
    let generation = refreshTaskGeneration
    let departed = await task.value
    // Only clear the slot if we still own it. `rebuildControllers` below may
    // have cleared it already and installed its own pass; a blind `= nil`
    // would drop that pass out of the single-flight guard and let a second
    // concurrent pass start on the same DDC services.
    if refreshTaskGeneration == generation { refreshTask = nil }
    return departed
  }

  /// D30: force fresh controllers for every display.
  ///
  /// `performRefresh` reconciles by `CGDirectDisplayID` and REUSES
  /// `previous.controller` / `previous.volume` / `previous.contrast` for a
  /// still-connected display — by design, so long-lived media-key references
  /// never go stale. That makes it the wrong tool after a settings reset:
  /// every reused controller keeps in-memory state derived from prefs that no
  /// longer exist (`hdrMode` mirror, `isMuted`, `lastAppliedSw`, and the
  /// published value it will re-`persist()` straight back into the freshly
  /// emptied domain). Emptying both slots first makes every display "appeared",
  /// so all three controllers per display are constructed from the current
  /// store.
  ///
  /// Callers must have already driven the hardware to a known state — this
  /// drops the only objects that know what that state was.
  func rebuildControllers() async {
    // Drain any pass already in flight FIRST. `performRefresh` snapshots the
    // reuse map and reassigns `displays` synchronously at its entry, before
    // its first await — so clearing the slots underneath a running pass would
    // neither rebuild its controllers (it made the reuse decision already) nor
    // survive it (its assignment landed already, leaving `displays` empty).
    // Piggybacking on it via `refresh()` has the same two problems. The loop
    // re-checks because a topology event can install a newer pass while we
    // wait; MainActor gives us no suspension between the loop exiting and
    // `refresh()` reading the slot, so the hand-off cannot be raced.
    while let inFlight = refreshTask {
      let generation = refreshTaskGeneration
      _ = await inFlight.value
      if refreshTaskGeneration == generation { refreshTask = nil }
    }
    displays = []
    builtIn = nil
    await refresh()
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
      // B8: discovery has always read these and always thrown them away. Kept
      // for BOTH branches below — a kept display re-reports its facts on every
      // pass, and a link renegotiation is exactly when the transport string can
      // change under a display we already know.
      hardwareFacts[entry.display.persistenceKey] = entry.facts
      if let previous = existing.removeValue(forKey: entry.display.id) {
        // Fresh DisplayState (name may change), reused controllers, fresh
        // writer for all three (rebind also resets each duplicate memo).
        //
        // The persistence key rides along because this branch runs on EVERY
        // pass, not only after a replug, while the identity of the panel on the
        // other end is what decides whether the controllers' read-derived facts
        // still describe anything real. macOS reassigns display IDs across a
        // replug and this reconciliation is keyed on the ID, so "same ID" is
        // NOT "same monitor"; the persistence key (EDID UUID) is the only thing
        // here that tells the two apart. See `rebind(writer:panelIdentity:)`.
        previous.controller.rebind(writer: entry.writer, panelIdentity: entry.display.persistenceKey)
        previous.volume.rebind(writer: entry.writer, panelIdentity: entry.display.persistenceKey)
        previous.contrast.rebind(writer: entry.writer, panelIdentity: entry.display.persistenceKey)
        let state = DisplayState(
          display: entry.display, controller: previous.controller,
          volume: previous.volume, contrast: previous.contrast, writer: entry.writer
        )
        kept.append(state)
        return state
      }
      let persistenceKey = entry.display.persistenceKey
      // D11: the ONE prefs object shared by this display's brightness, volume
      // and contrast controllers — so the safe-mode `startupAction` override
      // gates the volume/contrast readback (`refreshFromHardware` opens with
      // `guard prefs.startupAction == .read`) for all of them at once.
      let prefs = DisplayPrefs(persistenceKey: persistenceKey, safeMode: safeMode)
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
        legacyKey: "brightness.\(persistenceKey)",
        // Seeded here so the next pass's rebind — which happens on every
        // refresh — is not mistaken for a panel swap.
        panelIdentity: persistenceKey,
        mirrorTopology: mirrorTopology
      )
      let volume = DDCValueController(
        writer: entry.writer, command: .volume, prefs: prefs,
        displayID: entry.display.id,
        store: UserDefaultsBrightnessStore(), storageKey: "volume.\(persistenceKey)",
        panelIdentity: persistenceKey
      )
      let contrast = DDCValueController(
        writer: entry.writer, command: .contrast, prefs: prefs,
        displayID: entry.display.id,
        store: UserDefaultsBrightnessStore(), storageKey: "contrast.\(persistenceKey)",
        panelIdentity: persistenceKey
      )
      let state = DisplayState(
        display: entry.display, controller: controller, volume: volume, contrast: contrast,
        writer: entry.writer
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
      // D11: safe mode issues NO DDC reads. `BrightnessController.refreshFromHardware`
      // is ungated on `startupAction` in the engine, so the gate lands here.
      // (Gating it inside the controller on `startupAction == .read` is arguably
      // the correct engine behavior regardless — recorded as an M5 follow-up,
      // deliberately out of this task's ownership fence.)
      if !safeMode { await state.controller.refreshFromHardware() }
      await state.volume.refreshFromHardware() // no-op unless startupAction == .read (validated)
      await state.contrast.refreshFromHardware()
    }
    for state in kept {
      // Let any coalesced tail-write land before reading back, then resync
      // from hardware. Harmless no-op on write-only panels (MAG341C): the
      // read fails its guard and the last-written state stands.
      await state.controller.waitForPendingWrites()
      if !safeMode { await state.controller.refreshFromHardware() }
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
    // controller already seeded from the same read at init). The built-in's
    // read is native (DisplayServices), not DDC — ungated under safe mode.
    await builtIn?.controller.refreshFromHardware()
    restartPoller()
    // Drop verdicts for departed displays: a replug hands out a fresh
    // IOAVService, so an old answer is not evidence about the new wire.
    let live = Set(displays.map(\.display.persistenceKey))
    volumeSupport = volumeSupport.filter { live.contains($0.key) }
    // Same rule, same reason: a replug hands out a fresh IOAVService, so an old
    // answer is not evidence about the new wire.
    capabilityString = capabilityString.filter { live.contains($0.key) }
    hardwareFacts = hardwareFacts.filter { live.contains($0.key) }
    probeVolumeCapabilities()
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
        volume: existing.volume, contrast: existing.contrast, writer: existing.writer
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
      role: .builtIn,
      // store/storageKey/legacyKey stay nil (re-review T10-E): macOS owns
      // built-in brightness across launches; the controller seeds from a
      // native read at init.
      mirrorTopology: mirrorTopology
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
      ),
      // No DDC wire, and nothing ever probes the built-in slot (the D24 pass
      // walks `displays`, which is external-only) — but `DisplayState` has one
      // shape for both slots, so the honest stub goes here too.
      writer: NoopDDCWriter()
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
