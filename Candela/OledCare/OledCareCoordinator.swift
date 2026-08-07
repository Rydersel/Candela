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

  /// Why a locked display was not dimmed, by persistenceKey, for whatever
  /// surface reports it. Present ONLY while the display is locked and the dim
  /// was refused: a stale entry would be a sentence about a state the machine
  /// is no longer in.
  private(set) var lockDimSkips: [String: LockDimSkip] = [:]

  private struct PerDisplay {
    var engine: IdleDimmingEngine
    /// Cached from prefs (refreshed by `reconcileEnrollment`) so the tick can
    /// decide whether to run the focus sampler without a per-tick prefs read.
    var unfocusedDimEnabled: Bool
    var hoursTracking: Bool
    /// The ID this display's overlay was last driven under — a rendering
    /// address, never identity. Refreshed from the live display list each tick.
    var lastDisplayID: CGDirectDisplayID?
    /// What we last asked the window server for (mirrors the overlay's own
    /// applied state). nil = no overlay wanted. This is what OC12 verifies.
    var lastAppliedAlpha: Double?
    var lastAppliedBlackout = false
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

  @ObservationIgnored private weak var model: AppModel?
  @ObservationIgnored private let overlay = OledOverlay()
  @ObservationIgnored private let lockObserver = LockStateObserver()
  @ObservationIgnored private let focus = FocusSampler()
  /// Keyed by persistenceKey; created lazily and kept for the app's lifetime —
  /// hours are persistent facts about a panel, not about a connection.
  @ObservationIgnored private var trackers: [String: PanelHoursTracker] = [:]
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
    endAllLockDims()
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
        states[key] = existing
      } else {
        states[key] = PerDisplay(
          engine: IdleDimmingEngine(config: config),
          unfocusedDimEnabled: prefs.oledUnfocusedDimEnabled,
          hoursTracking: prefs.oledHoursTracking,
          lastDisplayID: displayState.id
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
          hoursTracker(for: key).noteTick(
            displayAwake: true, secondsSinceLastTick: Self.seconds(now - last)
          )
        }
      }
      state.wasAwake = awake
      state.hoursLastTick = now

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
  private func render(_ dimState: OledDimState, into state: inout PerDisplay, on id: CGDirectDisplayID) {
    let alpha = state.engine.alpha(for: dimState)
    let blackout = dimState == .blackout
    guard overlay.apply(alpha: alpha, blackout: blackout, on: id) else {
      // No NSScreen matched: nothing reached the screen, so there is nothing
      // to verify and no state to memoise — the next tick retries, and the
      // overlay rate-limits its own warning.
      state.lastAppliedAlpha = nil
      state.lastAppliedBlackout = false
      return
    }
    if alpha != state.lastAppliedAlpha || blackout != state.lastAppliedBlackout {
      // The window server actually moved (or will, a run-loop turn from now).
      state.needsVerify = true
      state.verifyAttempts = 0
      state.lastAppliedAlpha = alpha
      state.lastAppliedBlackout = blackout
    }
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

  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds)
      + Double(duration.components.attoseconds) / 1e18
  }
}
