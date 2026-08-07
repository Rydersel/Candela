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
  }

  /// Poll cadence: slow while every enrolled display is `.active`/`.suspended`;
  /// fast while any overlay is up (restore latency gate is 100 ms, #21) or an
  /// OC12 verification is pending.
  private static let slowCadence: Duration = .seconds(2)
  private static let fastCadence: Duration = .milliseconds(100)
  /// After this much CONTINUOUS settling the signal is ignored: the entry gate
  /// exists for a transition window measured in seconds, not for a latch that
  /// never cleared.
  private static let hdrSettleDeferralBound: Duration = .seconds(10)

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
  @ObservationIgnored private let log = Logger(
    subsystem: "com.rydersel.Candela", category: "oledcare"
  )

  /// The notification tokens are not unregistered here (not `Sendable`, so a
  /// nonisolated deinit cannot touch them) — sibling-coordinator precedent:
  /// this object lives as long as the app and the blocks capture weakly.
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

    lockObserver.onLock = { [weak self] in
      guard let self else { return }
      for key in states.keys { states[key]?.engine.noteLock() }
      tick()
    }
    lockObserver.onUnlock = { [weak self] in
      guard let self else { return }
      for key in states.keys { states[key]?.engine.noteUnlock() }
      tick()
    }
    lockObserver.start()

    let center = NSWorkspace.shared.notificationCenter
    sleepWakeObservers.append(center.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.systemWillSleep() }
    })
    sleepWakeObservers.append(center.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.systemDidWake() }
    })

    reconcileEnrollment()
    driver?.cancel()
    driver = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        self.tick()
        try? await Task.sleep(for: self.cadence())
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
    guard let model, !model.isSafeMode else { return }
    reconcileEnrollment()
    if driver != nil { tick() }
  }

  /// The topology loop's hook. IDs may have been REASSIGNED even with both
  /// displays still present, so the response is teardown + re-render from
  /// state under freshly resolved IDs — never `repinFrames()` alone, which
  /// would pin an overlay to the wrong panel.
  func displaysReconfigured() {
    guard let model, !model.isSafeMode else { return }
    clearAllOverlays()
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
  /// hours the user just cleared.
  func prepareForReset() {
    clearAllOverlays()
    states = [:]
    dimStates = [:]
    for tracker in trackers.values { tracker.reset() }
  }

  /// VCP 0xD6 power-off (spec §3): the wave's only DDC write. Standby is
  /// recorded BEFORE the write so the departure the power-off produces cannot
  /// race the bookkeeping; the departure itself is EXPECTED and flows through
  /// `displaysReconfigured` like any other (state kept, hours persisted, a
  /// fresh `.active` engine on return).
  func powerOffDisplay(_ state: AppModel.DisplayState) async -> Bool {
    hoursTracker(for: state.display.persistenceKey).noteStandby()
    return await state.writer.write(command: VCP.powerMode, value: 0x04)
  }

  // MARK: - Sleep / wake

  private func systemWillSleep() {
    // IDs are stable across a plain system sleep, so the removal IS verified
    // (first post-wake ticks re-check); contrast displaysReconfigured, where
    // the old IDs may already name different panels.
    clearAllOverlays(verifyRemoval: true)
    for key in states.keys { hoursTracker(for: key).noteStandby() }
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
        existing.hoursTracking = prefs.oledHoursTracking
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
      hoursTracker(for: key).noteStandby()
      dropState(for: key)
    }
  }

  private func dropState(for key: String) {
    guard let state = states.removeValue(forKey: key) else { return }
    if let id = state.lastDisplayID { overlay.remove(for: id) }
    dimStates.removeValue(forKey: key)
  }

  // MARK: - The tick

  private func tick() {
    guard let model else { return }
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

      // The unfocused clock: reset to nil the moment this display holds
      // focus; started when some OTHER display does. A nil sample means
      // "no focus data" (before the first resolve, or just invalidated) and
      // deliberately stops the clock — "unfocused everywhere" is the failure
      // the sampler's hold-last rule exists to prevent, and this is its
      // consumer-side half.
      var unfocusedSeconds: Double?
      if state.unfocusedDimEnabled, let focusedDisplay {
        if focusedDisplay == id {
          state.unfocusedSince = nil
        } else if state.unfocusedSince == nil {
          state.unfocusedSince = now
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
      // run-loop turn in both directions.
      if state.needsVerify {
        state.needsVerify = !verifyLastRender(of: state, on: id)
      }
      render(newState, into: &state, on: id)

      states[key] = state
      published[key] = newState
    }
    // Assigned only on change: @Observable notifies on every set and this
    // runs at up to 10 Hz.
    if published != dimStates { dimStates = published }
  }

  private func cadence() -> Duration {
    let overlayUp = states.values.contains { $0.lastAppliedAlpha != nil }
    let verifying = states.values.contains(where: \.needsVerify)
    return overlayUp || verifying ? Self.fastCadence : Self.slowCadence
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
    }
  }

  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds)
      + Double(duration.components.attoseconds) / 1e18
  }
}
