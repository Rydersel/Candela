import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import Observation
import os

/// OLED care: the idle/blackout timers, the care dim and the hours tracker.
///
/// Owned by `AppModel` for `DisplayModeCoordinator`'s reason: the timers must
/// outlive whatever window or pane started them. Unlike the sibling
/// coordinators it takes no dependencies at init — `start(model:)` hands it the
/// model once, held weakly, and everything else is resolved fresh per tick.
///
/// Shape rules this type is built around, each measured or ruled during W3a:
///
/// - **Everything is keyed by `persistenceKey`, never `CGDirectDisplayID`.**
///   IDs reassign across a dock cycle with both displays still present
///   (MAG 3→2, Dell 2→3), so the ID→key resolution happens fresh on every tick
///   and an ID is only ever a rendering address.
/// - **OC12, verified on the window server's side and on a LATER tick.** The
///   server lags AppKit by a run-loop turn in BOTH directions (measured
///   ~6–9 ms), so verifying inline after a mutation reads the pre-mutation
///   world. A render that changed state marks the display and the FOLLOWING
///   tick checks `verifyPresence`; the reconcile lever is `reassert(on:)`,
///   never a repeat `apply` — an unchanged apply is a no-op by construction.
/// - **On any reconfiguration: tear down and re-render, never repin.**
///   `repinFrames()` alone would pin an overlay to the wrong panel after an ID
///   swap. `displaysReconfigured()` calls `removeAll()` and the next render
///   recreates every wanted overlay under the fresh IDs.
/// - **OC13: a mirror-set participant is `suspended`** — overlay removed,
///   engine paused (it returns `.suspended` while the signal holds), hours not
///   accumulated. Membership comes from the app's one mirror definition,
///   `MirrorTopologyStore`/`MirrorTopology.isInMirrorSet`, master included.
/// - **Safe Mode builds `chrome` and nothing else** (spec §7): chrome toggles
///   are explicit user actions on system settings, not automatic behavior, so
///   they stay functional; the driver loop — overlays, sampling, hours — never
///   starts.
/// - **W3b-1 telemetry rides the same loop at its own 60 s cadence**, and takes
///   its suspension verdict from the dimming engine's published state rather
///   than re-deriving one. `samplingQualifies(dimState:on:)` is the whole of
///   that decision.
@MainActor
@Observable
final class OledCareCoordinator {
  /// The latest engine state per enrolled display, by persistenceKey. The
  /// pane's per-display section reads this ("paused while mirrored", etc.).
  private(set) var dimStates: [String: OledDimState] = [:]

  /// Built unconditionally in `start(model:)` — including Safe Mode — so the
  /// pane's global toggles always reflect real system state. Nil only before
  /// launch wiring runs.
  private(set) var chrome: ChromeAutoHideController?

  /// Why a locked display was not dimmed, by persistenceKey. Present ONLY while
  /// the display is locked and the dim was refused: a stale entry would be a
  /// sentence about a state the machine is no longer in.
  ///
  /// Read by both surfaces that report lock dim, through `OledCareCopy` (the
  /// OLED Care pane's status row and the display hub's care preview). OC7
  /// sub-ruling 4 is "recorded, never reported as dimmed", and a record no
  /// surface reads satisfies only the first half.
  private(set) var lockDimSkips: [String: LockDimSkip] = [:]

  private struct PerDisplay {
    var engine: IdleDimmingEngine
    /// Cached from prefs (refreshed by `reconcileEnrollment`) so the tick can
    /// decide whether to run the focus sampler without a per-tick prefs read.
    var unfocusedDimEnabled: Bool
    var hoursTracking: Bool
    /// Cached from prefs alongside the others. Telemetry gates the luminance
    /// capture only; window observation is a separate pref because it needs no
    /// permission and is the degraded mode's only data source.
    var telemetryEnabled: Bool
    var windowObservationEnabled: Bool
    /// The ID this display's overlay was last driven under — a rendering
    /// address, never identity. Refreshed from the live display list each tick.
    var lastDisplayID: CGDirectDisplayID?
    /// What we last asked the window server for (mirrors the overlay's own
    /// applied state). nil = no overlay wanted. This is what OC12 verifies.
    var lastAppliedAlpha: Double?
    var lastAppliedBlackout = false
    var lastAppliedMask: OverlayMask.Oriented?
    /// #20. Off by default, so an enrolled display that never opts in pays
    /// nothing past the flag test in `render`.
    var detectionDimmingEnabled = false
    /// The current nomination in PANEL space, recomputed only when a new
    /// luminance sample lands. Nil means "nothing qualifies", which is
    /// deliberately distinguishable from an all-zero mask: the render then
    /// skips the mask path entirely and keeps the cheaper scalar one.
    var nominatedMask: OverlayMask?
    /// OC12: the last render mutated window-server state; verify it on a
    /// LATER tick than the one that mutated.
    var needsVerify = false
    /// Reconcile attempts against the CURRENT mismatch; zeroed on every new
    /// mutation and on success. Bounds the OC12 loop — see `maxVerifyAttempts`.
    var verifyAttempts = 0
    var wasAwake = true
    var hoursLastTick: SuspendingClock.Instant?
    /// When this display lost focus (nil = focused, or no focus data yet).
    /// This coordinator owns the unfocused clock; `FocusSampler` only answers
    /// "which display holds the front window right now".
    var unfocusedSince: SuspendingClock.Instant?
    /// When `isHDRSettling` was first observed true, continuously. The latch
    /// in `BrightnessController` has no timeout on its clear path, so a
    /// dropped transition would otherwise disable dim entry for the session.
    var hdrSettlingSince: SuspendingClock.Instant?
    /// Start of the last telemetry slot this display took. ONE clock drives
    /// both halves — spec §4 schedules window observation on the sampling
    /// clock — so a display can never be sampled and observed on drifting
    /// cadences that each pay their own cost.
    var lastSampleAt: SuspendingClock.Instant?
    /// A capture is out on the XPC round trip. Nothing else may issue one: two
    /// in flight would double-book the interval they both stand for.
    var sampleInFlight = false
    /// Mirror-set membership as of the last tick, for OC13's entry EDGE. The
    /// steady state is already handled (a mirrored display never qualifies);
    /// this exists so the observer's ageing state is dropped exactly once,
    /// when the panel stops showing what those ages describe.
    var wasMirrored = false
    /// Whether THIS coordinator has a temporary dim outstanding on the
    /// display's controller. Tracked here rather than read back off the
    /// controller so the disengage is driven by what we engaged, and a dim some
    /// future caller owns is never ended on our behalf.
    var lockDimEngaged = false
    /// The dim-in fade, while it is still running. Cancelled by every path that
    /// ends the dim. Cancellation is the tidy half only: `endTemporaryDim`
    /// supersedes an in-flight ramp by token, so a step already suspended when
    /// the user unlocked cannot land after the restore even if this were nil.
    var lockDimRamp: Task<Void, Never>?
  }

