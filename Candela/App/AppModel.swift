import CandelaKit
import CoreGraphics
import Foundation
import Observation
import os
import ServiceManagement

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

  /// ONE gate for every display-reconfiguring feature (AR12): display modes,
  /// mirroring, rotation and arrangement. Declared before all four because each
  /// of them takes it as a required init parameter — a defaulted gate would give
  /// each coordinator a private one, which compiles, runs, and excludes nobody.
  let reconfigurationGate = DisplayReconfigurationGate()

  /// Display-mode enumeration, the preview countdown and stored-mode writes.
  /// Owned here rather than by a view because the countdown must outlive
  /// whatever window started it, and because the settings pane and the panel
  /// have to drive the same session.
  ///
  /// `@ObservationIgnored lazy` for the reason `mirroring` below is: it names a
  /// stored property declared above it, and the Observation macro cannot wrap a
  /// `lazy var`. Views observe the coordinator's own properties, not this
  /// reference.
  ///
  /// The physical-facts provider is wired here rather than at a surface for
  /// `didStoreMode`'s reason: the catalog is rebuilt at reconnect with nothing
  /// on screen, so a view-installed provider would be absent exactly when the
  /// panel's own size is being judged.
  @ObservationIgnored private(set) lazy var displayModes: DisplayModeCoordinator = {
    let coordinator = DisplayModeCoordinator(gate: reconfigurationGate)
    coordinator.physicalFacts = { [weak self] display in
      self?.physicalPanelFacts(for: display)
    }
    // A synthesized stop is a row in this coordinator's catalog and a preview on
    // its clock, so the routing lives there; the engine lives in `synthesis`.
    coordinator.synthesis = synthesis
    return coordinator
  }()

  /// Synthesized sizes (SS4): the mode-synthesis engine, its preview session,
  /// the pairing snapshot every SS7 carve-out reads, and the two per-display
  /// prefs.
  ///
  /// Owned here for `displayModes`' reason and one of its own: an engage and a
  /// disengage take tens of seconds and outlive any window that started them,
  /// and the settings pane, the menu-bar panel and the whole-app reset all have
  /// to drive the same engine.
  @ObservationIgnored private(set) lazy var synthesis: SynthesisCoordinator = {
    let coordinator = SynthesisCoordinator(
      virtualDisplays: virtualDisplays,
      configurator: CoreGraphicsDisplayConfigurator(),
      gate: reconfigurationGate,
      topologyStore: mirrorTopology
    )
    // The prefs join. Built from the DISPLAY PREFS persistence key, which is
    // what every per-display accessor suffixes on; `DisplayConfigIdentity.key`
    // is a different key space and reading one while writing the other is a
    // silent opt-in that saves and reads back false.
    coordinator.persistenceKey = { [weak self] displayID in
      self?.allControlledStates.first { $0.id == displayID }?.display.persistenceKey
    }
    // SS9. The achieved state first, and the stored intent as well: at launch
    // the controllers may not exist yet, and refusing on either answer is the
    // conservative direction for a guard whose failure mode is a silently
    // dropped HDR.
    coordinator.isHDREngaged = { [weak self] displayID in
      guard let self else { return false }
      if allControlledStates.first(where: { $0.id == displayID })?.controller.isHDREngaged == true {
        return true
      }
      guard let key = allControlledStates.first(where: { $0.id == displayID })?
        .display.persistenceKey
      else { return false }
      return DisplayPrefs(persistenceKey: key).hdrMode != .off
    }
    // `didWriteSynthesisPref` is wired in `StatusItemController`, where
    // `SettingsActions` lives; see `didStoreMode` beside it.
    // The opt-in decides which rows the size picker holds, and the catalog is
    // enumerated on demand: a pref write alone re-renders the panes over the
    // rows they already had.
    coordinator.didChangeOffer = { [weak self] displayID in
      self?.displayModes.refreshCatalog(for: displayID)
    }
    // The exact mechanism `MirroringCoordinator` uses before its own applies: a
    // synthesis teardown reconfigures displays too, so it must not run over a
    // preview whose fallback was captured before it.
    coordinator.endOutstandingPreview = { [weak self] in
      guard let self else { return true }
      return await displayModes.endOutstandingPreview()
    }
    // AR12's release funnel. Synthesis shares the `.displayModes` claimant with
    // the mode picker, so it must never release the gate itself: the
    // coordinator decides, from BOTH sessions, whether anything is still
    // outstanding that the claim is protecting.
    coordinator.releaseClaimIfIdle = { [weak self] in
      await self?.displayModes.releaseReconfigurationClaimIfIdle()
    }
    return coordinator
  }()

  /// PD7: the app-side half of the density join. The Kit is handed a value and
  /// performs no lookup of its own.
  ///
  /// Both halves are resolved from the LIVE display list on every call, never
  /// remembered: `hardwareFacts` is keyed by persistence key because display IDs
  /// reassign across a replug, so the ID this is asked about only means anything
  /// against the list as it stands right now.
  ///
  /// A display with no entry yields nil sizes rather than no facts, so a virtual
  /// display still reports itself as virtual. It has to: discovery drops virtual
  /// displays from the DDC pool, so they never have facts, and their declared
  /// physical size is a fiction no plausibility range can catch.
  private func physicalPanelFacts(
    for display: ConfiguredDisplay
  ) -> DisplayModeCoordinator.PhysicalPanelFacts {
    // Ours by ownership, everyone else's by the optional-returning predicate
    // (nil reads as an ordinary panel), the same pair the arrangement canvas
    // asks. Two answers to "is this virtual" is one too many.
    let isVirtual = virtualDisplays.ownedDisplayIDs.contains(display.id)
      || VirtualDisplayDetection.isVirtual(display.id) == true
    let facts = allControlledStates
      .first { $0.id == display.id }
      .flatMap { hardwareFacts[$0.display.persistenceKey] }
    return DisplayModeCoordinator.PhysicalPanelFacts(
      physicalWidthCm: facts?.physicalWidthCm,
      physicalHeightCm: facts?.physicalHeightCm,
      isVirtual: isVirtual
    )
  }

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
    store: mirrorTopology, modes: displayModes, gate: reconfigurationGate
  )

  /// Rotation requests and the rotation countdown. Owned here for
  /// `displayModes`' reason — the countdown must outlive whatever window started
  /// it. Unlike the other two it persists nothing: a rotation is already system
  /// state the instant it applies (RT2).
  @ObservationIgnored private(set) lazy var rotation = RotationCoordinator(
    gate: reconfigurationGate
  )

  /// The display arrangement, its preview countdown, and the layout on screen.
  /// Owned here for `displayModes`' reason — the countdown must outlive whatever
  /// started the change, and an arrangement change is the one that can move the
  /// menu bar out from under the window that asked for it.
  @ObservationIgnored private(set) lazy var arrangement = ArrangementCoordinator(
    gate: reconfigurationGate
  )

  /// OLED care's timers and care dim (W3a). Owned here for `displayModes`'
  /// reason — the idle timers must outlive whatever pane configured them.
  @ObservationIgnored private(set) lazy var oledCare = OledCareCoordinator()

  /// Displays Candela creates (VD4). In-process ownership is what makes a
  /// crash reclaim them; the host's owned set is the ONLY authority on "is
  /// this one of ours" and feeds discovery's DDC-pool exclusion.
  @ObservationIgnored let virtualDisplays = VirtualDisplayHost()

  @ObservationIgnored private let log = Logger(
    subsystem: "com.rydersel.Candela", category: "virtualdisplay"
  )

  /// Serializes every create/destroy off the main actor: the host blocks
  /// (it polls the online list), and menu tracking starves main-actor work.
  @ObservationIgnored private let virtualDisplayQueue = DispatchQueue(
    label: "com.rydersel.Candela.vdsync", qos: .userInitiated
  )

  /// Slots with a create/destroy in flight on the vd queue. Observable so
  /// the pane can disable a slot's buttons and say it is working; a create
  /// can legitimately take ~10 s.
  private(set) var virtualSlotBusy: Set<Int> = []

  /// The last failure per slot, cleared by the next success. Observable so
  /// the pane can say WHY a slot is not running instead of silently reverting
  /// to a Create button.
  private(set) var virtualSlotIssues: [Int: VirtualDisplayFailure] = [:]

  /// The `.syncVirtualDisplays` effect (VD14): converge live virtual displays
  /// to the slot prefs. Reconciliation is pure (`VirtualDisplayReconciler`);
  /// this only executes what it returns, one action set at a time.
  ///
  /// - Parameter slot: scope of the convergence. The pane passes the slot
  ///   whose `configured` was written, so one slot's Create can never
  ///   recreate another slot that has drifted-but-unapplied edits (VD17),
  ///   and a Safe Mode Create brings up exactly the clicked slot. nil is
  ///   the launch sweep.
  func syncVirtualDisplays(slot: Int? = nil) {
    // A create landing between the reset's destroy step and the domain wipe
    // would stand a display no pref explains (VD15).
    guard !isResetting else { return }
    // VD9: every configured slot has a persisted uuid BEFORE any create, so
    // "the same display across recreations" holds on every configure path,
    // not only the pane's.
    for n in VirtualDisplayIdentity.userSlotRange where slot == nil || slot == n {
      var definition = appPrefs.virtualSlot(n)
      if definition.configured, definition.uuid == nil {
        definition.uuid = UUID()
        appPrefs.setVirtualSlot(definition, slot: n)
      }
    }
    let definitions = appPrefs.virtualSlotDefinitions()
    let host = virtualDisplays
    let actions = VirtualDisplayReconciler.actions(
      definitions: definitions, live: host.live(), isAvailable: host.isAvailable, limitedTo: slot
    )
    guard !actions.isEmpty else { return }
    virtualSlotBusy.formUnion(actions.map(\.slot))
    virtualDisplayQueue.async { [weak self] in
      var failures: [Int: VirtualDisplayFailure] = [:]
      var succeeded: [Int] = []
      func runCreate(_ slot: Int) {
        guard let definition = definitions[slot] else { return }
        switch host.create(
          definition.spec, slot: slot, uuid: definition.uuid ?? UUID(), appearanceTimeout: 10
        ) {
        case .success: succeeded.append(slot)
        case let .failure(failure): failures[slot] = failure
        }
      }
      for action in actions {
        switch action {
        case let .create(slot):
          runCreate(slot)
        case let .destroy(slot):
          if host.destroy(slot: slot, departureTimeout: 5) {
            succeeded.append(slot)
          } else {
            failures[slot] = .didNotDepart
          }
        case let .recreate(slot):
          // The old display must be GONE before the same identity is
          // re-advertised, or the create only collects the duplicate
          // refusal after a full timeout.
          if host.destroy(slot: slot, departureTimeout: 5) {
            runCreate(slot)
          } else {
            failures[slot] = .didNotDepart
          }
        }
      }
      // Immutable copies: the vars above are confined to the queue closure,
      // and sending them into the MainActor task as constants is what strict
      // concurrency can prove race-free.
      let finishedSlots = succeeded
      let failedSlots = failures
      Task { @MainActor [weak self] in
        guard let self else { return }
        for slot in finishedSlots { virtualSlotIssues[slot] = nil }
        for (slot, failure) in failedSlots {
          virtualSlotIssues[slot] = failure
          // A slot that could not be created must not stay `configured`:
          // every later sync and every launch would silently retry a doomed
          // 10-second create. The retry becomes the user's decision.
          var definition = appPrefs.virtualSlot(slot)
          if definition.configured, failure != .didNotDepart {
            definition.configured = false
            appPrefs.setVirtualSlot(definition, slot: slot)
          }
        }
        virtualSlotBusy.subtract(actions.map(\.slot))
        notePrefsChanged()
      }
    }
  }

  /// Launch prelude (VD6, VD13). Normalizes the slot prefs first: a
  /// configured slot without recreate-at-launch died with the last session
  /// and its pref must say so before the first sync. Then logs any online
  /// display carrying a slot identity nothing owns (the asleep-panel crash
  /// orphan, S1 §5A) — the recreation that follows triggers the WindowServer
  /// re-enumeration measured to clear such orphans. Safe Mode stops before
  /// the sync: recreation is automatic startup behavior; an explicit Create
  /// in the pane still works (VD13).
  func syncVirtualDisplaysAtLaunch() {
    let (normalized, changed) = VirtualDisplayReconciler.launchNormalized(
      definitions: appPrefs.virtualSlotDefinitions()
    )
    for slot in changed {
      if let definition = normalized[slot] { appPrefs.setVirtualSlot(definition, slot: slot) }
    }
    logOrphanedVirtualDisplays()
    guard !safeMode else { return }
    syncVirtualDisplays()
  }

  private func logOrphanedVirtualDisplays() {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return }
    let owned = virtualDisplays.ownedDisplayIDs
    for id in ids.prefix(Int(count)) where !owned.contains(id) {
      let vendor = CGDisplayVendorNumber(id)
      let model = CGDisplayModelNumber(id)
      guard vendor == VirtualDisplayIdentity.vendorID,
            VirtualDisplayIdentity.slotRange
            .map(VirtualDisplayIdentity.productID(slot:)).contains(model)
      else { continue }
      log.error(
        "vd: orphaned slot display online at launch (id \(id), model 0x\(String(model, radix: 16), privacy: .public)); a previous instance likely died with the built-in panel asleep"
      )
    }
  }

  /// VD15's first half, called by the settings reset BEFORE the domain wipe
  /// removes the slot keys: a wiped `configured` with the display still
  /// standing would be state the pane can no longer explain.
  func destroyAllVirtualDisplaysForReset() async {
    // SS11: the ENGINE takes its own displays down first, and it is verified.
    // `destroyAll` below would otherwise release the synthesis slots behind the
    // engine's back, leaving its pairing table describing a virtual display
    // that has departed and every SS7 carve-out reading a set that is not
    // there. The synthesis prefs are cleared by the domain wipe that follows,
    // which is the same ordering: teardown first, keys after.
    await synthesis.disengageAllForReset()
    let host = virtualDisplays
    await withCheckedContinuation { continuation in
      virtualDisplayQueue.async {
        host.destroyAll(departureTimeout: 5)
        continuation.resume()
      }
    }
  }

  /// App-level M4 prefs (startupAction, multiKeyboardVolume, showContrast)
  /// read through one DisplayPrefs like the engine does; the persistence key
  /// is irrelevant for unsuffixed accessors. Assigned in `init` rather than
  /// inline: it needs the safe-mode flag, which arrives as an init parameter.
  @ObservationIgnored private let appPrefs: DisplayPrefs

  /// Raised for the whole of any settings reset, per-display or all-settings.
  /// ONE latch for both, because the pair is what goes wrong: a per-display
  /// reset running alongside Reset All restores HDR through a controller the
  /// rebuild has already replaced, so the write lands on an object nothing is
  /// looking at while the live display keeps a locked register. Observable, so
  /// both buttons can refuse the second click rather than relying on nobody
  /// making it.
  private(set) var isResetting = false

  /// Claims the latch. False means a reset is already running and this one must
  /// not start.
  func beginReset() -> Bool {
    guard !isResetting else { return false }
    isResetting = true
    return true
  }

  func endReset() { isResetting = false }

  /// D24: per-display VCP 0x62 verdict from the capabilities string. Observable,
  /// so the panel's volume slider enables/disables live the moment a probe
  /// lands. An ABSENT entry means "not probed yet, or the probe was skipped" and
  /// reads as `.unknown` — the panel is fully usable before any DDC happens. A
  /// STORED `.unknown` means the probe ran and failed, and is cached for the
  /// session so a write-only panel (the MAG 341C) is not re-probed on every
  /// menu close.
  private(set) var volumeSupport: [String: VCPSupport] = [:]

  /// The same verdict for VCP 0x8D, read from the same capabilities string in
  /// the same pass. Separate because the two registers are separately
  /// advertised: a display can list mute and not volume, or the reverse, and
  /// the mute key writes whichever one the display's mute strategy selects.
  /// Absent reads as `.unknown` for `volumeSupport`'s reasons, and never greys
  /// the slider, which is a 0x62 surface only.
  private(set) var muteSupport: [String: VCPSupport] = [:]

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

  /// The tap was torn down (#59: revocation). Diagnostics must report "the
  /// media-key tap is not running", not the config of a tap that no longer
  /// exists.
  func noteTapDisarmed() {
    lastArmedTapConfig = nil
  }

  /// The gamma-interference monitor, injected by `StatusItemController` after
  /// construction (it owns the AppKit alert island the monitor needs). Read
  /// ONLY for reporting — nothing here drives it.
  @ObservationIgnored var gammaInterference: GammaInterferenceMonitor?

  /// The last 20 display arrivals, departures and failed resolution restores,
  /// newest first, for the diagnostics report (spec §7 — churn bugs are about
  /// displays that just left, and by the time anyone copies a report the
  /// display in question is usually gone).
  ///
  /// Stamped HERE, at append, because `DiagnosticsReport.render` is pure by
  /// contract: the same snapshot must render to the same bytes forever, which
  /// is what makes two pasted reports diffable.
  private(set) var recentDisplayEvents: [String] = []

  /// A controller rebuild empties both slots and re-discovers, so every display
  /// looks like an arrival to `performRefresh` — see `rebuildControllers`. That
  /// is a settings reset, not a topology change, and recording it would fill the
  /// ring with events that never happened at the wire.
  @ObservationIgnored private var suppressDisplayEvents = false

  func noteDisplayEvent(_ description: String) {
    guard !suppressDisplayEvents else { return }
    let stamp = Date.now.formatted(date: .omitted, time: .shortened)
    recentDisplayEvents.insert("\(stamp) \(description)", at: 0)
    if recentDisplayEvents.count > 20 {
      recentDisplayEvents.removeLast(recentDisplayEvents.count - 20)
    }
  }

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

  /// First-sight lines dismissed this session (SO22), by persistence key.
  /// In-memory ON PURPOSE — never a marker pref: the line renders while the
  /// display's pref domain is empty, and writing anything to dismiss it would
  /// defeat the emptiness check it is gated on. Dying with the process is the
  /// intended lifetime for an informational line about a display that is,
  /// definitionally, about to acquire stored values or stay untouched.
  private(set) var dismissedFirstSightKeys: Set<String> = []

  func dismissFirstSight(_ persistenceKey: String) {
    dismissedFirstSightKeys.insert(persistenceKey)
  }

  /// Where each display's stranded-mute recovery got to, by persistence key.
  ///
  /// Owned here rather than by `BannerRegion` because that region has TWO live
  /// placements (the hub root and whatever sub-page is pushed over it), and
  /// `@State` would give them a phase each: the user would click on one page
  /// and walk back to find the outcome gone. In memory and session-scoped for
  /// the same reason the first-sight dismissals are: it describes an action
  /// just taken, not a setting.
  private(set) var muteRecoveryPhases: [String: MuteRecoveryPhase] = [:]

  enum MuteRecoveryPhase: Equatable {
    case running
    /// The unmute did not reach the display. Carries WHY, because HDR is a
    /// thing the user can go and turn off and the other case is a retry.
    case failed(StrandedMuteOutcome)
  }

  func setMuteRecoveryPhase(_ phase: MuteRecoveryPhase?, for persistenceKey: String) {
    muteRecoveryPhases[persistenceKey] = phase
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

  /// What a discovery pass returns, named so the seam below can be spelled
  /// without repeating the tuple.
  typealias DiscoveredDisplays = [(
    display: ExternalDisplay, writer: any DDCWriting, facts: DisplayHardwareFacts
  )]

  /// How this model finds displays.
  ///
  /// Injected for ONE case that cannot be produced by hand (#51): a different
  /// panel arriving on a display ID we already hold, inside a SINGLE refresh
  /// pass. Every physical unplug fires its own reconfiguration, so a same-port
  /// swap always splits into a departure pass and an arrival pass, and the
  /// reconciliation branch that matters is never entered. Verified on the rig
  /// 2026-08-17 by the event ring's ordering, which distinguishes the two.
  @ObservationIgnored private let discoverDisplays: (Set<CGDirectDisplayID>) -> DiscoveredDisplays

  init(
    shade: (any ShadeRendering)? = nil,
    gamma: (any GammaApplying)? = nil,
    hdrToggling: (any HDRToggling)? = nil,
    audioDevices: (any AudioDeviceProviding)? = nil,
    safeMode: Bool = false,
    discoverDisplays: @escaping (Set<CGDirectDisplayID>) -> DiscoveredDisplays = {
      DisplayDiscovery.discover(excluding: $0)
    }
  ) {
    self.shade = shade
    self.gamma = gamma
    self.hdrToggling = hdrToggling ?? MonitorPanelService()
    self.audioDevices = audioDevices ?? CoreAudioDeviceProvider()
    self.safeMode = safeMode
    self.discoverDisplays = discoverDisplays
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

  /// SO21: two connected displays resolving to ONE persistence key — identical
  /// units reporting no serial — share every pref, and the surfaces that show
  /// those prefs say so. Computed from the live display list at every read,
  /// never persisted: the state exists exactly while both units are attached.
  ///
  /// Asked of `DisplayOrdering.sharedIdentityOrdinals` rather than recounted
  /// here, so shared identity has ONE definition: a key is shared exactly when
  /// its rows get numbered. The hub's caption and the sidebar's numbering are
  /// the two surfaces reading it, and a recount would let them drift apart
  /// under any change to what counts as shared (excluding hidden displays, say).
  func isSharedIdentity(_ persistenceKey: String) -> Bool {
    let keys = displays.map(\.display.persistenceKey)
    return zip(keys, DisplayOrdering.sharedIdentityOrdinals(keys: keys))
      .contains { $0 == persistenceKey && $1 != nil }
  }

  // MARK: - Diagnostics report

  /// Everything the diagnostics report says, gathered at the moment the button
  /// was pressed (spec §7). EVERY controlled display, built-in included — the
  /// report is copied into an issue about one display and read by someone who
  /// needs to know what else was attached.
  ///
  /// No serial VALUE enters it, only `hasSerial`. The other half of the scrub
  /// contract — bare pref names, never composed `UserDefaults` keys — is
  /// `DiagnosticsPrefSummary`'s, in CandelaKit, where a test pins it over every
  /// line it emits.
  func diagnosticsSnapshot() -> DiagnosticsReportSnapshot {
    DiagnosticsReportSnapshot(
      appVersion: "\(AppInfo.version) (\(AppInfo.build))",
      osVersion: osVersionText,
      safeMode: safeMode,
      accessibilityGranted: accessibility.isGranted,
      launchAtLogin: launchAtLoginText,
      displays: allControlledStates.map(diagnosticsEntry),
      recentEvents: recentDisplayEvents
    )
  }

  private func diagnosticsEntry(_ state: DisplayState) -> DiagnosticsReportSnapshot.DisplayEntry {
    let persistenceKey = state.display.persistenceKey
    let prefs = DisplayPrefs(persistenceKey: persistenceKey)
    let facts = hardwareFacts[persistenceKey]
    let isBuiltIn = builtIn?.id == state.id
    return DiagnosticsReportSnapshot.DisplayEntry(
      name: DisplayOrdering.title(
        friendlyName: prefs.friendlyName, hardwareName: state.display.name
      ),
      hardwareName: state.display.name,
      // The built-in never passes through `DisplayDiscovery`, so its facts are
      // permanently absent and "not reported" would read as a failed lookup
      // rather than as a panel with no cable.
      connection: isBuiltIn ? "None: built-in display" : DiagnosticsCopy.transport(facts),
      manufacturer: isBuiltIn ? nil : facts?.manufacturerID,
      hasSerial: facts?.numericSerialNumber != nil || facts?.alphanumericSerialNumber != nil,
      // Never `catalogs[...]?.current` directly: the catalog exists only for
      // displays something has already shown, so the built-in's entry depends
      // on which pages were visited this session (combined pass D8).
      //
      // A synthesis-engaged display answers from the ENGINE instead, and this
      // is Phase 0's binding rule rather than a preference: while a stop is
      // engaged the readback is the virtual master's geometry under a
      // fabricated mode id that appears in no enumeration, so a report quoting
      // it would name a mode nobody can look up. The engine's pairing carries
      // the slot too, which is what tells two engaged displays apart in a
      // pasted report and is the handoff's "the stop in force belongs in the
      // report's mode line".
      currentMode: synthesis.pairing(forPhysical: state.id).map {
        SynthesisCopy.reportMode(
          width: $0.size.logicalWidth, height: $0.size.logicalHeight, slot: $0.slot)
      } ?? displayModes.currentMode(for: state.id).map(DiagnosticsCopy.mode),
      controlMethod: DiagnosticsCopy.brightnessPath(state.controller.brightnessPath),
      readbackVerdict: isBuiltIn
        ? "Not applicable: no data cable"
        : DiagnosticsCopy.readbackVerdict(DDCReadEvidence.worst([
          state.controller.readEvidence,
          state.volume.readEvidence,
          state.contrast.readEvidence,
        ])),
      hdrEngaged: state.controller.isHDREngaged,
      nonDefaultPrefs: DiagnosticsPrefSummary.nonDefaultPrefs(
        prefs, remembersMode: displayModes.isRemembering(state.id)
      )
    )
  }

  /// `operatingSystemVersionString` is "Version 26.0 (Build 25A100)" today. The
  /// build number is what identifies an exact OS to whoever triages the paste,
  /// so it is kept rather than recomposed from `operatingSystemVersion`; the
  /// prefix swap degrades to the raw string if Apple changes the wording.
  private var osVersionText: String {
    let raw = ProcessInfo.processInfo.operatingSystemVersionString
    guard raw.hasPrefix("Version ") else { return raw }
    return "macOS " + raw.dropFirst("Version ".count)
  }

  /// D10: a LIVE read of the one source of truth, never a mirrored bool. The
  /// three non-enabled states are distinct answers — "requires approval" is the
  /// one a user can act on, and folding it into "not registered" is what makes
  /// a login-item report useless.
  private var launchAtLoginText: String {
    switch SMAppService.mainApp.status {
    case .enabled: "enabled"
    case .notRegistered: "not registered"
    case .requiresApproval: "requires approval"
    case .notFound: "not found"
    @unknown default: "unknown"
    }
  }

  /// Fork `!display.isDisabled` (per-display "disable keyboard control",
  /// review R1): every key loop skips a disabled display's BODY, but the tap
  /// still swallows the event — fork parity; spec Appendix A's pass-through
  /// parenthetical is wrong about the fork. Read live per call.
  func keyEnabledStates(_ states: [DisplayState]) -> [DisplayState] {
    states.filter { !DisplayPrefs(persistenceKey: $0.display.persistenceKey).isDisabled }
  }

  /// The same filter for VOLUME keys, which additionally obey D24: the
  /// monitor's own denial of VCP 0x62, the verdict that greys the slider
  /// (`volumeSliderEnabled` asks the same policy for the slider surfaces). One
  /// predicate for both, so a keypress cannot write a register the display says
  /// it does not implement while its slider sits greyed for that exact reason.
  ///
  /// Brightness and contrast keys keep the plain filter: the denial is about the
  /// volume register, not about the display.
  ///
  /// A display dropped here SWALLOWS its press. The executor's
  /// nothing-resolved fallbacks run BEFORE this filter (R1), so a denied display
  /// never converts its keypress into a step of every other panel.
  func volumeKeyEnabledStates(_ states: [DisplayState]) -> [DisplayState] {
    states.filter { state in
      let prefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)
      return VolumeSliderPolicy.acceptsVolumeKeys(
        isKeyboardDisabled: prefs.isDisabled,
        override: prefs.audioSinkOverride,
        volumeSupport: volumeSupport[state.display.persistenceKey] ?? .unknown
      )
    }
  }

  /// The mute key's own filter. It asks about the register the key would write,
  /// which the display's mute strategy chooses: the dedicated command sends VCP
  /// 0x8D, and without it silence is a volume-register write of 0.
  ///
  /// The strategy is the one IN FORCE, not the raw pref: a display whose
  /// capabilities string denies 0x8D does not get the dedicated command, and
  /// `DDCValueController` degrades its mute to the volume register. The engine
  /// and this filter compute it from one function, so the key cannot be judged
  /// on a register the write will not touch.
  ///
  /// Unmuting never depends on this. Every route back (the display's mute
  /// toggle, the hardware-control toggle, the reset, the stranded-mute banner)
  /// drives the controller directly and asks no capability verdict, which is
  /// what keeps a refusal here inside D29 rule 3.
  func muteKeyEnabledStates(_ states: [DisplayState]) -> [DisplayState] {
    states.filter { state in
      let key = state.display.persistenceKey
      let prefs = DisplayPrefs(persistenceKey: key)
      return VolumeSliderPolicy.acceptsMuteKey(
        isKeyboardDisabled: prefs.isDisabled,
        override: prefs.audioSinkOverride,
        volumeSupport: volumeSupport[key] ?? .unknown,
        muteSupport: muteSupport[key] ?? .unknown,
        usesDedicatedMuteCommand: usesDedicatedMuteCommand(prefs, key: key)
      )
    }
  }

  func stepBrightnessAllExternal(isUp: Bool, isFine: Bool) -> [(id: CGDirectDisplayID, name: String, newValue: Double)] {
    keyEnabledStates(displays).map { state in
      (state.id, state.display.name, state.controller.step(isUp: isUp, isFine: isFine))
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
  func stepBrightness(displayIDs: [CGDirectDisplayID], isUp: Bool, isFine: Bool) -> [(id: CGDirectDisplayID, name: String, newValue: Double)] {
    displayIDs.compactMap { displayID in
      let slot = displays.first { $0.id == displayID } ?? builtIn.flatMap { $0.id == displayID ? $0 : nil }
      // isDisabled filters the loop body (R1): a resolved-but-disabled
      // display steps nothing and shows no HUD; the executor's empty-result
      // fallback path itself re-runs through keyEnabledStates.
      guard let slot, !keyEnabledStates([slot]).isEmpty else { return nil }
      return (slot.id, slot.display.name,
              slot.controller.step(isUp: isUp, isFine: isFine))
    }
  }

  /// Steps the built-in panel (Ctrl-directed keys only — plain presses target
  /// the pointer's display, which may well be the built-in). Returns nil when
  /// no built-in display is online.
  func stepBrightnessBuiltIn(isUp: Bool, isFine: Bool) -> (id: CGDirectDisplayID, name: String, newValue: Double)? {
    guard let builtIn, !keyEnabledStates([builtIn]).isEmpty else { return nil }
    return (builtIn.id, builtIn.display.name,
            builtIn.controller.step(isUp: isUp, isFine: isFine))
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
    if KeyModePolicy.watchesMediaKeys(appPrefs.keyboardVolume) {
      // Fork getDdcCapableDisplays (= !isSw(), review R5): the fork's own
      // disengage gate, kept because it is where the rule came from. The
      // per-display arming verdict below refuses a forceSoftware display too,
      // through the same availability switch the engine checks before a write,
      // so this line is no longer what decides such a rig on its own.
      let ddcDisplaysExist = !ddcCapableStates().isEmpty
      let pool = volumeKeyPool(for: device)
      // Asked once per family, because the two arm on different registers.
      func watches(_ actionable: Int) -> Bool {
        AudioRoutingPolicy.shouldWatchVolumeKeys(
          mode: volumeMode,
          ddcDisplaysExist: ddcDisplaysExist,
          actionableDisplayCount: actionable,
          defaultOutput: device
        )
      }
      if watches(pool.filter(armsVolumeKeys).count) {
        watched.formUnion([.volumeUp, .volumeDown])
      }
      if watches(pool.filter(armsMuteKey).count) {
        watched.insert(.mute)
      }
    }
    return .init(
      watchedKeys: watched,
      interceptAlternateBrightnessKeys: appPrefs.interceptAlternateBrightnessKeys
    )
  }

  /// The candidate pool a volume or mute press would resolve to under the
  /// current mode, before any per-display verdict: the same three branches as
  /// `KeyActionExecutor.volumeKeyCandidates`, which is what makes the arming
  /// question and the acting question one question.
  ///
  /// The mouse mode resolves to the pointer's display at key time, and the tap
  /// cannot know in advance where the pointer will be, so this is the union: that
  /// mode falls back to every display when the pointer resolves no external, so
  /// `displays` is the set a press could reach either way.
  ///
  /// The union is deliberately wider than any one press. With the pointer on a
  /// display that refuses while another accepts, the keys stay armed and that
  /// press is swallowed with nothing to show for it. That is R1 as specified: the
  /// press was aimed at a display that refuses it, and the alternative is
  /// spraying it at the panels the user was not pointing at.
  private func volumeKeyPool(for device: AudioOutputDevice?) -> [DisplayState] {
    switch volumeMode {
    case .audioDeviceNameMatching: audioMatchingDisplays(for: device)
    case .allScreens, .mouse: displays
    }
  }

  /// Does this display keep the volume keys armed? Everything the executor's
  /// verdict is made of except the per-display keyboard switch: the capability
  /// half of `volumeKeyEnabledStates`, plus the controller's own availability
  /// (`VolumeSliderPolicy.armsVolumeKeys` states why the switch is left out and
  /// why availability is passed rather than re-derived).
  ///
  /// `state.volume.isAvailable` is read from the controller the press would go
  /// through, not rebuilt from its two prefs here, so the tap cannot come to a
  /// different conclusion than the write path about the same wire.
  private func armsVolumeKeys(_ state: DisplayState) -> Bool {
    let key = state.display.persistenceKey
    return VolumeSliderPolicy.armsVolumeKeys(
      commandIsAvailable: state.volume.isAvailable,
      override: DisplayPrefs(persistenceKey: key).audioSinkOverride,
      volumeSupport: volumeSupport[key] ?? .unknown
    )
  }

  /// The same for the mute key, on the register the display's mute strategy
  /// selects: the register `muteKeyEnabledStates` would write. Availability is
  /// the volume controller's under both strategies, because that is the
  /// controller `toggleMute` runs on.
  private func armsMuteKey(_ state: DisplayState) -> Bool {
    let key = state.display.persistenceKey
    let prefs = DisplayPrefs(persistenceKey: key)
    return VolumeSliderPolicy.armsMuteKey(
      commandIsAvailable: state.volume.isAvailable,
      override: prefs.audioSinkOverride,
      volumeSupport: volumeSupport[key] ?? .unknown,
      muteSupport: muteSupport[key] ?? .unknown,
      usesDedicatedMuteCommand: usesDedicatedMuteCommand(prefs, key: key)
    )
  }

  /// Which register a mute lands on for this display: the pref, vetoed by the
  /// display's own denial of 0x8D, because `DDCValueController` degrades that
  /// mute to the volume register rather than recording a mute nothing carries.
  ///
  /// ONE derivation for the tap's arming and the executor's filter, and the
  /// same function the engine computes it with. The raw pref diverges from the
  /// write in exactly the cell this exists for (0x8D denied, 0x62 alive): the
  /// tap would hand macOS a mute key the engine can honour.
  private func usesDedicatedMuteCommand(_ prefs: DisplayPrefs, key: String) -> Bool {
    VolumeSliderPolicy.usesDedicatedMuteCommand(
      prefEnabled: prefs.enableMuteUnmute,
      override: prefs.audioSinkOverride,
      muteSupport: muteSupport[key] ?? .unknown
    )
  }

  /// Re-arm hook for the media-key tap, injected by `StatusItemController`.
  ///
  /// The watched set now reads the capabilities verdict, and that verdict lands
  /// asynchronously, seconds after the display appears. Without this the tap
  /// stays armed from the pre-probe answer for the whole session: a display that
  /// turns out to deny the register would keep swallowing keys that reach
  /// nobody, which is the state the arming rule exists to end.
  @ObservationIgnored var onVolumeKeyRoutingChanged: (() -> Void)?

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

  /// The tooltip for a greyed volume slider, from the same two inputs the
  /// enablement reads, so the explanation can never describe a cause other than
  /// the one that applied.
  func volumeSliderDisabledReason(_ state: DisplayState, displayName: String) -> String? {
    VolumeSliderPolicy.disabledReason(
      displayName: displayName,
      override: DisplayPrefs(persistenceKey: state.display.persistenceKey).audioSinkOverride,
      volumeSupport: volumeSupport[state.display.persistenceKey] ?? .unknown
    )
  }

  /// Would turning the mute row ON actually send this display's own mute
  /// command? The strategy asked with the pref held on, so it answers the
  /// switch's PROMISE rather than its position, which is what the row's spoken
  /// label describes in both positions.
  func dedicatedMuteCommandInReach(_ state: DisplayState) -> Bool {
    let key = state.display.persistenceKey
    return VolumeSliderPolicy.usesDedicatedMuteCommand(
      prefEnabled: true,
      override: DisplayPrefs(persistenceKey: key).audioSinkOverride,
      muteSupport: muteSupport[key] ?? .unknown
    )
  }

  /// The settings row's status caption: why the mute this display takes is not
  /// the mute its row promises, or nil while the two agree.
  ///
  /// Reads the same three inputs `usesDedicatedMuteCommand(_:key:)` passes, and
  /// the policy resolves them through that same function, so the caption cannot
  /// name a degrade the engine is not doing. `muteSupport` is observed, so the
  /// row re-reads when the capabilities probe lands seconds after the display
  /// appears.
  func degradedMuteReason(_ state: DisplayState) -> String? {
    let key = state.display.persistenceKey
    let prefs = DisplayPrefs(persistenceKey: key)
    return VolumeSliderPolicy.degradedMuteReason(
      commandIsAvailable: state.volume.isAvailable,
      prefEnabled: prefs.enableMuteUnmute,
      override: prefs.audioSinkOverride,
      muteSupport: muteSupport[key] ?? .unknown
    )
  }

  /// The same reason worded for the menu bar's panel, which renders it under the
  /// display's own name header and so must not repeat that name (#130).
  func volumeSliderCompactReason(_ state: DisplayState) -> String? {
    VolumeSliderPolicy.compactDisabledReason(
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
        let previousVolume = self.volumeSupport[persistenceKey]
        let previousMute = self.muteSupport[persistenceKey]
        self.volumeSupport[persistenceKey] = capabilities.map {
          CapabilityString.support(forVCP: VCP.audioSpeakerVolume, in: $0)
        } ?? .unknown
        // One string, both verdicts, one statement: the probe gate reads
        // `volumeSupport`, so a mute verdict written anywhere else would be
        // sampled from a display this pass never asked.
        self.muteSupport[persistenceKey] = capabilities.map {
          CapabilityString.support(forVCP: VCP.audioMuteScreenBlank, in: $0)
        } ?? .unknown
        // The launch restore ran before this answer existed. It is dispatched
        // from the same main-actor turn that finishes the refresh, while this
        // probe is still out, so a muted display was restored on the assumption
        // that its mute command works. Where the answer says otherwise, the
        // restore has to be redone against the register the mute actually
        // lands on; the controller decides whether anything changed and does
        // nothing when it did not.
        self.displays.first { $0.display.persistenceKey == persistenceKey }?
          .volume.restoreIfMuteStrategyChanged()
        // These two verdicts decide which volume keys the tap watches, and they
        // land here, after the arm. A landing answer that differs from the one
        // the tap was armed from has to re-arm it.
        //
        // Compared as every reader sees them, absent folded to `.unknown`: the
        // first probe on a display always writes an entry where there was none,
        // and on a panel that answers nothing that is the same verdict written
        // down, not a change to react to.
        if self.volumeSupport[persistenceKey] != (previousVolume ?? .unknown)
          || self.muteSupport[persistenceKey] != (previousMute ?? .unknown) {
          self.onVolumeKeyRoutingChanged?()
        }
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
    // Every display re-enters as an "arrival" below; none of them moved.
    suppressDisplayEvents = true
    await refresh()
    suppressDisplayEvents = false
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
    let existing = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
    var appeared: [DisplayState] = []
    var kept: [DisplayState] = []
    let entries = discoverDisplays(virtualDisplays.ownedDisplayIDs)
    // Reconciled on PANEL identity, not on the display ID (#51). A display ID is
    // a slot: macOS reassigns them across a replug, so an ID that is still
    // present can be a different monitor, and reusing its controllers would
    // persist the new panel's brightness under the old panel's storage key and
    // hand it the old panel's tuning. The rule and its bookkeeping live in
    // `DisplayReconciliation`, where they are under test.
    let plan = DisplayReconciliation.plan(
      held: existing.mapValues(\.display.persistenceKey),
      discovered: Dictionary(
        uniqueKeysWithValues: entries.map { ($0.display.id, $0.display.persistenceKey) }))
    displays = entries.map { entry in
      // B8: discovery has always read these and always thrown them away. Kept
      // for BOTH branches below — a kept display re-reports its facts on every
      // pass, and a link renegotiation is exactly when the transport string can
      // change under a display we already know.
      hardwareFacts[entry.display.persistenceKey] = entry.facts
      if plan.reused.contains(entry.display.id), let previous = existing[entry.display.id] {
        // Fresh DisplayState (name may change), reused controllers, fresh
        // writer for all three (rebind also resets each duplicate memo).
        //
        // The persistence key rides along even though the plan has already
        // established it is unchanged: `rebind` reads it to decide whether its
        // read-derived facts still describe anything real, and passing it keeps
        // that decision in one place rather than making this call site the
        // thing that guarantees it.
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
      // Built BEFORE the brightness controller because they are part of its
      // construction: it holds this display's other write queues for the life of
      // the wire, and drops their duplicate memos whenever it sees an HDR window
      // close. The engine's parameter has no default, so this ordering is not a
      // convention anyone has to remember.
      let volume = DDCValueController(
        writer: entry.writer, command: .volume, prefs: prefs,
        store: UserDefaultsBrightnessStore(), storageKey: "volume.\(persistenceKey)",
        panelIdentity: persistenceKey
      )
      let contrast = DDCValueController(
        writer: entry.writer, command: .contrast, prefs: prefs,
        store: UserDefaultsBrightnessStore(), storageKey: "contrast.\(persistenceKey)",
        panelIdentity: persistenceKey
      )
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
        mirrorTopology: mirrorTopology,
        wireSiblings: [volume, contrast]
      )
      let state = DisplayState(
        display: entry.display, controller: controller, volume: volume, contrast: contrast,
        writer: entry.writer
      )
      appeared.append(state)
      return state
    }
    refreshBuiltIn()
    // The diagnostics ring's one insertion point for externals: `appeared` and
    // whatever is LEFT in `existing` are exactly this pass's arrivals and
    // departures, already computed above for the controller reconciliation.
    // Recorded here rather than from a second observer, which would have to
    // re-derive the same difference and could disagree with it.
    for state in appeared { noteDisplayEvent("\(state.display.name) arrived") }
    // From the plan, so a panel REPLACED on a still-live ID is announced as
    // leaving. Reading "whatever is left in `existing`" cannot see that one: its
    // ID is still occupied, so the ring would show an arrival with no departure
    // and the old panel's HUD would outlive it.
    for state in plan.departed.sorted().compactMap({ existing[$0] }) {
      noteDisplayEvent("\(state.display.name) departed")
    }
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
      // The mute companion's D24 gate, one register over from the slider's.
      // Re-pointed on every pass for the same reason the epoch pair is: a kept
      // controller can be looking at a panel that is not the one it saw last
      // pass, and this verdict is keyed by persistence key. Read through a
      // closure so a probe landing after this pass still decides the next
      // mute, and so there is exactly one copy of the verdict.
      let muteKey = state.display.persistenceKey
      state.volume.setMuteWireSupport { [weak self] in
        self?.muteSupport[muteKey] ?? .unknown
      }
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
    muteSupport = muteSupport.filter { live.contains($0.key) }
    // Same rule, same reason: a replug hands out a fresh IOAVService, so an old
    // answer is not evidence about the new wire.
    capabilityString = capabilityString.filter { live.contains($0.key) }
    hardwareFacts = hardwareFacts.filter { live.contains($0.key) }
    probeVolumeCapabilities()
    // Includes an ID whose panel was REPLACED: the HUD this returns to clean up
    // belongs to the monitor that left, and the one now on that ID gets its own
    // on the next keypress.
    return Array(plan.departed)
  }

  /// Reconciles the built-in slot against discovery. Same identity rule as
  /// externals: a still-present built-in keeps its controller (fresh
  /// DisplayState for the name); no writer rebind — there is no DDC wire, the
  /// writer is a permanent `NoopDDCWriter`.
  private func refreshBuiltIn() {
    guard let found = BuiltInDisplayDiscovery.discover() else {
      // Clamshell is a real churn source and the ring would otherwise show the
      // externals renegotiating around a departure it never mentioned.
      if let departed = builtIn { noteDisplayEvent("\(departed.display.name) departed") }
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
    noteDisplayEvent("\(display.name) arrived")
    // Inert value controllers: the built-in has no DDC wire, so their
    // `isAvailable` stays true but every write no-ops on `NoopDDCWriter`.
    // Nothing renders them (the panel shows volume/contrast for `displays`
    // only); they exist so `DisplayState` has one shape for both slots, and so
    // the brightness controller's wire is named here the same way it is for an
    // external. It has no HDR backend, so nothing ever asks it to invalidate.
    let volume = DDCValueController(
      writer: NoopDDCWriter(), command: .volume,
      prefs: DisplayPrefs(persistenceKey: "builtIn")
    )
    let contrast = DDCValueController(
      writer: NoopDDCWriter(), command: .contrast,
      prefs: DisplayPrefs(persistenceKey: "builtIn")
    )
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
      mirrorTopology: mirrorTopology,
      wireSiblings: [volume, contrast]
    )
    builtIn = DisplayState(
      display: display, controller: controller,
      volume: volume,
      contrast: contrast,
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
            // Not while a reset is running. A reset drives this display's
            // hardware and then waits for its queue to go quiet before letting
            // HDR back on, and sync is the one writer that submits on somebody
            // ELSE's schedule: a built-in ramping under ambient light, or a
            // Control Center drag, fans a write onto this display every poll
            // tick, so the queue never goes quiet and the reset gives up on
            // restoring the display's HDR.
            //
            // The movement made during the reset is DROPPED, not deferred: a
            // disabled fan-out resets the deadband and returns, so the externals
            // stay offset by however far the source moved in those few seconds.
            // That is the documented meaning of the pref being off, applied for
            // the duration rather than a new behaviour, and it is the cheaper
            // of the two losses on offer.
            BrightnessSync.fanOut(
              delta: delta,
              from: controller,
              to: self.allControlledStates.map(\.controller),
              isEnabled: self.appPrefs.enableBrightnessSync && !self.isResetting
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