  /// Poll cadence: slow while every enrolled display is `.active`/`.suspended`;
  /// fast while any dim is up by any delivery (restore latency gate is 100 ms,
  /// #21) or an OC12 verification is pending. The predicate and both durations
  /// live in `OledCareCadence`, under test.
  /// After this much CONTINUOUS settling the signal is ignored: the entry gate
  /// exists for a transition window measured in seconds, not for a latch that
  /// never cleared.
  private static let hdrSettleDeferralBound: Duration = .seconds(10)
  /// OC12 reconcile bound ("log, don't loop" needs an actual number): at the
  /// fast cadence five attempts is ~500 ms — dozens of run-loop turns against
  /// a measured 6–9 ms server lag — so a mismatch still standing is structural
  /// (a departing display, a shield above us), and retrying forever would pin
  /// the fast cadence and put an error in the log ten times a second.
  private static let maxVerifyAttempts = 5
  /// Spec §4: one capture per enrolled display per 60 s, and the window list on
  /// the same clock.
  private static let samplingInterval: Duration = .seconds(60)
  /// "At most every few minutes, plus at termination" (spec §4). A defaults
  /// write per sample would put one on a permanent 60 s timer per panel for a
  /// value that is only ever read by a settings view.
  private static let exposurePersistInterval: Duration = .seconds(300)
  @ObservationIgnored private weak var model: AppModel?
  @ObservationIgnored private let overlay = OledOverlay()
  @ObservationIgnored private let lockObserver = LockStateObserver()
  @ObservationIgnored private let focus = FocusSampler()
  /// Keyed by persistenceKey; created lazily and kept for the app's lifetime —
  /// hours are persistent facts about a panel, not about a connection.
  @ObservationIgnored private var trackers: [String: PanelHoursTracker] = [:]
  /// OC20's wear signal, one per panel, keyed and reset exactly like `trackers`
  /// because it measures the same thing about the same glass: how long, and now
  /// also at what level.
  @ObservationIgnored private var wearTrackers: [String: WearSignalTracker] = [:]
  @ObservationIgnored private let sampler = LuminanceSampler()
  /// Accumulated exposure per panel, by persistenceKey, restored from disk on
  /// first touch and kept for the app's lifetime — wear is a fact about a
  /// panel, not about a connection, exactly like `trackers`.
  ///
  /// Observation-tracked, unlike its two neighbours: `healthSummary(for:)`
  /// reads it, so a SwiftUI health view re-renders when a sample lands without
  /// anyone maintaining a revision counter.
  private var accumulators: [String: ExposureAccumulator] = [:]
  /// The most recent window observation per display, for attribution in the
  /// health view. Tracked for the same reason as `accumulators`.
  private var latestObservations: [String: WindowObservation] = [:]
  /// OC18's per-app attribution OVER TIME — panel-seconds each app has
  /// occupied, folded from the same observations `latestObservations` holds the
  /// latest of. Restored on first touch and kept for the app's lifetime,
  /// exactly like `accumulators`, and observation-tracked for the same reason:
  /// `healthSummary(for:)` reads it.
  ///
  /// One instance per key, `hoursTracker(for:)`'s rule: two live accumulators
  /// double-book every observation, and this is persisted, so the bias never
  /// washes out.
  private var ownerHours: [String: OwnerHoursAccumulator] = [:]
  /// The ageing half of window observation. `WindowObserver.observe` is
  /// MUTATING on a value type, so this must be mutated in place — a `let` copy
  /// discards every window's age on return and the stationary threshold could
  /// then never be reached. Not observation-tracked: nothing renders it, only
  /// the `WindowObservation` it produces.
  @ObservationIgnored private var observers: [String: WindowObserver] = [:]
  /// Displays whose accumulated map has changed since the last write-through.
  @ObservationIgnored private var unsavedExposureKeys: Set<String> = []
  /// Keys whose stored wear history this build could not interpret but which
  /// are NOT junk: a newer schema, or a different `PanelGrid`. Nothing is
  /// written back for them, so a later build can still migrate the bytes.
  /// Cleared only by the user's own delete, which is the one action that means
  /// "I do not want this history".
  @ObservationIgnored private var unwritableExposureKeys: Set<String> = []
  @ObservationIgnored private var lastExposurePersist: SuspendingClock.Instant?
  /// Bumped by anything that destroys accumulated exposure. A capture issued
  /// before the bump lands after it, and would otherwise re-book an interval
  /// into a map the user just deleted; comparing the epoch makes that
  /// impossible rather than unlikely.
  @ObservationIgnored private var exposureEpoch = 0
  /// Per enrolled-and-connected display, by persistenceKey.
  @ObservationIgnored private var states: [String: PerDisplay] = [:]
  @ObservationIgnored private var driver: Task<Void, Never>?
  @ObservationIgnored private var sleepWakeObservers: [any NSObjectProtocol] = []
  /// C1 latch. `runSettingsReset` suspends several times between
  /// `prepareForReset()` and the domain wipe, and an HDR-off IS a display
  /// reconfiguration — so the topology loop can fire mid-reset and would
  /// re-read still-unwiped enrollment prefs and re-arm the very overlays the
  /// reset just tore down. While this is up, `tick()`, `displaysReconfigured()`
  /// and `reapplyAfterPrefChange()` are all no-ops; only `resetDidComplete()`
  /// clears it.
  @ObservationIgnored private var resetting = false
  /// OC12 for removals issued OUTSIDE the per-display tick (reset,
  /// un-enrollment), whose per-display state — the thing that would carry the
  /// marker — is deleted in the same breath. Keyed by the ID the window was
  /// closed under (current at issue time); value = attempts so far. Drained by
  /// the tick independently of `states`, so a close the server ignored still
  /// gets re-closed on a later turn instead of becoming an unwatched
  /// full-black window whose prefs were just wiped.
  @ObservationIgnored private var pendingRemovalVerifications: [CGDirectDisplayID: Int] = [:]
  @ObservationIgnored private let log = Logger(
    subsystem: "com.rydersel.Candela", category: "oledcare"
  )

  /// Reachable: the driver binds `self` strongly only inside the
  /// non-suspending half of each iteration, so the task never retains this
  /// object across a sleep and cannot keep it alive. The cancel ends the loop
  /// at its next check rather than leaving it waking every cadence to find a
  /// nil weak self. The notification tokens are not unregistered here (not
  /// `Sendable`, so a nonisolated deinit cannot touch them) —
  /// sibling-coordinator precedent: the blocks capture weakly.
  deinit {
    driver?.cancel()
  }

  // MARK: - Lifecycle

  /// Called once from `applicationDidFinishLaunching`. Safe Mode (spec §7)
  /// suppresses the driver loop — no overlays, no sampling, no hours — but the
  /// chrome controller is still built: its toggles are explicit user actions.
  func start(model: AppModel) {
    guard chrome == nil else { return }
    self.model = model
    chrome = ChromeAutoHideController(writer: SystemChromeWriter())
    guard !model.isSafeMode else { return }

    // Everything below the Safe Mode guard above is what Safe Mode suppresses,
    // and lock dim rides that gate rather than carrying one of its own: no lock
    // observer is registered, so no tick ever reaches `.lockDim` and no
    // brightness is written on our behalf in a safe-mode session (spec section 7).
    lockObserver.onLock = { [weak self] in
      guard let self else { return }
      // Read once and hand the same baseline to every engine: the lock action
      // itself is input, and the engines must not read its falling idle counter
      // as input that arrived after the lock.
      let idleAtLock = OledCareSignalSources.systemIdleSeconds()
      for key in states.keys { states[key]?.engine.noteLock(idleSeconds: idleAtLock) }
      tick()
    }
    lockObserver.onUnlock = { [weak self] in
      guard let self else { return }
      for key in states.keys { states[key]?.engine.noteUnlock() }
      tick()
    }
    lockObserver.start()

    // queue: nil, matching the app's own sleep observers at the wiring site
    // (StatusItemController.swift:265): the block then runs SYNCHRONOUSLY at
    // post time, inside AppKit's bounded pre-sleep window. A `.main`-queued
    // operation is merely ENQUEUED, and can land after the wake — tearing
    // overlays down into a machine that already slept and booking the standby
    // edge on the wrong side of it. AppKit posts these on the main thread;
    // `assumeIsolated` asserts (and would trap on) exactly that — the same
    // documented trade as the KVO observer at StatusItemController.swift:225.
    let center = NSWorkspace.shared.notificationCenter
    sleepWakeObservers.append(center.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.systemWillSleep() }
    })
    sleepWakeObservers.append(center.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.systemDidWake() }
    })

    // Spec §4's "plus at termination" half. Registered here rather than added
    // to `StatusItemController.applicationWillTerminate` because this object
    // owns the maps and nothing outside it knows they are dirty; `queue: nil`
    // for the sleep observers' reason — the block must run synchronously at
    // post time, and an enqueued one would land after the process is gone.
    sleepWakeObservers.append(NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: nil
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.flushExposureHistory() }
    })

    reconcileEnrollment()
    // start() is single-shot (the chrome guard above), so there is never a
    // previous driver to cancel here.
    driver = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        // Strong self is confined to the non-suspending half of the
        // iteration and dropped BEFORE the sleep: a guard binding whose scope
        // covered the await would have the task retain self across every
        // suspension — a cycle that defeats [weak self], makes deinit
        // unreachable and turns its cancel into dead code.
        let interval: Duration
        do {
          guard let self else { return }
          self.tick()
          interval = self.cadence()
        }
        try? await Task.sleep(for: interval)
      }
    }
  }

  /// The pane's accessor, and the only door to a display's hours (Task 3
  /// carry-in: never construct a second tracker for a key this one holds — two
  /// live trackers double-book every tick).
  func hoursTracker(for persistenceKey: String) -> PanelHoursTracker {
    if let existing = trackers[persistenceKey] { return existing }
    let tracker = PanelHoursTracker(persistenceKey: persistenceKey)
    trackers[persistenceKey] = tracker
    return tracker
  }

  /// Same single-instance rule as `hoursTracker`, for the same reason: two live
  /// trackers over one key double-book every tick, and this one feeds a
  /// multi-week soak where a 2× error is indistinguishable from a real result.
  func wearTracker(for persistenceKey: String) -> WearSignalTracker {
    if let existing = wearTrackers[persistenceKey] { return existing }
    let tracker = WearSignalTracker(persistenceKey: persistenceKey)
    wearTrackers[persistenceKey] = tracker
    return tracker
  }

  /// The proxy OC20 accumulates against: the fraction of full output the panel
  /// is left at, composing the overlay's retained fraction with the brightness
  /// setting.
  ///
  /// `.lockDim` reads its factor explicitly rather than through `alpha(for:)`,
  /// which answers nil there by design: the lock dim is delivered on the wire
  /// and deliberately never writes `controller.brightness` or the store, so the
  /// controller reports the user's own setting for the whole locked span. Using
  /// the alpha path would book every locked hour at full brightness.
  ///
  /// Reasoned, not measured. It ignores the panel's EOTF and any local dimming,
  /// which is why OC20 also stores the dim-state axis as an independent,
  /// model-free answer to OC17's gate.
  static func effectiveLevel(
    state: OledDimState, engine: IdleDimmingEngine, brightness: Double
  ) -> Double {
    guard brightness.isFinite else { return 0 }
    switch state {
    case .blackout: return 0
    case .lockDim: return brightness * engine.lockDimFactor
    case .idleDim, .unfocusedDim:
      // `alpha` is how much we cover the panel with; what is left is its
      // complement, which is the config's own "how bright it is LEFT" number.
      return brightness * (1 - (engine.alpha(for: state) ?? 0))
    case .active, .suspended: return brightness
    }
  }

  /// The health view's one door (W3b-1 Task 9). Safe for a display that is not
  /// enrolled, not connected, or has never been sampled: the map is restored
  /// from disk on first touch and `.empty` answers everything honestly.
  ///
  /// Telemetry is read from the cached enrollment state when there is one and
  /// from prefs otherwise, so a disconnected panel's history still reports the
  /// confidence it was recorded under rather than defaulting to `.estimated`.
  ///
  /// Deliberately does NOT memoise either store it may have to load: this is
  /// called from a SwiftUI body, and populating an observation-tracked
  /// dictionary there is a state mutation during view update. Reading them
  /// still registers the dependency, so the view refreshes when a sample lands;
  /// until one does, the cost is decoding 240 doubles and a small dictionary.
  func healthSummary(for persistenceKey: String) -> PanelHealthSummary {
    let map = accumulators[persistenceKey]?.map ?? loadExposureMap(for: persistenceKey)
    let owners = ownerHours[persistenceKey]?.hours ?? loadOwnerHours(for: persistenceKey)
    let prefs = DisplayPrefs(persistenceKey: persistenceKey)
    let telemetry = states[persistenceKey]?.telemetryEnabled ?? prefs.oledTelemetry
    let observing = states[persistenceKey]?.windowObservationEnabled
      ?? prefs.oledWindowObservation
    return PanelHealthSummary.make(
      map: map,
      observation: latestObservations[persistenceKey],
      ownerHours: owners,
      telemetryEnabled: telemetry,
      observationEnabled: observing)
  }

  /// The health view's delete action: the accumulated exposure map, the
  /// per-app panel-seconds, and the window attribution derived from them,
  /// cleared in one step, in memory and on disk.
  ///
  /// The panel's TOTAL HOURS are deliberately NOT cleared. They are a different
  /// measurement with its own reset path (`PanelHoursTracker.reset()`, driven
  /// by the settings reset), and a control labelled for exposure history must
  /// not silently destroy a lifetime counter. Per-app hours ARE cleared: they
  /// are derived from the same observations as the map, and leaving them would
  /// let the health view keep naming apps for a history the user just deleted.
  func clearExposureHistory(for persistenceKey: String) {
    exposureEpoch += 1
    accumulators[persistenceKey] = ExposureAccumulator()
    ownerHours[persistenceKey] = OwnerHoursAccumulator()
    forgetWindowObservation(for: persistenceKey)
    unsavedExposureKeys.remove(persistenceKey)
    // The bytes were held back precisely because destroying them was not the
    // user's call. It is now.
    unwritableExposureKeys.remove(persistenceKey)
    UserDefaults.standard.removeObject(forKey: Self.exposureKeyName(persistenceKey))
    UserDefaults.standard.removeObject(forKey: Self.ownerHoursKeyName(persistenceKey))
  }

  // MARK: - Entry points

  /// D28 shape: synchronous, main-actor, the ONLY pref entry point. Rebuilds
  /// each enrolled display's config from prefs; a display whose enrollment
  /// turned off loses its overlay and its engine. `persistenceKey` scoping is
  /// deliberately not exploited — the reconcile walks the whole (small)
  /// display list either way, and `updateConfig` from prefs is idempotent.
  func reapplyAfterPrefChange(persistenceKey _: String?) {
    guard let model, !model.isSafeMode, !resetting else { return }
    reconcileEnrollment()
    if driver != nil { tick() }
  }

  /// The topology loop's hook. IDs may have been REASSIGNED even with both
  /// displays still present, so the response is teardown + re-render from
  /// state under freshly resolved IDs — never `repinFrames()` alone, which
  /// would pin an overlay to the wrong panel.
  func displaysReconfigured() {
    guard let model, !model.isSafeMode, !resetting else { return }
    clearAllOverlays()
    // Old IDs may already name different panels, so pending removal checks
    // keyed on them would ask the wrong question (the verifyRemoval rationale
    // below); the removeAll above re-closed every window we hold anyway.
    pendingRemovalVerifications = [:]
    // The sampler's held resolution is a raw ID and a reassigned ID is still
    // online, so liveness checks can't save it — drop it and let the next
    // resolve re-seed.
    focus.invalidate()
    reconcileEnrollment()
    if driver != nil { tick() }
  }

  /// D29 ordering, first statement of the reset path: overlays down and hour
  /// counters reset while their objects are alive. The domain wipe never
  /// reaches the trackers (rebuildControllers doesn't touch this object), so
  /// a live tracker's debounced write-through would otherwise re-persist the
  /// hours the user just cleared. Raises the `resetting` latch; the caller
  /// MUST pair this with `resetDidComplete()` after the wipe.
  func prepareForReset() {
    resetting = true
    // Before the state below is discarded, and before the domain is wiped: a
    // reset that clears the OLED prefs must not leave a display sitting at a
    // dim level whose owner it just deleted (the D29 ordering rule, in the
    // brightness register instead of the mute one).
    //
    // This runs FIRST of the two blocks. Both must precede the wipe and they
    // are independent, but only this one leaves the panel visibly wrong if it
    // is skipped; the telemetry teardown below is bookkeeping. Recovery before
    // bookkeeping, the same ordering D29 states for the mute strand.
    endAllLockDims()
    // Sampling stops BEFORE the prefs are wiped, never after (D29's ordering
    // applied to this path). The domain wipe removes the exposure keys, so a
    // live accumulator surviving it would write the deleted map back on its
    // next debounce — the same defect the tracker reset below prevents for
    // hours. The epoch bump does the same for a capture already in flight,
    // which would otherwise land in a fresh map after the wipe.
    exposureEpoch += 1
    unsavedExposureKeys.removeAll()
    // The wipe removes the stored bytes the quarantine existed to protect, so
    // holding the flag past it would leave a display recording nothing forever
    // over a file that is already gone.
    unwritableExposureKeys.removeAll()
    accumulators.removeAll()
    ownerHours.removeAll()
    observers.removeAll()
    latestObservations.removeAll()
    // These removals delete the per-display state that would carry their OC12
    // marker, so verification rides the pending list instead: a blackout
    // window whose close the server ignores must not become unwatched at the
    // exact moment the prefs describing it are wiped (spec §7's prohibition).
    // IDs are current — no reconfiguration has occurred.
    for state in states.values {
      if let id = state.lastDisplayID, state.lastAppliedAlpha != nil {
        pendingRemovalVerifications[id] = 0
      }
    }
    clearAllOverlays()
    states = [:]
    dimStates = [:]
    for tracker in trackers.values { tracker.reset() }
    // Same reason, same moment: a live wear tracker's debounced write-through
    // would re-persist the histogram the wipe just removed.
    for tracker in wearTrackers.values { tracker.reset() }
  }

  /// The post-wipe half of the reset contract (paired with
  /// `prepareForReset()`): clears the latch and re-derives membership from the
  /// wiped domain. Without this, OLED care after a reset was only correct by
  /// the accident of no topology event landing mid-reset — the latch swallows
  /// those events, so somebody must reconcile once the wipe is real.
  func resetDidComplete() {
    resetting = false
    guard let model, !model.isSafeMode else { return }
    reconcileEnrollment()
    if driver != nil { tick() }
  }

  // MARK: - Sleep / wake

  private func systemWillSleep() {
    // IDs are stable across a plain system sleep, so the removal IS verified
    // (first post-wake ticks re-check); contrast displaysReconfigured, where
    // the old IDs may already name different panels.
    clearAllOverlays(verifyRemoval: true)
    // Gated per display like every passive standby edge: an opted-out display
    // must not have hours keys written — or its note dismissal cleared — by a
    // standby it never accumulated toward.
    for (key, state) in states where state.hoursTracking {
      hoursTracker(for: key).noteStandby()
    }
    // Sleep is the one edge where the process can stop existing without a
    // termination notification (a battery that runs out in the bag), so the
    // debounced maps go down with it rather than up to five minutes of history.
    flushExposureHistory()
  }

  private func systemDidWake() {
    // noteWake, never a rebuilt engine: a rebuilt engine has no idle floor and
    // would re-dim on the stale system idle counter — the exact defect the
    // floor exists to prevent.
    for key in states.keys { states[key]?.engine.noteWake() }
    tick()
  }

  // MARK: - Enrollment

  /// Rebuilds membership from the live display list and prefs: arrivals get a
  /// fresh `.active` engine, still-present displays get their config re-read,
  /// un-enrolled and departed displays lose overlay + engine (departures also
  /// standby their tracker — the panel stopped being driven).
  private func reconcileEnrollment() {
    guard let model else { return }
    var seen: Set<String> = []
    for displayState in model.displays {
      let key = displayState.display.persistenceKey
      seen.insert(key)
      let prefs = DisplayPrefs(persistenceKey: key)
      guard prefs.oledCareEnrolled else {
        dropState(for: key)
        continue
      }
      let config = OledDimConfig(prefs: prefs)
      if var existing = states[key] {
        existing.engine.updateConfig(config)
        existing.unfocusedDimEnabled = prefs.oledUnfocusedDimEnabled
        let tracking = prefs.oledHoursTracking
        if tracking, !existing.hoursTracking {
          // Tracking turned back ON: the since-standby counter froze during
          // the untracked period, and the 8-hour note must not later believe
          // it. noteStandby(), deliberately NOT reset(): reset would also
          // destroy the lifetime total — persistent wear data the user did
          // not ask to clear — while noteStandby zeroes exactly the counter
          // the note reads (and re-arms the note, which a fresh baseline has
          // earned).
          hoursTracker(for: key).noteStandby()
        }
        existing.hoursTracking = tracking
        existing.telemetryEnabled = prefs.oledTelemetry
        existing.windowObservationEnabled = prefs.oledWindowObservation
        // Turning #20 off must drop the nomination, not merely stop consulting
        // it. A retained mask would come straight back on the next re-enable
        // built from a screen the user has since changed, and until then it
        // would sit in the state as a live-looking value nothing updates: the
        // same shape as the stale `hottestOwner` this wave already had to fix.
        existing.detectionDimmingEnabled = prefs.oledDetectionDimming
        if !existing.detectionDimmingEnabled { existing.nominatedMask = nil }
        states[key] = existing
      } else {
        states[key] = PerDisplay(
          engine: IdleDimmingEngine(config: config),
          unfocusedDimEnabled: prefs.oledUnfocusedDimEnabled,
          hoursTracking: prefs.oledHoursTracking,
          telemetryEnabled: prefs.oledTelemetry,
          windowObservationEnabled: prefs.oledWindowObservation,
          lastDisplayID: displayState.id,
          detectionDimmingEnabled: prefs.oledDetectionDimming
        )
      }
    }
    for key in Array(states.keys) where !seen.contains(key) {
      // Standby gated on the pref like every passive edge (a lazily created
      // tracker writing zeros for an opted-out display is exactly the key
      // pollution the gate exists to stop).
      if states[key]?.hoursTracking == true {
        hoursTracker(for: key).noteStandby()
      }
      dropState(for: key)
    }
  }

  private func dropState(for key: String) {
    guard var state = states.removeValue(forKey: key) else { return }
    // Un-enrollment is the case that matters here: the display is still
    // connected, and dropping the state that remembers the dim without ending
    // it would strand the panel dark with nothing left to restore it. A display
    // that has actually departed has no controller to write to; its stored
    // brightness was never touched, so the next arrival's restore pass is what
    // puts it back.
    if let controller = model?.displays.first(
      where: { $0.display.persistenceKey == key }
    )?.controller {
      endLockDim(&state, on: controller)
    }
    clearSkip(for: key)
    if let id = state.lastDisplayID {
      overlay.remove(for: id)
      // This removal deletes the state that would carry its OC12 marker, so
      // the verification rides the pending list — queued only when an overlay
      // was actually up, under an ID that was current when the window was
      // driven (un-enrollment is not a reconfiguration; the reconfiguration
      // path clears its overlays and this list BEFORE reconciling).
      if state.lastAppliedAlpha != nil {
        pendingRemovalVerifications[id] = 0
      }
    }
    dimStates.removeValue(forKey: key)
    // Window ages describe how long a rect has been where it is ON THIS PANEL,
    // so a departure or an un-enrollment invalidates them for the same reason
    // mirroring does. Both ACCUMULATORS stay — the exposure map and the
    // per-app panel-seconds are wear data about the glass, and the panel comes
    // back. Written through first: a dock cycle must not cost up to a debounce
    // interval of history.
    forgetWindowObservation(for: key)
    saveExposureHistory(for: key)
  }

  // MARK: - The tick

  private func tick() {
    guard let model, !resetting else { return }
    // Drained independently of `states` — these entries outlive the state
    // that issued them by design (I-2), including across a reset.
    drainPendingRemovalVerifications()
    // Users who never enroll pay nothing past this line.
    guard !states.isEmpty else { return }
    let idleSeconds = OledCareSignalSources.systemIdleSeconds()
    let assertionHeld = OledCareSignalSources.displaySleepAssertionHeld()
    let isLocked = lockObserver.isLocked
    let topology = model.mirrorTopology.topology()
    let now = SuspendingClock.now
    // Focus is sampled only when some enrolled display wants unfocused dim
    // (spec §3), at whatever cadence the loop is running — which IS the
    // overlay-up cadence whenever an overlay is up, satisfying the "a clicked
    // display must not stay dimmed for seconds" rule. 0.46 ms per call
    // [MEASURED], well under 1% of a core at 10 Hz.
    let anyUnfocusedEnabled = states.values.contains(where: \.unfocusedDimEnabled)
    let focusedDisplay = anyUnfocusedEnabled ? focus.focusedDisplayID() : nil
    // ID → key resolved fresh every tick; IDs reassign and are never cached
    // as identity. Uniquing defensively: two identical panels can collide on
    // persistenceKey, and a crash would be worse than one of them winning.
    let live = Dictionary(
      model.displays.map { ($0.display.persistenceKey, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var published = dimStates

    for key in Array(states.keys) {
      guard var state = states[key] else { continue }
      guard let displayState = live[key] else {
        // Departed but not yet reconciled (the topology loop debounces ~1 s).
        // Nothing to render against; reconcileEnrollment owns the teardown.
        // The published entry goes NOW — the pane must not keep reading a
        // stale .idleDim/.blackout for a display that is gone.
        published.removeValue(forKey: key)
        continue
      }
      let id = displayState.id
      state.lastDisplayID = id
      let isMirrored = topology.displays.first { $0.id == id }?.isInMirrorSet ?? false

      // The settle latch is unbounded in BrightnessController; bound the
      // deferral here so a dropped clear cannot disable dimming all session.
      var hdrSettling = displayState.controller.isHDRSettling
      if hdrSettling {
        let since = state.hdrSettlingSince ?? now
        state.hdrSettlingSince = since
        if now - since > Self.hdrSettleDeferralBound { hdrSettling = false }
      } else {
        state.hdrSettlingSince = nil
      }

      // The unfocused clock: cleared ONLY by a focus visit to THIS display;
      // started when some other display holds focus. A nil sample (before the
      // first resolve, or right after invalidate()) HOLDS the clock unchanged
      // — the consumer half of FocusSampler's hold-last contract. Zeroing it
      // on nil would drop a live unfocused dim on a transient resolve failure
      // (Spotlight frontmost, a Space transition — exactly the cases
      // hold-last exists for) and not bring it back for a full threshold.
      var unfocusedSeconds: Double?
      if state.unfocusedDimEnabled {
        if let focusedDisplay {
          if focusedDisplay == id {
            state.unfocusedSince = nil
          } else if state.unfocusedSince == nil {
            state.unfocusedSince = now
          }
        }
        if let since = state.unfocusedSince {
          unfocusedSeconds = Self.seconds(now - since)
        }
      } else {
        state.unfocusedSince = nil
      }

      let newState = state.engine.tick(OledDimSignals(
        idleSeconds: idleSeconds,
        assertionHeld: assertionHeld,
        isLocked: isLocked,
        isMirrored: isMirrored,
        isHDRSettling: hdrSettling,
        unfocusedSeconds: unfocusedSeconds
      ))

      // Hours. SuspendingClock, not ContinuousClock: the delta must not book
      // a system-sleep span as awake panel time, and SuspendingClock does not
      // advance while the machine is suspended. Display sleep WITHOUT system
      // sleep is handled by the awake gate — the loop keeps ticking, so the
      // asleep spans contribute no noteTick. Mirrored displays accumulate
      // nothing (OC13: suspended means suspended).
      //
      // Known over-count, documented in the pane's caption rather than fixed
      // (#94): a panel blanked by DPMS keeps reporting
      // `CGDisplayIsAsleep == false`, at full resolution, with no
      // reconfiguration, so hours accrue while it is dark. MEASURED for a DDC
      // `D6 set 4` write. That the monitor's OWN power button reaches that same
      // state is REASONED FROM that measurement, not measured — a press may
      // instead deassert hot-plug detect, which is a real departure and is
      // already handled (reconcileEnrollment -> noteStandby). Monitor-dependent
      // and untested; #23 carries the item. macOS exposes no signal that
      // distinguishes a soft-standby panel, and the one signal Candela used to
      // have (its own 0xD6 write) went with the power-off action.
      let awake = CGDisplayIsAsleep(id) == 0
      if state.hoursTracking {
        if state.wasAwake, !awake { hoursTracker(for: key).noteStandby() }
        if awake, !isMirrored, let last = state.hoursLastTick {
          let elapsed = Self.seconds(now - last)
          hoursTracker(for: key).noteTick(
            displayAwake: true, secondsSinceLastTick: elapsed
          )
          // OC20 rides the SAME gate and the SAME delta as panel hours, so the
          // two counters cannot disagree about how long a panel was on. That is
          // also why `.suspended` never accumulates here: a mirrored display
          // books nothing in either counter (OC13), and the slot exists only so
          // the on-disk state ordering stays stable.
          wearTracker(for: key).noteTick(
            dimState: newState,
            effectiveLevel: Self.effectiveLevel(
              state: newState, engine: state.engine,
              brightness: displayState.controller.brightness),
            secondsSinceLastTick: elapsed)
        }
      }
      state.wasAwake = awake
      state.hoursLastTick = now

      // OC13's mirror-entry edge: drop the ageing state once, on the way in.
      if isMirrored, !state.wasMirrored { forgetWindowObservation(for: key) }
      state.wasMirrored = isMirrored
      // Telemetry rides this loop at its own cadence; `newState` is the
      // suspension authority, not a second reading of the same signals.
      updateTelemetry(for: key, state: &state, dimState: newState, on: id, at: now)

      // OC12 ordering: last tick's mutation is verified BEFORE this tick's
      // render, so the check always runs a full tick after the change it is
      // checking — never inline against a window server that lags AppKit by a
      // run-loop turn in both directions. Bounded (I-1): one nudge per
      // detected mismatch, and after maxVerifyAttempts of them the marker is
      // dropped with ONE summary log — a mismatch that survives ~500 ms of
      // retries is structural, and the next state change re-arms the check.
      if state.needsVerify {
        if verifyLastRender(of: state, on: id) {
          state.needsVerify = false
          state.verifyAttempts = 0
        } else if state.verifyAttempts + 1 >= Self.maxVerifyAttempts {
          state.needsVerify = false
          state.verifyAttempts = 0
          log.error("""
          OLED care overlay for display \(id, privacy: .public) still mismatched after \
          \(Self.maxVerifyAttempts, privacy: .public) reconcile attempts; giving up until the next state change
          """)
        } else {
          state.verifyAttempts += 1
        }
      }
      deliverLockDim(newState, into: &state, for: key, on: displayState)
      render(newState, into: &state, on: id)

      states[key] = state
      published[key] = newState
    }
    // Assigned only on change: @Observable notifies on every set and this
    // runs at up to 10 Hz.
    if published != dimStates { dimStates = published }
  }

  /// A given-up verify drops the fast cadence only when nothing is wanted (the
  /// strand case); a wanted dim keeps it, whichever way it is delivered.
  private func cadence() -> Duration {
    OledCareCadence.interval(
      anyOverlayUp: states.values.contains { $0.lastAppliedAlpha != nil },
      anyLockDimEngaged: states.values.contains(where: \.lockDimEngaged),
      verificationPending: states.values.contains(where: \.needsVerify)
        || !pendingRemovalVerifications.isEmpty
    )
  }

  // MARK: - Lock dim (delivered on the wire, not by an overlay)

  /// THE lock-dim funnel: every engage and disengage in this type goes through
  /// here, and `.lockDim` is the only state that engages one.
  ///
  /// Delivery is a hardware dim because an overlay cannot do this job:
  /// MEASURED 2026-08-07, a `CGShieldingWindowLevel()` window does not render
  /// above the lock screen, and it reports itself on screen while it is
  /// covered. The write goes through `BrightnessController`, so it inherits the
  /// one DDC writer, the coalescer's pacing, path selection (an HDR display
  /// dims natively, since live HDR locks the DDC brightness register) and the
  /// poller's echo suppression. It never touches `brightness` or the store, so
  /// the restore is the user's own value by construction rather than by a copy
  /// this object would have to keep correct.
  private func deliverLockDim(
    _ dimState: OledDimState, into state: inout PerDisplay,
    for key: String, on displayState: AppModel.DisplayState
  ) {
    guard dimState == .lockDim else {
      endLockDim(&state, on: displayState.controller)
      clearSkip(for: key)
      return
    }
    let controller = displayState.controller
    // Re-asserted every tick rather than engaged once on the edge, and the
    // scope of what that buys is worth stating exactly, because a comment that
    // claims more than the code enforces is its own defect:
    //
    // - It DOES cover a display that got a REBUILT controller under it while
    //   locked (a reconfiguration reuses controllers, a replug does not). The
    //   fresh controller has no factor, so `beginTemporaryDim` applies.
    // - It does NOT, and cannot, repair a controller that still holds the dim
    //   but re-applied a leg from the wrong value: the unchanged-factor guard
    //   makes that call a no-op. That invariant is enforced where it belongs,
    //   inside `BrightnessController` (`applyPaths` takes no argument and every
    //   leg derives from one effective value), not by this loop.
    let decision = LockDimPolicy.decide(
      path: controller.brightnessPath,
      brightness: controller.brightness,
      factor: state.engine.lockDimFactor
    )
    switch decision {
    case let .dim(factor):
      if !state.lockDimEngaged {
        // The lock edge: fade in over ~1.2 s rather than stepping, which is the
        // only place a ramp is wanted. Everything else here jumps.
        state.lockDimRamp = controller.rampTemporaryDim(to: factor)
        state.lockDimEngaged = true
      } else if controller.temporaryDimFactor == nil {
        // Already engaged as far as this object knows, yet the controller holds
        // no dim: it was REBUILT under a still-connected display (a replug
        // rebuilds; a reconfiguration reuses). Re-engage at the target and do
        // NOT ramp, because this is a correction, not the lock transition. The
        // ramp's synchronous first step is what keeps this branch from firing
        // spuriously in the window between starting a ramp and its first write.
        controller.beginTemporaryDim(factor: factor)
      }
      clearSkip(for: key)
    case let .skip(reason):
      // A skip ENDS any dim this display already has. The path can change under
      // a live dim (HDR engaged from System Settings, a command turned off), and
      // recording "nothing can dim this" while a dim of ours is still on the
      // wire is a state disagreement: the display would sit dimmed with the
      // coordinator reporting it skipped.
      endLockDim(&state, on: controller)
      // Recorded, never engaged: a display whose brightness nothing can move
      // must not be remembered as dimmed, or the unlock would "restore" a dim
      // that never happened. Assigned (and logged) only on a CHANGE: this runs
      // on every tick, and `lockDimSkips` is observed.
      if lockDimSkips[key] != reason {
        lockDimSkips[key] = reason
        log.info("""
        OLED care lock dim skipped for display \(displayState.id, privacy: .public): \
        \(String(describing: reason), privacy: .public)
        """)
      }
    }
  }

  /// Ends the dim and nothing else. Clearing the recorded skip is deliberately
  /// NOT folded in: the skip arm calls this and then records a reason, and a
  /// clear in here would make that record look new on every tick, which is a
  /// log line and an observation notify at the fast cadence.
  private func endLockDim(_ state: inout PerDisplay, on controller: BrightnessController) {
    state.lockDimRamp?.cancel()
    state.lockDimRamp = nil
    guard state.lockDimEngaged else { return }
    controller.endTemporaryDim()
    state.lockDimEngaged = false
  }

  /// Only when there is something to clear: this is on the per-tick path and
  /// `lockDimSkips` is `@Observable`, so an unconditional `removeValue` would
  /// notify every observer on every tick.
  private func clearSkip(for key: String) {
    guard lockDimSkips[key] != nil else { return }
    lockDimSkips.removeValue(forKey: key)
  }

  /// Ends every outstanding lock dim, for the teardowns that must not leave a
  /// panel dark: quit, settings reset, and losing a display's enrollment.
  /// Displays that have already departed are unreachable by definition; their
  /// stored brightness is untouched, so the restore pass on the next arrival
  /// puts the panel back.
  func endAllLockDims() {
    guard let model else { return }
    let live = Dictionary(
      model.displays.map { ($0.display.persistenceKey, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    for key in Array(states.keys) {
      guard var state = states[key] else { continue }
      guard let controller = live[key]?.controller else {
        state.lockDimRamp?.cancel()
        state.lockDimRamp = nil
        state.lockDimEngaged = false
        states[key] = state
        lockDimSkips.removeValue(forKey: key)
        continue
      }
      endLockDim(&state, on: controller)
      clearSkip(for: key)
      states[key] = state
    }
  }

  // MARK: - Rendering (with the two funcs below, the ONLY overlay callers)

  /// THE render funnel: every overlay apply in this type goes through here.
  ///
  /// **The mask carries ABSOLUTE per-cell opacity, and `alpha` goes to 1 when
  /// one is present.** `contentView.alphaValue` multiplies the layer, mask
  /// included, so passing the dim state's own alpha alongside a mask would
  /// scale every nominated cell down by it: an idle dim of 0.5 with a 0.15
  /// nomination would render 0.075 in the region and, worse, **zero everywhere
  /// else**, silently deleting the uniform dim the user actually asked for.
  /// Composing to absolutes and handing the whole thing over as the mask is the
  /// only arrangement where both survive.
  private func render(_ dimState: OledDimState, into state: inout PerDisplay, on id: CGDirectDisplayID) {
    let stateAlpha = state.engine.alpha(for: dimState)
    let blackout = dimState == .blackout
    // Blackout is excluded (OC17's rule, and there is no luminance left to
    // spend). Everything else composes, INCLUDING `.active`: #20 is the one
    // care feature that runs while the user is working, so it can require an
    // overlay in a state whose own alpha is nil and which would otherwise have
    // no window at all.
    let nomination = (state.detectionDimmingEnabled && !blackout) ? state.nominatedMask : nil

    var alpha = stateAlpha
    var mask: OverlayMask.Oriented?
    if let nomination, let transform = Self.transform(for: id) {
      let composed = OverlayMask.uniform(stateAlpha ?? 0).darkened(by: nomination)
      mask = composed.displayOriented(through: transform)
      alpha = 1.0
    }

    guard overlay.apply(alpha: alpha, mask: mask, blackout: blackout, on: id) else {
      // No NSScreen matched: nothing reached the screen, so there is nothing
      // to verify and no state to memoise — the next tick retries, and the
      // overlay rate-limits its own warning.
      state.lastAppliedAlpha = nil
      state.lastAppliedBlackout = false
      state.lastAppliedMask = nil
      return
    }
    if alpha != state.lastAppliedAlpha || blackout != state.lastAppliedBlackout
      || mask != state.lastAppliedMask {
      // The window server actually moved (or will, a run-loop turn from now).
      // The mask is in this test because `write` re-orders the window on every
      // state change, mask included, so a mask-only change is still something
      // OC12 has to verify landed.
      state.needsVerify = true
      state.verifyAttempts = 0
      state.lastAppliedAlpha = alpha
      state.lastAppliedBlackout = blackout
      state.lastAppliedMask = mask
    }
  }

  /// Recomputes #20's nomination for one display. Called when a new luminance
  /// sample lands, which is the only thing that can change the answer.
  ///
  /// Stored in PANEL space, not display space: the render composes it with the
  /// uniform dim and orients the result, so keeping it panel-side means one
  /// orientation per render instead of one here plus a re-orientation whenever
  /// the display rotates under a cached mask.
  private func renominate(
    for key: String, grid: [Double], cols: Int, rows: Int, through transform: PanelSpaceTransform
  ) {
    guard states[key]?.detectionDimmingEnabled == true else {
      states[key]?.nominatedMask = nil
      return
    }
    guard let observation = latestObservations[key] else {
      // No window list means no staticness prior, and the conjunction is the
      // feature: nominating on brightness alone is what dims a playing video.
      states[key]?.nominatedMask = nil
      return
    }
    let panelGrid = transform.panelNativeGrid(fromDisplayGrid: grid, cols: cols, rows: rows)
    states[key]?.nominatedMask = StaticRegionDetector.nominate(
      recentGrid: panelGrid, observation: observation, thresholds: .default)
  }

  /// OC12 reconcile, one tick after a mutation. True when the window server
  /// agrees with the last render. On a missing wanted overlay the lever is
  /// `reassert(on:)` — NEVER a repeat apply, which is a no-op by construction
  /// against the overlay's memo — and re-verification waits for the NEXT
  /// tick: one nudge per detected mismatch, log, don't loop.
  private func verifyLastRender(of state: PerDisplay, on id: CGDirectDisplayID) -> Bool {
    let wanted = state.lastAppliedAlpha != nil
    let present = overlay.verifyPresence(on: id)
    if wanted, !present {
      log.error("OLED care overlay for display \(id, privacy: .public) not on screen after apply; reasserting")
      overlay.reassert(on: id)
      return false
    }
    if !wanted, present {
      // A removal the server has not honoured: verifyPresence already
      // re-closed the strand and logged. Check again next tick.
      return false
    }
    return true
  }

  /// Wholesale teardown (reconfiguration, system sleep, reset). `verifyRemoval`
  /// is true only when display IDs are known stable across the teardown (system
  /// sleep) — after a reconfiguration the old IDs may name different panels, so
  /// a verify keyed on the new resolution would ask the wrong question.
  private func clearAllOverlays(verifyRemoval: Bool = false) {
    overlay.removeAll()
    for key in states.keys {
      states[key]?.lastAppliedAlpha = nil
      states[key]?.lastAppliedBlackout = false
      states[key]?.needsVerify = verifyRemoval
      states[key]?.verifyAttempts = 0
    }
  }

  /// I-2: verifies removals whose issuing state is already gone (reset,
  /// un-enrollment). `verifyPresence` re-closes a strand itself; this just
  /// keeps asking on later turns until the server agrees, with the same
  /// attempt bound the in-state check has.
  private func drainPendingRemovalVerifications() {
    for (id, attempts) in pendingRemovalVerifications {
      if !overlay.verifyPresence(on: id) {
        pendingRemovalVerifications.removeValue(forKey: id)
      } else if attempts + 1 >= Self.maxVerifyAttempts {
        pendingRemovalVerifications.removeValue(forKey: id)
        log.error("""
        OLED care overlay for display \(id, privacy: .public) still on screen after \
        \(Self.maxVerifyAttempts, privacy: .public) removal checks; giving up
        """)
      } else {
        pendingRemovalVerifications[id] = attempts + 1
      }
    }
  }

  // MARK: - Telemetry (W3b-1)

  /// The 60 s schedule, riding the driver loop — there is no second timer.
  ///
  /// The two halves share one clock (spec §4: window observation is scheduled
  /// on the sampling clock) but are gated by separate prefs, because window
  /// observation needs no permission and is the whole of the degraded mode.
  ///
  /// The window list is polled inline: it is the same `CGWindowListCopyWindowInfo`
  /// the focus sampler already makes on this loop [MEASURED 2026-08-06: 0.46 ms].
  /// The luminance capture is not — it suspends for ~70 ms across an
  /// `SCShareableContent` XPC round trip, and the driver loop is the thing that
  /// has to answer input inside 100 ms when an overlay is up (#21). It is
  /// therefore handed to a ONE-SHOT task; the loop itself stays synchronous.
  private func updateTelemetry(
    for key: String, state: inout PerDisplay, dimState: OledDimState,
    on id: CGDirectDisplayID, at now: SuspendingClock.Instant
  ) {
    guard state.telemetryEnabled || state.windowObservationEnabled else { return }
    guard samplingQualifies(dimState: dimState, on: id) else { return }
    if let last = state.lastSampleAt, now - last < Self.samplingInterval { return }
    state.lastSampleAt = now

    // A degenerate transform does NOT reject the sample downstream —
    // `panelNativeGrid` re-bins on rotation alone and never looks at
    // `displaySize` — so a mid-reconfiguration display has to be gated here or
    // it accumulates normally into cells that mean nothing.
    guard let transform = Self.transform(for: id) else { return }

    if state.windowObservationEnabled {
      observeWindows(for: key, on: id, through: transform)
    }
    if state.telemetryEnabled, !state.sampleInFlight {
      state.sampleInFlight = true
      captureExposure(for: key, on: id, through: transform)
    }
    persistExposureHistoryIfDue(at: now)
  }

  /// THE suspension verdict for telemetry, in one place and derived from the
  /// engine's own published state: `.suspended` IS mirrored (OC13), and every
  /// dim state is a panel that is not showing what a capture would measure.
  /// Nothing here re-reads a signal the overlay path already turned into a
  /// verdict.
  ///
  /// The lock is checked separately because lock dim is a PREF — a locked
  /// display with `oledLockDim` off sits at `.active`, and spec §4 skips it
  /// regardless. Sleep and battery are the two conditions the engine takes no
  /// input from at all.
  ///
  /// **`CGDisplayIsAsleep` cannot see a panel blanked at the monitor itself,
  /// and this gate inherits that hole (#94, MEASURED).** A DPMS-off panel stays
  /// in both display lists, keeps `CGDisplayIsAsleep` false and reports full
  /// resolution, so the check below passes over a dark panel and a capture
  /// returns the still-composited framebuffer. The hours counter has the same
  /// hole and documents it ~300 lines above; the consequence here is worse in
  /// kind rather than in degree. Hours over-count by a scalar, while the
  /// exposure map and the per-app attribution book wear against SPECIFIC cells
  /// and SPECIFIC apps that emitted nothing, and both are persisted.
  ///
  /// Bounded, not fixed, because §2 says a blanked panel is indistinguishable
  /// at every layer we can observe and does not self-recover. What bounds it is
  /// HID idle time: with nobody typing, the engine leaves `.active` at the idle
  /// threshold and sampling stops. **The uncovered case is a second display**,
  /// where the user works on one panel while the other sits blanked, holding
  /// idle at zero and this one at `.active` indefinitely. Do not "fix" this
  /// with a readback or a DPMS probe; see #94 and §2.
  private func samplingQualifies(dimState: OledDimState, on id: CGDirectDisplayID) -> Bool {
    guard !resetting, dimState == .active, !lockObserver.isLocked else { return false }
    guard CGDisplayIsAsleep(id) == 0 else { return false }
    return !OledCareSignalSources.onLowBattery()
  }

  /// Display geometry for the transform, from `CGDisplayBounds` — the same
  /// source `CGWindowListSource` subtracts its origin from, so a window rect
  /// and a luminance cell land in one coordinate system. `NSScreen.frame` is
  /// bottom-left and would put every window on the wrong half of the panel.
  ///
  /// Nil, never a default, on a zero size or a rotation that is not a right
  /// angle: the first is a mid-reconfiguration reading and the second is one
  /// this feature declines to describe (RT7) rather than round into a
  /// scrambled wear history.
  private static func transform(for id: CGDirectDisplayID) -> PanelSpaceTransform? {
    let size = CGDisplayBounds(id).size
    guard size.width > 0, size.height > 0 else { return nil }
    guard let rotation = DisplayRotation(degrees: CGDisplayRotation(id)) else { return nil }
    return PanelSpaceTransform(displaySize: size, rotation: rotation)
  }

  /// Constructed at the point of use rather than stored: the source is a
  /// display ID and one method, and IDs reassign across a replug. A stored
  /// instance would need re-creating on every reconfiguration to stay correct;
  /// this cannot go stale, because the ID it gets is the one this tick
  /// resolved.
  private func observeWindows(
    for key: String, on id: CGDirectDisplayID, through transform: PanelSpaceTransform
  ) {
    let windows = CGWindowListSource(displayID: id).onScreenWindows()
    // Mutated IN PLACE: `observe` is mutating on a value type, and a local copy
    // would discard every window's age on return — the 5-minute stationary
    // threshold could then never be reached.
    var observer = observers[key] ?? WindowObserver()
    let observation = observer.observe(windows, through: transform, at: Date())
    observers[key] = observer
    latestObservations[key] = observation

    // OC18's attribution over time. Booked at the NOMINAL interval for the
    // exposure path's reason: an observation stands for one sampling slot, and
    // the wall-clock gap since the last one can be an hour if the panel was
    // locked. No epoch check, unlike `finishExposureCapture`: this whole path
    // is synchronous on the main actor, so there is nothing in flight for a
    // mid-capture delete to race — the epoch exists for the capture's ~70 ms
    // suspension, which this side does not have.
    var owners = ownerHoursAccumulator(for: key)
    let before = owners.hours.totalSeconds
    owners.accumulate(observation, elapsed: Self.seconds(Self.samplingInterval))
    ownerHours[key] = owners
    // Only a booked observation dirties the store: an all-uncovered panel adds
    // nothing, and marking it dirty would re-encode an unchanged value.
    if owners.hours.totalSeconds > before { unsavedExposureKeys.insert(key) }
  }

  private func forgetWindowObservation(for key: String) {
    observers.removeValue(forKey: key)
    latestObservations.removeValue(forKey: key)
  }

  private func captureExposure(
    for key: String, on id: CGDirectDisplayID, through transform: PanelSpaceTransform
  ) {
    let epoch = exposureEpoch
    log.debug("OLED care: exposure capture issued for display \(id, privacy: .public)")
    // One shot, not a loop. `self` is deliberately not held across the await —
    // the driver loop's rule, for its reason: the sampler is a separate object,
    // so awaiting through it retains the sampler and not this coordinator.
    Task { @MainActor [weak self] in
      guard let sampler = self?.sampler else { return }
      let sample = await sampler.sample(displayID: id)
      self?.finishExposureCapture(sample, for: key, on: id, through: transform, epoch: epoch)
    }
  }

  /// Everything the capture's suspension can invalidate is re-checked here.
  /// ~70 ms is long enough for the display to lock, mirror, sleep, dim, be
  /// reconfigured, be un-enrolled, or have its history deleted, and a sample
  /// taken before any of those is exposure the panel did not emit.
  private func finishExposureCapture(
    _ sample: LuminanceSampler.Sample?, for key: String, on id: CGDirectDisplayID,
    through transform: PanelSpaceTransform, epoch: Int
  ) {
    states[key]?.sampleInFlight = false
    guard let sample, epoch == exposureEpoch else { return }
    guard let state = states[key], state.telemetryEnabled, state.lastDisplayID == id,
      let dimState = dimStates[key], samplingQualifies(dimState: dimState, on: id)
    else { return }
    // Geometry can change under a capture without the display departing (a
    // rotation, a mode switch). The grid was reduced through the OLD geometry,
    // so it is binned rather than re-mapped through geometry it never saw.
    guard Self.transform(for: id) == transform else { return }

    var accumulator = exposureAccumulator(for: key)
    let before = accumulator.map.sampleCount
    // Handed over whole: `accumulate` is all-or-nothing and refuses a malformed
    // sample itself, so pre-filtering here would only be a second opinion that
    // can disagree.
    accumulator.accumulate(
      displayGrid: sample.grid, cols: sample.cols, rows: sample.rows, through: transform,
      // The NOMINAL interval, not the measured gap. A sample stands for one
      // sampling slot; the gap since the last one can be an hour if the panel
      // was locked, and booking that as time at this luminance would credit the
      // map with exposure that never happened. The unit is arbitrary and only
      // ever compared against itself, so the jitter this ignores is noise.
      elapsed: Self.seconds(Self.samplingInterval), at: Date())
    guard accumulator.map.sampleCount > before else {
      log.debug("OLED care: exposure sample refused for display \(id, privacy: .public)")
      return
    }
    accumulators[key] = accumulator
    unsavedExposureKeys.insert(key)
    // #20 nominates off the sampling clock, not the 10 Hz tick: the grid it
    // reads changes once a minute, so re-nominating per tick would burn CPU to
    // reach the same answer 600 times.
    renominate(for: key, grid: sample.grid, cols: sample.cols, rows: sample.rows,
               through: transform)
    log.debug("""
    OLED care: exposure sample accepted for display \(id, privacy: .public) \
    (\(accumulator.map.sampleCount, privacy: .public) total)
    """)
  }

  // MARK: - Exposure persistence

  /// Restored from disk on first touch and memoised, `hoursTracker(for:)`'s
  /// rule and its reason: two live accumulators for one key double-book every
  /// sample, and the map is persisted, so the bias never washes out.
  private func exposureAccumulator(for key: String) -> ExposureAccumulator {
    if let existing = accumulators[key] { return existing }
    let accumulator = ExposureAccumulator(map: loadExposureMap(for: key))
    accumulators[key] = accumulator
    return accumulator
  }

  /// Its neighbour's rule, for its reason: one live accumulator per key.
  private func ownerHoursAccumulator(for key: String) -> OwnerHoursAccumulator {
    if let existing = ownerHours[key] { return existing }
    let accumulator = OwnerHoursAccumulator(hours: loadOwnerHours(for: key))
    ownerHours[key] = accumulator
    return accumulator
  }

  private static func exposureKeyName(_ persistenceKey: String) -> String {
    // `PanelHoursTracker`'s spelling: engine state, not a `PrefName` case —
    // nothing routes accumulated wear through `SettingsActions`.
    "oledExposureMap.\(persistenceKey)"
  }

  private static func ownerHoursKeyName(_ persistenceKey: String) -> String {
    "oledOwnerHours.\(persistenceKey)"
  }

  /// A `cells` array of the wrong length throws out of `ExposureMap.init(from:)`
  /// BY DESIGN — decoding it would hand the health view a map that traps the
  /// first time it is indexed — so an unreadable store starts over rather than
  /// propagating.
  ///
  /// **Starting over is destructive, so what it may start over FROM is
  /// narrow.** Returning `.empty` here does not merely lose the history in
  /// memory: the next accepted sample marks the key dirty and
  /// `saveExposureHistory` encodes the empty map straight over the stored one,
  /// inside a minute. That is correct for malformed JSON, which is junk. It is
  /// not correct for a store written by a newer build or laid out for a
  /// different grid, which is intact history a later build could migrate, so
  /// `OledStoreDecodeFailure` quarantines the key instead and nothing is
  /// written back for it.
  private func loadExposureMap(for key: String) -> ExposureMap {
    guard let data = UserDefaults.standard.data(forKey: Self.exposureKeyName(key)) else {
      return .empty
    }
    do {
      return try JSONDecoder().decode(ExposureMap.self, from: data)
    } catch let failure as OledStoreDecodeFailure {
      quarantine(key, reason: "exposure map", failure: failure)
      return .empty
    } catch {
      log.error("""
      OLED care: stored exposure map for \(key, privacy: .public) is unreadable \
      (\(error.localizedDescription, privacy: .public)); starting over
      """)
      return .empty
    }
  }

  /// Reads back as `.empty` on anything unreadable, `loadExposureMap`'s reason
  /// scaled down: a per-owner total nobody can decode is not worth propagating
  /// a failure over, and starting the series again is honest. The quarantine
  /// split is NOT scaled down — the two stores share one dirty set and one
  /// write, so holding one back while overwriting the other would leave a
  /// display's history half-migrable.
  private func loadOwnerHours(for key: String) -> OwnerHours {
    guard let data = UserDefaults.standard.data(forKey: Self.ownerHoursKeyName(key)) else {
      return .empty
    }
    do {
      return try JSONDecoder().decode(OwnerHours.self, from: data)
    } catch let failure as OledStoreDecodeFailure {
      quarantine(key, reason: "per-app hours", failure: failure)
      return .empty
    } catch {
      log.error("""
      OLED care: stored per-app hours for \(key, privacy: .public) are unreadable \
      (\(error.localizedDescription, privacy: .public)); starting over
      """)
      return .empty
    }
  }

  private func quarantine(_ key: String, reason: String, failure: OledStoreDecodeFailure) {
    unwritableExposureKeys.insert(key)
    log.error("""
    OLED care: stored \(reason, privacy: .public) for \(key, privacy: .public) was written by a \
    schema this build does not read (\(String(describing: failure), privacy: .public)); keeping \
    the stored bytes and recording nothing new for this display until its history is deleted
    """)
  }

  private func persistExposureHistoryIfDue(at now: SuspendingClock.Instant) {
    guard !unsavedExposureKeys.isEmpty else { return }
    if let last = lastExposurePersist, now - last < Self.exposurePersistInterval { return }
    lastExposurePersist = now
    flushExposureHistory()
  }

  /// The undebounced write: termination, system sleep, and a display leaving.
  ///
  /// OC20's histogram rides the same three moments. It debounces on the same
  /// 60 s as panel hours, so without this a quit loses up to a minute per
  /// display per launch, which over a multi-week soak is a systematic
  /// undercount rather than noise.
  private func flushExposureHistory() {
    for key in unsavedExposureKeys { saveExposureHistory(for: key) }
    for tracker in wearTrackers.values { tracker.flush() }
  }

  /// Both halves of a panel's exposure history — the per-cell map and the
  /// per-owner series — ride ONE dirty set: they are written on the same tick
  /// and destroyed by the same delete, so a second set would be state kept in
  /// agreement by discipline. Either store can legitimately be absent, because
  /// telemetry and window observation are separate prefs; each is written only
  /// if it exists.
  private func saveExposureHistory(for key: String) {
    // Clears the dirty flag whether or not the encodes land: a value that
    // cannot be encoded now cannot be encoded on the next pass either, and
    // leaving the key dirty would retry it forever.
    guard unsavedExposureKeys.remove(key) != nil else { return }
    // Quarantined: the stored bytes are history this build cannot read but a
    // later one might. The dirty flag is still cleared above, so this display
    // simply records nothing until the user deletes its history.
    guard !unwritableExposureKeys.contains(key) else { return }
    if let map = accumulators[key]?.map {
      if let data = try? JSONEncoder().encode(map) {
        UserDefaults.standard.set(data, forKey: Self.exposureKeyName(key))
      } else {
        log.error("OLED care: could not encode the exposure map for \(key, privacy: .public)")
      }
    }
    if let hours = ownerHours[key]?.hours {
      if let data = try? JSONEncoder().encode(hours) {
        UserDefaults.standard.set(data, forKey: Self.ownerHoursKeyName(key))
      } else {
        log.error("OLED care: could not encode the per-app hours for \(key, privacy: .public)")
      }
    }
  }

  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds)
      + Double(duration.components.attoseconds) / 1e18
  }
}
