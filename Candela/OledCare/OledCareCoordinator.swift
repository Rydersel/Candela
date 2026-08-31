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
/// coordinators it takes no dependencies at init: `start(model:)` hands it the
/// model once, held weakly, and everything else is resolved fresh per tick.
///
/// Shape rules this type is built around, each measured or ruled:
///
/// - **Everything is keyed by `persistenceKey`, never `CGDirectDisplayID`.**
///   IDs reassign across a dock cycle with both displays still present
///   (MAG 3 to 2, Dell 2 to 3), so the ID-to-key resolution happens fresh on
///   every tick and an ID is only ever a rendering address.
/// - **OC12, verified on the window server's side and on a LATER tick.** The
///   server lags AppKit by a run-loop turn in BOTH directions (measured 6 to
///   9 ms), so verifying inline after a mutation reads the pre-mutation world.
///   A render that changed state marks the display and the FOLLOWING tick
///   checks `verifyPresence`; the reconcile lever is `reassert(on:)`, never a
///   repeat `apply`, which is a no-op by construction.
/// - **On any reconfiguration: tear down and re-render, never repin.**
///   `repinFrames()` alone would pin an overlay to the wrong panel after an ID
///   swap. `displaysReconfigured()` calls `removeAll()` and the next render
///   recreates every wanted overlay under the fresh IDs.
/// - **OC13: a mirror-set participant is `suspended`**: overlay removed, engine
///   paused, hours not accumulated. Membership comes from the app's one mirror
///   definition, `MirrorTopology.isInMirrorSet`, master included.
/// - **SS8 carves synthesis out of the two counters, not out of the pause.** A
///   mirror set Candela engaged to render a synthesized size is not mirroring
///   the user asked for (`MirrorTopology.isSynthesisSet`), and the panel behind
///   it is lit and being worn, so panel hours and the wear signal keep accruing.
///   TELEMETRY CARVES OUT THE SAME WAY: sampling is measurement, not
///   intervention, so `OledTelemetryTarget` lets exposure capture and window
///   observation keep running through a synthesis suspension. A user mirror
///   stays out, and so does the virtual master. The pause itself, and every
///   intervention under it, stays for v1; the pane says which mirror it is.
/// - **Safe Mode builds `chrome` and nothing else**: chrome toggles are explicit
///   user actions on system settings, so they stay functional; the driver loop
///   (overlays, sampling, hours) never starts.
/// - **Telemetry rides the same loop at its own 60 s cadence**, taking its
///   suspension verdict from the dimming engine's published state rather than
///   re-deriving one. `samplingQualifies(dimState:on:)` over
///   `OledTelemetryTarget` is the whole of that decision, and the same target
///   carries the display it reads from: under a synthesized size that is the
///   virtual display the panel mirrors, because ScreenCaptureKit does not list
///   a mirrored display and the window rectangles live in the surface's space.
///   Identity stays the panel's throughout.
@MainActor
@Observable
final class OledCareCoordinator: CheckupCareHolding {
  /// The latest engine state per enrolled display, by persistenceKey. The
  /// pane's per-display section reads this ("paused while mirrored", etc.).
  private(set) var dimStates: [String: OledDimState] = [:]

  /// Built unconditionally in `start(model:)`, Safe Mode included, so the pane's
  /// global toggles always reflect real system state. Nil only before launch
  /// wiring runs.
  private(set) var chrome: ChromeAutoHideController?

  /// Why a locked display was not dimmed, by persistenceKey. Present ONLY while
  /// the display is locked and the dim was refused: a stale entry would be a
  /// sentence about a state the machine is no longer in.
  ///
  /// Read through `OledCareCopy` by both surfaces that report lock dim. OC7
  /// sub-ruling 4 is "recorded, never reported as dimmed", and a record no
  /// surface reads satisfies only the first half.
  private(set) var lockDimSkips: [String: LockDimSkip] = [:]

  /// The enrolled displays whose OC13 pause is a synthesis set rather than
  /// mirroring the user asked for, by persistenceKey. Rebuilt whole every tick
  /// from the verdict the loop already made, so it cannot disagree with
  /// `dimStates` about why a display is paused.
  ///
  /// v1 keeps the pause under a synthesized size (SS8), so the pane still reads
  /// "paused"; this is what lets it name the right mirror.
  private(set) var synthesisSuspensions: Set<String> = []

  /// The enrolled displays paused because a checkup field is on them, by
  /// persistenceKey. Rebuilt every tick from the same verdict as `dimStates`,
  /// like `synthesisSuspensions`, so the pane cannot disagree about the reason.
  private(set) var checkupSuspensions: Set<String> = []

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
    /// The ID this display's overlay was last driven under: a rendering address,
    /// never identity. Refreshed from the live display list each tick.
    var lastDisplayID: CGDirectDisplayID?
    /// What we last asked the window server for (mirrors the overlay's own
    /// applied state). nil = no overlay wanted. This is what OC12 verifies.
    var lastAppliedAlpha: Double?
    var lastAppliedBlackout = false
    var lastAppliedMask: OverlayMask.Oriented?
    /// Detection dimming. Off by default, so an enrolled display that never opts
    /// in pays nothing past the flag test in `render`.
    var detectionDimmingEnabled = false
    /// This tick's display-sleep assertion reading, carried so `render` can put
    /// detection dimming behind the same gate as idle dimming. The engine gates
    /// its own states on it, but `.active` never passes through `mayShow`, and
    /// `.active` is exactly when detection dimming runs.
    var assertionHeld = false
    /// The current nomination in PANEL space. The LUMINANCE half changes only
    /// when a new sample lands; the WINDOW half is re-read on the fast loop
    /// while a nomination is displayed (`refreshNominationGeometry`), so a moved
    /// window sheds its dim in about a second. Nil means "nothing qualifies",
    /// deliberately distinguishable from an all-zero mask: the render then keeps
    /// the cheaper scalar path.
    var nominatedMask: OverlayMask?
    /// Throttle for `refreshNominationGeometry`; nil until a mask first shows.
    var lastNominationRefreshAt: SuspendingClock.Instant?
    /// OC12: the last render mutated window-server state; verify it on a
    /// LATER tick than the one that mutated.
    var needsVerify = false
    /// Reconcile attempts against the CURRENT mismatch; zeroed on every new
    /// mutation and on success. Bounds the OC12 loop; see `maxVerifyAttempts`.
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
    /// Start of the last telemetry slot this display took. ONE clock drives both
    /// halves, so a display is never sampled and observed on drifting cadences
    /// that each pay their own cost.
    var lastSampleAt: SuspendingClock.Instant?
    /// A capture is out on the XPC round trip. Nothing else may issue one: two
    /// in flight would double-book the interval they both stand for.
    var sampleInFlight = false
    /// USER mirror-set membership as of the last tick, for OC13's entry EDGE.
    /// The steady state is already handled (a mirrored display never
    /// qualifies); this exists so the observer's ageing state is dropped
    /// exactly once, when the panel stops showing what those ages describe.
    /// A synthesis set is not membership for this purpose (SS8): the panel goes
    /// on showing those same windows, so the edge must not fire on an engage.
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
  /// fast while any dim is up by any delivery (the restore latency gate is
  /// 100 ms) or an OC12 verification is pending. The predicate and both
  /// durations live in `OledCareCadence`, under test.
  /// After this much CONTINUOUS settling the signal is ignored: the entry gate
  /// exists for a transition window measured in seconds, not for a latch that
  /// never cleared.
  private static let hdrSettleDeferralBound: Duration = .seconds(10)
  /// OC12 reconcile bound ("log, don't loop" needs an actual number): at the
  /// fast cadence five attempts is ~500 ms, dozens of run-loop turns against a
  /// measured 6 to 9 ms server lag, so a mismatch still standing is structural
  /// (a departing display, a shield above us). Retrying forever would pin the
  /// fast cadence and log an error ten times a second.
  private static let maxVerifyAttempts = 5
  /// Spec §4: one capture per enrolled display per 60 s, and the window list on
  /// the same clock.
  private static let samplingInterval: Duration = .seconds(60)
  /// How often a DISPLAYED nomination re-checks window geometry. One second: a
  /// dim clearing within a second reads as cleanup, while a dim sitting on moved
  /// content for a whole sampling slot reads as burn-in, the symptom the feature
  /// exists to prevent. The poll under it is a measured 0.46 ms, and it only
  /// runs while a mask is on screen.
  private static let nominationGeometryInterval: Duration = .seconds(1)
  /// "At most every few minutes, plus at termination" (spec §4). A defaults
  /// write per sample would put one on a permanent 60 s timer per panel for a
  /// value that is only ever read by a settings view.
  private static let exposurePersistInterval: Duration = .seconds(300)
  @ObservationIgnored private weak var model: AppModel?
  @ObservationIgnored private let overlay = OledOverlay()
  @ObservationIgnored private let lockObserver = LockStateObserver()
  @ObservationIgnored private let focus = FocusSampler()
  /// Keyed by persistenceKey, created lazily and kept for the app's lifetime:
  /// hours are persistent facts about a panel, not about a connection.
  @ObservationIgnored private var trackers: [String: PanelHoursTracker] = [:]
  /// OC20's wear signal, one per panel, keyed and reset exactly like `trackers`
  /// because it measures the same thing about the same glass: how long, and now
  /// also at what level.
  @ObservationIgnored private var wearTrackers: [String: WearSignalTracker] = [:]
  @ObservationIgnored private let sampler = LuminanceSampler()
  /// Accumulated exposure per panel, by persistenceKey, restored from disk on
  /// first touch and kept for the app's lifetime: wear is a fact about a panel,
  /// not about a connection, exactly like `trackers`.
  ///
  /// Observation-tracked, unlike its two neighbours: `healthSummary(for:)`
  /// reads it, so a SwiftUI health view re-renders when a sample lands without
  /// anyone maintaining a revision counter.
  private var accumulators: [String: ExposureAccumulator] = [:]
  /// The most recent window observation per display, for attribution in the
  /// health view. Tracked for the same reason as `accumulators`.
  private var latestObservations: [String: WindowObservation] = [:]
  /// OC18's per-app attribution OVER TIME: panel-seconds each app has occupied,
  /// folded from the same observations `latestObservations` holds the latest of.
  /// Restored on first touch and kept for the app's lifetime, observation-
  /// tracked for `accumulators`' reason.
  ///
  /// One instance per key, `hoursTracker(for:)`'s rule: two live accumulators
  /// double-book every observation, and this is persisted, so the bias never
  /// washes out.
  private var ownerHours: [String: OwnerHoursAccumulator] = [:]
  /// EM2's paired modelled-vs-measured store, one per panel, restored on first
  /// touch and kept for the app's lifetime like `accumulators`, and
  /// observation-tracked for the same reason: the OLED Care pane's comparison
  /// section reads it.
  private var comparisons: [String: ModelComparison] = [:]
  /// The exposure model's wallpaper backdrop; its cache lives inside it.
  @ObservationIgnored private let wallpaper = WallpaperLuminanceSource()
  /// The most recent accepted reading, panel-native, for the hero's live
  /// thermal view. Not history: it is the frame the accumulator just folded
  /// in, kept so a surface can show what the display looked like at the last
  /// reading, dated so the view can say how stale it is. Tracked; a SwiftUI
  /// surface renders it.
  private var latestSamples: [String: (cells: [Double], at: Date)] = [:]
  /// The most recent window-list snapshot, display-local, for the ghost
  /// overlay. Same standing as `latestObservations`: a live reading, not a
  /// store. Tracked; the hero renders it.
  private var latestWindows: [String: [WindowSnapshot]] = [:]
  /// The ageing half of window observation. `WindowObserver.observe` is MUTATING
  /// on a value type, so this must be mutated in place: a `let` copy discards
  /// every window's age on return and the stationary threshold could then never
  /// be reached. Not observation-tracked; nothing renders it.
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
  /// Displays with a checkup field on them, by persistenceKey. Not enrollment
  /// state, so `reconcileEnrollment` leaves it alone: only the window that
  /// raised a field takes it down, and a display can be un-enrolled and
  /// re-enrolled underneath it.
  @ObservationIgnored private var checkupFieldHolds: Set<String> = []
  @ObservationIgnored private var driver: Task<Void, Never>?
  /// Armed only while a dim is up, disarmed by its own first event. Restoring
  /// off the 100 ms poll alone took 102 to 118 ms against a 100 ms gate
  /// [MEASURED 2026-08-28], so the event runs the tick. The poll stays as the
  /// fallback: keyboard events skip a global monitor without an Accessibility grant.
  @ObservationIgnored private var inputMonitors: [Any] = []
  @ObservationIgnored private var sleepWakeObservers: [any NSObjectProtocol] = []
  /// C1 latch. `runSettingsReset` suspends several times between
  /// `prepareForReset()` and the domain wipe, and an HDR-off IS a display
  /// reconfiguration, so the topology loop can fire mid-reset, re-read
  /// still-unwiped enrollment prefs and re-arm the overlays the reset just tore
  /// down. While this is up, `tick()`, `displaysReconfigured()` and
  /// `reapplyAfterPrefChange()` are all no-ops; only `resetDidComplete()`
  /// clears it.
  @ObservationIgnored private var resetting = false
  /// The per-display equivalent, by persistence key. A one-display reset drives
  /// that display's hardware and waits for its writes to land, so a lock dim
  /// starting underneath would queue brightness behind the reset's own writes,
  /// where the reset cannot account for them. Deliberately NOT `prepareForReset`
  /// for this case: that one ends every display's dim and resets every hour
  /// counter, which a reset of one display has no business doing.
  @ObservationIgnored private var resettingDisplays: Set<String> = []
  /// OC12 for removals issued OUTSIDE the per-display tick (reset,
  /// un-enrollment), where the per-display state that would carry the marker is
  /// deleted in the same breath. Keyed by the ID the window was closed under,
  /// value is attempts so far. Drained by the tick independently of `states`, so
  /// a close the server ignored gets re-closed on a later turn instead of
  /// becoming an unwatched full-black window whose prefs were just wiped.
  @ObservationIgnored private var pendingRemovalVerifications: [CGDirectDisplayID: Int] = [:]
  @ObservationIgnored private let log = Logger(
    subsystem: "com.rydersel.Candela", category: "oledcare"
  )

  /// Reachable: the driver binds `self` strongly only inside the non-suspending
  /// half of each iteration, so the task never retains this object across a
  /// sleep. The cancel ends the loop at its next check rather than leaving it
  /// waking every cadence to find a nil weak self. The notification tokens are
  /// not unregistered here (not `Sendable`, so a nonisolated deinit cannot touch
  /// them); their blocks capture weakly.
  deinit {
    driver?.cancel()
  }

  // MARK: - Lifecycle

  /// Called once from `applicationDidFinishLaunching`. Safe Mode suppresses the
  /// driver loop (no overlays, no sampling, no hours) but still builds the
  /// chrome controller: its toggles are explicit user actions.
  func start(model: AppModel) {
    guard chrome == nil else { return }
    self.model = model
    chrome = ChromeAutoHideController(writer: SystemChromeWriter())
    guard !model.isSafeMode else { return }

    // Lock dim rides the Safe Mode guard above rather than carrying one of its
    // own: no lock observer is registered, so no tick ever reaches `.lockDim`
    // and no brightness is written on our behalf in a safe-mode session.
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

    // queue: nil, matching the app's own sleep observers, so the block runs
    // SYNCHRONOUSLY at post time inside AppKit's bounded pre-sleep window. A
    // `.main`-queued operation is merely ENQUEUED and can land after the wake,
    // tearing overlays down into a machine that already slept and booking the
    // standby edge on the wrong side of it. AppKit posts these on the main
    // thread, which is what `assumeIsolated` asserts and would trap on.
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

    // The "plus at termination" half of the persistence schedule. Registered
    // here because this object owns the maps and nothing outside it knows they
    // are dirty. `queue: nil` for the sleep observers' reason: an enqueued block
    // would land after the process is gone.
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
        // Strong self is confined to the non-suspending half of the iteration
        // and dropped BEFORE the sleep. A guard binding whose scope covered the
        // await would have the task retain self across every suspension, a cycle
        // that defeats [weak self] and makes deinit unreachable.
        let interval: Duration
        do {
          guard let self else { return }
          self.tick()
          interval = self.cadence()
          if self.anyDimUp() {
            self.armInputMonitor()
          } else {
            self.disarmInputMonitor()
          }
        }
        try? await Task.sleep(for: interval)
      }
    }
  }

  /// The pane's accessor, and the only door to a display's hours. Never
  /// construct a second tracker for a key this one holds: two live trackers
  /// double-book every tick.
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

  /// The health view's one door. Safe for a display that is not enrolled, not
  /// connected, or has never been sampled: the map is restored from disk on
  /// first touch and `.empty` answers everything honestly.
  ///
  /// Telemetry is read from the cached enrollment state when there is one and
  /// from prefs otherwise, so a disconnected panel's history still reports the
  /// confidence it was recorded under rather than defaulting to `.estimated`.
  ///
  /// Deliberately does NOT memoise either store it may have to load: this is
  /// called from a SwiftUI body, and populating an observation-tracked
  /// dictionary there is a state mutation during view update. Reading them still
  /// registers the dependency, so the view refreshes when a sample lands; until
  /// one does, the cost is decoding one grid and a small dictionary.
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

  /// The raw map, live accumulator first. The health summary normalizes and drops
  /// `firstSample`, both of which the provenance record needs.
  func exposureMap(for persistenceKey: String) -> ExposureMap {
    accumulators[persistenceKey]?.map ?? loadExposureMap(for: persistenceKey)
  }

  /// The OLED Care pane's comparison section. Non-memoising, `healthSummary`'s
  /// rule and reason: called from a SwiftUI body, where populating an
  /// observation-tracked dictionary is a state mutation during view update.
  func modelComparison(for persistenceKey: String) -> ModelComparison {
    comparisons[persistenceKey] ?? loadModelComparison(for: persistenceKey)
  }

  /// The hero's live thermal view: the last accepted reading and when it
  /// landed. Nil until one lands this session; the caller must show its age,
  /// never present it as now.
  func latestSample(for persistenceKey: String) -> (cells: [Double], at: Date)? {
    latestSamples[persistenceKey]
  }

  /// The ghost overlay's window rectangles, display-local, from the same
  /// permission-free snapshot attribution uses. Empty until observation runs.
  func latestWindowSnapshots(for persistenceKey: String) -> [WindowSnapshot] {
    latestWindows[persistenceKey] ?? []
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
    // The comparison is derived from the same samples the map is, so the
    // delete that empties one must empty the other or the section keeps
    // scoring a history the user just removed.
    comparisons[persistenceKey] = .empty
    UserDefaults.standard.removeObject(forKey: Self.exposureKeyName(persistenceKey))
    UserDefaults.standard.removeObject(forKey: Self.ownerHoursKeyName(persistenceKey))
    UserDefaults.standard.removeObject(forKey: Self.modelComparisonKeyName(persistenceKey))
  }

  // MARK: - Entry points

  /// D28 shape: synchronous, main-actor, the ONLY pref entry point. Rebuilds
  /// each enrolled display's config from prefs; a display whose enrollment
  /// turned off loses its overlay and its engine. `persistenceKey` scoping is
  /// deliberately not exploited: the reconcile walks the whole (small) display
  /// list either way, and `updateConfig` from prefs is idempotent.
  func reapplyAfterPrefChange(persistenceKey _: String?) {
    guard let model, !model.isSafeMode, !resetting else { return }
    reconcileEnrollment()
    if driver != nil { tick() }
  }

  /// The topology loop's hook. IDs may have been REASSIGNED even with both
  /// displays still present, so the response is teardown plus re-render from
  /// state under freshly resolved IDs, never `repinFrames()` alone, which would
  /// pin an overlay to the wrong panel.
  func displaysReconfigured() {
    guard let model, !model.isSafeMode, !resetting else { return }
    clearAllOverlays()
    // Old IDs may already name different panels, so pending removal checks
    // keyed on them would ask the wrong question (the verifyRemoval rationale
    // below); the removeAll above re-closed every window we hold anyway.
    pendingRemovalVerifications = [:]
    // The sampler's held resolution is a raw ID and a reassigned ID is still
    // online, so liveness checks cannot save it. Drop it and let the next
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
    // reset that clears the OLED prefs must not leave a display sitting at a dim
    // level whose owner it just deleted (D29's ordering rule, in the brightness
    // register instead of the mute one).
    //
    // FIRST of the two blocks: only this one leaves the panel visibly wrong if
    // it is skipped, and the telemetry teardown below is bookkeeping. Recovery
    // before bookkeeping, the ordering D29 states for the mute strand.
    endAllLockDims()
    // Sampling stops BEFORE the prefs are wiped, never after (D29's ordering on
    // this path). The wipe removes the exposure keys, so a live accumulator
    // surviving it would write the deleted map back on its next debounce. The
    // epoch bump does the same for a capture already in flight.
    exposureEpoch += 1
    unsavedExposureKeys.removeAll()
    // The wipe removes the stored bytes the quarantine existed to protect, so
    // holding the flag past it would leave a display recording nothing forever
    // over a file that is already gone.
    unwritableExposureKeys.removeAll()
    accumulators.removeAll()
    ownerHours.removeAll()
    comparisons.removeAll()
    observers.removeAll()
    latestObservations.removeAll()
    latestSamples.removeAll()
    latestWindows.removeAll()
    // These removals delete the per-display state that would carry their OC12
    // marker, so verification rides the pending list instead: a blackout window
    // whose close the server ignores must not become unwatched at the exact
    // moment the prefs describing it are wiped. IDs are current, since no
    // reconfiguration has occurred.
    for state in states.values {
      if let id = state.lastDisplayID, state.lastAppliedAlpha != nil {
        pendingRemovalVerifications[id] = 0
      }
    }
    clearAllOverlays()
    states = [:]
    dimStates = [:]
    synthesisSuspensions = []
    checkupSuspensions = []
    for tracker in trackers.values { tracker.reset() }
    // Same reason, same moment: a live wear tracker's debounced write-through
    // would re-persist the histogram the wipe just removed.
    //
    // DISCARDED as well as reset, unlike `trackers`, because `flush()` writes
    // unconditionally: `reset()` alone leaves the object here, so the first
    // sleep or quit AFTER the latch clears re-creates `oledWearSeconds` as an
    // all-zero histogram, exactly what `reset()` promises not to leave behind.
    // (A `guard !resetting` in `flushExposureHistory` does NOT fix it: every
    // caller is already excluded by the latch.)
    for tracker in wearTrackers.values { tracker.reset() }
    wearTrackers.removeAll()
  }

  /// The per-display reset's opening move, paired with
  /// `displayResetDidComplete`: end this display's lock dim and hold its care
  /// work off while the reset drives the hardware. Scoped to one display, so
  /// every other display's dims, counters and overlays are untouched, which is
  /// why this is not `prepareForReset()`.
  func beginDisplayReset(_ key: String) {
    resettingDisplays.insert(key)
    guard let model,
          var state = states[key],
          let controller = model.displays
          .first(where: { $0.display.persistenceKey == key })?.controller
    else { return }
    endLockDim(&state, on: controller)
    clearSkip(for: key)
    states[key] = state
  }

  func displayResetDidComplete(_ key: String) {
    resettingDisplays.remove(key)
    guard let model, !model.isSafeMode else { return }
    reconcileEnrollment()
    if driver != nil { tick() }
  }

  /// The post-wipe half of the reset contract (paired with `prepareForReset()`):
  /// clears the latch and re-derives membership from the wiped domain. The latch
  /// swallows topology events, so somebody must reconcile once the wipe is real.
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
    // must not have hours keys written, or its note dismissal cleared, by a
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
    // would re-dim on the stale system idle counter, the defect the floor
    // exists to prevent.
    for key in states.keys { states[key]?.engine.noteWake() }
    tick()
  }

  // MARK: - Enrollment

  /// Rebuilds membership from the live display list and prefs: arrivals get a
  /// fresh `.active` engine, still-present displays get their config re-read,
  /// un-enrolled and departed displays lose overlay + engine (departures also
  /// standby their tracker, since the panel stopped being driven).
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
          // Tracking turned back ON: the since-standby counter froze during the
          // untracked period and the long-session note must not believe it.
          // noteStandby(), deliberately NOT reset(): reset would also destroy
          // the lifetime total, persistent wear data the user did not ask to
          // clear, while noteStandby zeroes exactly the counter the note reads.
          hoursTracker(for: key).noteStandby()
        }
        existing.hoursTracking = tracking
        existing.telemetryEnabled = prefs.oledTelemetry
        existing.windowObservationEnabled = prefs.oledWindowObservation
        // Turning detection dimming off must drop the nomination, not merely
        // stop consulting it. A retained mask would come straight back on the
        // next re-enable, built from a screen the user has since changed, and
        // until then it sits in the state as a live-looking value nothing
        // updates.
        existing.detectionDimmingEnabled = prefs.oledDetectionDimming
        // Dropped when EITHER producer stops, not just when detection dimming
        // is switched off. `renominate` only runs when a luminance sample lands,
        // so with telemetry off the last nomination would be rendered
        // indefinitely, dimming regions of a screen the user changed hours ago;
        // with observation off the staticness half freezes the same way. The
        // pane says "without them nothing is dimmed", and this makes it true.
        let hasProducers = existing.telemetryEnabled && existing.windowObservationEnabled
        if !existing.detectionDimmingEnabled || !hasProducers {
          existing.nominatedMask = nil
        }
        // The window ages go with it. `WindowObserver` holds a per-window
        // "unchanged since" instant and that clock keeps running while
        // observation is off, so a window that never moved would read as
        // stationary for the whole unobserved span and could be nominated on
        // the first sample after re-enabling.
        if !existing.windowObservationEnabled { forgetWindowObservation(for: key) }
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
    // Un-enrollment is the case that matters: the display is still connected,
    // and dropping the state that remembers the dim without ending it would
    // strand the panel dark with nothing left to restore it. A departed display
    // has no controller to write to, and its stored brightness was never
    // touched, so the next arrival's restore pass puts it back.
    if let controller = model?.displays.first(
      where: { $0.display.persistenceKey == key }
    )?.controller {
      endLockDim(&state, on: controller)
    }
    clearSkip(for: key)
    if let id = state.lastDisplayID {
      overlay.remove(for: id)
      // This removal deletes the state that would carry its OC12 marker, so the
      // verification rides the pending list: queued only when an overlay was up,
      // under an ID that was current when the window was driven. Un-enrollment
      // is not a reconfiguration, and that path clears this list before it
      // reconciles.
      if state.lastAppliedAlpha != nil {
        pendingRemovalVerifications[id] = 0
      }
    }
    dimStates.removeValue(forKey: key)
    // Paired with the removal above: the reason for a pause must not outlive
    // the pause. The tick rebuilds this set only while some display is
    // enrolled, so un-enrolling the last one would otherwise leave it standing.
    synthesisSuspensions.remove(key)
    checkupSuspensions.remove(key)
    // The hold goes with the state that would have honoured it: one nothing
    // ever releases would suspend care for the rest of the session if this
    // panel came back and enrolled again.
    checkupFieldHolds.remove(key)
    // Window ages describe how long a rect has been where it is ON THIS PANEL,
    // so a departure or an un-enrollment invalidates them for the reason
    // mirroring does. Both ACCUMULATORS stay: the map and the per-app
    // panel-seconds are wear data about the glass, and the panel comes back.
    // Written through first, so a dock cycle costs no history.
    forgetWindowObservation(for: key)
    saveExposureHistory(for: key)
  }

  // MARK: - The tick

  private func tick() {
    guard let model, !resetting else { return }
    // Drained independently of `states`: these entries outlive the state that
    // issued them by design (I-2), including across a reset.
    drainPendingRemovalVerifications()
    // Users who never enroll pay nothing past this line.
    guard !states.isEmpty else { return }
    let idleSeconds = OledCareSignalSources.systemIdleSeconds()
    let assertionHeld = OledCareSignalSources.displaySleepAssertionHeld()
    let isLocked = lockObserver.isLocked
    let topology = model.mirrorTopology.topology()
    let now = SuspendingClock.now
    // Focus is sampled only when some enrolled display wants unfocused dim, at
    // whatever cadence the loop is running, which IS the overlay-up cadence
    // whenever an overlay is up: a clicked display must not stay dimmed for
    // seconds. 0.46 ms per call [MEASURED], under 1% of a core at 10 Hz.
    let anyUnfocusedEnabled = states.values.contains(where: \.unfocusedDimEnabled)
    let focusedDisplay = anyUnfocusedEnabled ? focus.focusedDisplayID() : nil
    // ID to key resolved fresh every tick; IDs reassign and are never cached as
    // identity. Uniquing defensively: two identical panels can collide on
    // persistenceKey, and a crash would be worse than one of them winning.
    let live = Dictionary(
      model.displays.map { ($0.display.persistenceKey, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    var published = dimStates
    // Built empty rather than copied from the published set: a display that
    // stopped being a synthesis slave simply does not get re-added, so a
    // disengage clears the sentence with no removal pass.
    var synthesisPaused: Set<String> = []
    // Built empty for the same reason: a field coming down clears the pause
    // with no removal pass.
    var checkupPaused: Set<String> = []

    for key in Array(states.keys) {
      guard var state = states[key] else { continue }
      guard let displayState = live[key] else {
        // Departed but not yet reconciled (the topology loop debounces ~1 s).
        // Nothing to render against; reconcileEnrollment owns the teardown. The
        // published entry goes NOW, so the pane cannot keep reading a stale
        // .idleDim/.blackout for a display that is gone.
        published.removeValue(forKey: key)
        continue
      }
      let id = displayState.id
      state.lastDisplayID = id
      let isMirrored = topology.displays.first { $0.id == id }?.isInMirrorSet ?? false
      // SS8's carve-out, from the one synthesis predicate (SS7) over the
      // stamped store topology. `isMirrored` still drives the engine, so the
      // pause is unchanged; `isUserMirrored` is what the wear counters and the
      // observer's ageing state key on, because a panel rendering a synthesized
      // size is lit and being worn and none of that can be reconstructed later.
      let isSynthesis = topology.isSynthesisSet(containing: id)
      let isUserMirrored = isMirrored && !isSynthesis

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

      // The unfocused clock: cleared ONLY by a focus visit to THIS display,
      // started when some other display holds focus. A nil sample HOLDS the
      // clock unchanged, the consumer half of FocusSampler's hold-last
      // contract. Zeroing on nil would drop a live unfocused dim on a transient
      // resolve failure (Spotlight frontmost, a Space transition) and not bring
      // it back for a full threshold.
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

      // Carried onto the state so `render` can apply the same gate to detection
      // dimming, which runs in `.active` and never passes through the engine's.
      state.assertionHeld = assertionHeld

      let showingCheckupField = checkupFieldHolds.contains(key)
      let newState = state.engine.tick(OledDimSignals(
        idleSeconds: idleSeconds,
        assertionHeld: assertionHeld,
        isLocked: isLocked,
        isMirrored: isMirrored,
        isHDRSettling: hdrSettling,
        unfocusedSeconds: unfocusedSeconds,
        isCheckupFieldShowing: showingCheckupField
      ))
      if isSynthesis, newState == .suspended { synthesisPaused.insert(key) }
      if showingCheckupField, newState == .suspended { checkupPaused.insert(key) }

      // Hours. SuspendingClock, not ContinuousClock: the delta must not book a
      // system-sleep span as awake panel time, and SuspendingClock does not
      // advance while the machine is suspended. Display sleep WITHOUT system
      // sleep is handled by the awake gate. A display the USER mirrored
      // accumulates nothing (OC13); a synthesis slave does accumulate (SS8),
      // which is why the gate reads `isUserMirrored` and not the suspension.
      //
      // Known over-count, documented in the pane's caption rather than fixed: a
      // panel blanked by DPMS keeps reporting `CGDisplayIsAsleep == false`, at
      // full resolution, with no reconfiguration, so hours accrue while it is
      // dark. MEASURED for a DDC `D6 set 4` write. That the monitor's OWN power
      // button reaches the same state is REASONED FROM that measurement, not
      // measured: a press may instead deassert hot-plug detect, which is a real
      // departure and is already handled. macOS exposes no signal that
      // distinguishes a soft-standby panel, and the one signal Candela had, its
      // own 0xD6 write, went with the power-off action A-15 cut.
      let awake = CGDisplayIsAsleep(id) == 0
      if state.hoursTracking {
        if state.wasAwake, !awake { hoursTracker(for: key).noteStandby() }
        if awake, !isUserMirrored, let last = state.hoursLastTick {
          let elapsed = Self.seconds(now - last)
          hoursTracker(for: key).noteTick(
            displayAwake: true, secondsSinceLastTick: elapsed
          )
          // OC20 rides the SAME gate and the SAME delta as panel hours, so the
          // two counters cannot disagree about how long a panel was on. Under a
          // synthesized size the state IS `.suspended` and both counters run
          // anyway (SS8), so the wear tracker's `.suspended` slot books the
          // seconds a panel spends lit behind Candela's own mirror.
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
      // Synthesis never crosses it (SS8), because the panel keeps showing the
      // windows those ages describe, only at a different size. Entry-only, so a
      // disengage does not fire it.
      if isUserMirrored, !state.wasMirrored { forgetWindowObservation(for: key) }
      state.wasMirrored = isUserMirrored
      // Telemetry rides this loop at its own cadence; `newState` is the
      // suspension authority, not a second reading of the same signals. The
      // target is built from THIS tick's topology sample, so the surface it
      // resolves and the `isSynthesis` verdict above describe one instant.
      let target = OledTelemetryTarget(panel: id, topology: topology)
      updateTelemetry(for: key, state: &state, dimState: newState, on: target, at: now)
      // Mutates the LOCAL copy, deliberately before this tick's render: the
      // sample path's `renominate` writes `states[key]` because it lands
      // between ticks, but a mid-tick write there would be clobbered by the
      // `states[key] = state` below.
      refreshNominationGeometry(for: key, state: &state, on: target, at: now)

      // OC12 ordering: last tick's mutation is verified BEFORE this tick's
      // render, so the check runs a full tick after the change it is checking,
      // never inline against a window server that lags AppKit by a run-loop turn
      // in both directions. Bounded (I-1): one nudge per detected mismatch, then
      // the marker is dropped with ONE summary log, since a mismatch surviving
      // ~500 ms of retries is structural. The next state change re-arms it.
      if state.needsVerify {
        switch verifyLastRender(of: state, on: id) {
        case .agreed:
          state.needsVerify = false
          state.verifyAttempts = 0
        case .settling:
          break
        case .mismatched where state.verifyAttempts + 1 >= Self.maxVerifyAttempts:
          state.needsVerify = false
          state.verifyAttempts = 0
          log.error("""
          OLED care overlay for display \(id, privacy: .public) still mismatched after \
          \(Self.maxVerifyAttempts, privacy: .public) reconcile attempts; giving up until the next state change
          """)
        case .mismatched:
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
    if synthesisPaused != synthesisSuspensions { synthesisSuspensions = synthesisPaused }
    if checkupPaused != checkupSuspensions { checkupSuspensions = checkupPaused }
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

  /// Dims that input can lift. A pending verification also runs the fast
  /// cadence but gives an input event nothing to do.
  private func anyDimUp() -> Bool {
    states.values.contains { $0.lastAppliedAlpha != nil || $0.lockDimEngaged }
  }

  // MARK: - Event-driven restore

  private static let inputEvents: NSEvent.EventTypeMask = [
    .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    .scrollWheel, .keyDown, .flagsChanged,
  ]

  /// Global monitor for input outside the app, local one for input delivered to
  /// it: the blackout overlay accepts clicks (OC15), which never reach a global
  /// monitor.
  private func armInputMonitor() {
    guard inputMonitors.isEmpty else { return }
    if let global = NSEvent.addGlobalMonitorForEvents(matching: Self.inputEvents, handler: { [weak self] _ in
      MainActor.assumeIsolated { self?.inputArrived() }
    }) {
      inputMonitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(matching: Self.inputEvents, handler: { [weak self] event in
      MainActor.assumeIsolated { self?.inputArrived() }
      return event
    }) {
      inputMonitors.append(local)
    }
  }

  private func disarmInputMonitor() {
    for monitor in inputMonitors { NSEvent.removeMonitor(monitor) }
    inputMonitors.removeAll()
  }

  /// Single-shot: a pointer move is a stream of events and a tick per event would
  /// run the loop at the input rate. The driver re-arms next turn if a dim is still up.
  private func inputArrived() {
    disarmInputMonitor()
    tick()
  }

  // MARK: - Lock dim (delivered on the wire, not by an overlay)

  /// THE lock-dim funnel: every engage and disengage in this type goes through
  /// here, and `.lockDim` is the only state that engages one.
  ///
  /// Delivery is a hardware dim because an overlay cannot do this job: MEASURED
  /// 2026-08-07, a `CGShieldingWindowLevel()` window does not render above the
  /// lock screen, and reports itself on screen while it is covered. The write
  /// goes through `BrightnessController`, so it inherits the one DDC writer, the
  /// coalescer's pacing, path selection and the poller's echo suppression. It
  /// never touches `brightness` or the store, so the restore is the user's own
  /// value by construction rather than by a copy kept correct here.
  private func deliverLockDim(
    _ dimState: OledDimState, into state: inout PerDisplay,
    for key: String, on displayState: AppModel.DisplayState
  ) {
    guard dimState == .lockDim else {
      endLockDim(&state, on: displayState.controller)
      clearSkip(for: key)
      return
    }
    // A display mid-reset drives its own hardware and waits for those writes to
    // land before it lets HDR back on; a dim engaged here would ride the same
    // queue behind the reset's back. The dim resumes on the next tick after
    // `displayResetDidComplete`, which is a second at most.
    guard !resettingDisplays.contains(key) else {
      endLockDim(&state, on: displayState.controller)
      return
    }
    let controller = displayState.controller
    // Re-asserted every tick rather than engaged once on the edge, and the
    // scope of that is exactly:
    //
    // - It DOES cover a display that got a REBUILT controller under it while
    //   locked (a reconfiguration reuses controllers, a replug does not). The
    //   fresh controller has no factor, so `beginTemporaryDim` applies.
    // - It does NOT repair a controller that still holds the dim but re-applied
    //   a leg from the wrong value: the unchanged-factor guard makes that call
    //   a no-op. That invariant lives inside `BrightnessController`.
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
  /// included, so passing the dim state's own alpha alongside a mask would scale
  /// every nominated cell by it: an idle dim of 0.5 with a 0.15 nomination would
  /// render 0.075 in the region and ZERO everywhere else, deleting the uniform
  /// dim the user asked for.
  private func render(_ dimState: OledDimState, into state: inout PerDisplay, on id: CGDirectDisplayID) {
    let stateAlpha = state.engine.alpha(for: dimState)
    let blackout = dimState == .blackout
    // `.active` DOES compose: detection dimming is the one care feature that
    // runs while the user is working, so it can require an overlay in a state
    // whose own alpha is nil. Four cases do not, each for its own reason:
    //   `.blackout`: OC17's rule, and there is no luminance left to spend.
    //   `.suspended`: OC13, and suspended means suspended. `renominate` keeps
    //     refreshing the mask under a synthesized size (telemetry runs through
    //     that suspension), so the nomination is current but still not rendered.
    //   `.lockDim`: delivered on the wire, not by the overlay (A-16 measured
    //     that a shielding window does not render above the lock screen), so a
    //     mask here would be an overlay nobody could see.
    //   assertion held: the same gate idle dimming has. A video player or a
    //     presentation holding a display-sleep assertion must not have its
    //     window dimmed under it, and `.active` never passes through the
    //     engine's own `mayShow`.
    let excluded = blackout || dimState == .suspended || dimState == .lockDim
    let nomination =
      (state.detectionDimmingEnabled && !excluded && !state.assertionHeld)
      ? state.nominatedMask : nil

    var alpha = stateAlpha
    var mask: OverlayMask.Oriented?
    if let nomination, let transform = Self.transform(for: id) {
      let composed = OverlayMask.uniform(stateAlpha ?? 0).darkened(by: nomination)
      if composed.isUniform {
        // **Collapse to the scalar path with the COMPOSED level, never to
        // `alpha = 1.0` with no mask.** A uniform composition is reachable
        // whenever every cell is nominated, and the overlay cannot make this
        // decision for us because `alpha`'s meaning depends on the mask being
        // there. Getting this wrong painted the panel opaque black.
        let level = composed.peak
        alpha = level > 0 ? level : stateAlpha
      } else {
        mask = composed.displayOriented(through: transform)
        // Safe ONLY because a mask is going with it, carrying absolute
        // per-cell opacity that this multiplies by 1.
        alpha = 1.0
      }
    }

    guard overlay.apply(alpha: alpha, mask: mask, blackout: blackout, on: id) else {
      // No NSScreen matched: nothing reached the screen, so there is nothing to
      // verify and no state to memoise. The next tick retries, and the overlay
      // rate-limits its own warning.
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

  /// Recomputes detection dimming's nomination for one display. Called when a
  /// new luminance sample lands; `refreshNominationGeometry` covers the window
  /// half between samples while a mask is displayed.
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
    guard states[key]?.windowObservationEnabled == true,
      let observation = latestObservations[key]
    else {
      // No window list means no staticness prior, and the conjunction is the
      // feature. The pref is checked as well as the value: a retained
      // observation from before the user switched it off is exactly as stale
      // as the nomination it would produce.
      states[key]?.nominatedMask = nil
      return
    }
    let panelGrid = transform.panelNativeGrid(fromDisplayGrid: grid, cols: cols, rows: rows)
    states[key]?.nominatedMask = StaticRegionDetector.nominate(
      recentGrid: panelGrid, observation: observation, thresholds: .default)
  }

  private enum VerifyOutcome {
    case agreed
    case mismatched
    /// A close the server has not finished reporting; neither an attempt nor a
    /// mismatch. Bounded by `OledOverlay.closeGrace`.
    case settling
  }

  /// OC12 reconcile, one tick after a mutation. `.agreed` when the window
  /// server agrees with the last render. On a missing wanted overlay the lever
  /// is `reassert(on:)` (NEVER a repeat apply, which is a no-op by construction
  /// against the overlay's memo) and re-verification waits for the NEXT tick:
  /// one nudge per detected mismatch, log, don't loop.
  private func verifyLastRender(of state: PerDisplay, on id: CGDirectDisplayID) -> VerifyOutcome {
    let wanted = state.lastAppliedAlpha != nil
    switch (wanted, overlay.verifyPresence(on: id)) {
    case (true, .absent):
      log.error("OLED care overlay for display \(id, privacy: .public) not on screen after apply; reasserting")
      overlay.reassert(on: id)
      return .mismatched
    case (false, .present):
      // A removal the server has not honoured: verifyPresence already
      // re-closed the strand and logged. Check again next tick.
      return .mismatched
    case (_, .closing):
      return .settling
    case (true, .present), (false, .absent):
      return .agreed
    }
  }

  /// Wholesale teardown (reconfiguration, system sleep, reset). `verifyRemoval`
  /// is true only when display IDs are known stable across the teardown (system
  /// sleep): after a reconfiguration the old IDs may name different panels, so a
  /// verify keyed on the new resolution would ask the wrong question.
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
      switch overlay.verifyPresence(on: id) {
      case .absent:
        pendingRemovalVerifications.removeValue(forKey: id)
      case .closing:
        break
      case .present where attempts + 1 >= Self.maxVerifyAttempts:
        pendingRemovalVerifications.removeValue(forKey: id)
        log.error("""
        OLED care overlay for display \(id, privacy: .public) still on screen after \
        \(Self.maxVerifyAttempts, privacy: .public) removal checks; giving up
        """)
      case .present:
        pendingRemovalVerifications[id] = attempts + 1
      }
    }
  }

  // MARK: - Telemetry

  /// The 60 s schedule, riding the driver loop. There is no second timer.
  ///
  /// The two halves share one clock but are gated by separate prefs, because
  /// window observation needs no permission and is the whole of the degraded
  /// mode.
  ///
  /// The window list is polled inline: it is the same
  /// `CGWindowListCopyWindowInfo` the focus sampler already makes on this loop
  /// [MEASURED 2026-08-06: 0.46 ms]. The luminance capture is not, since it
  /// suspends for ~70 ms across an `SCShareableContent` XPC round trip and the
  /// driver loop has to answer input inside 100 ms when an overlay is up. It
  /// goes to a ONE-SHOT task; the loop itself stays synchronous.
  private func updateTelemetry(
    for key: String, state: inout PerDisplay, dimState: OledDimState,
    on target: OledTelemetryTarget, at now: SuspendingClock.Instant
  ) {
    guard state.telemetryEnabled || state.windowObservationEnabled else { return }
    guard samplingQualifies(dimState: dimState, on: target) else { return }
    if let last = state.lastSampleAt, now - last < Self.samplingInterval { return }
    state.lastSampleAt = now

    // A degenerate transform does NOT reject the sample downstream:
    // `panelNativeGrid` re-bins on rotation alone and never looks at
    // `displaySize`, so a mid-reconfiguration display has to be gated here or it
    // accumulates normally into cells that mean nothing.
    guard let transform = Self.transform(target) else { return }

    // Both halves read the SURFACE. While a synthesized size is engaged the
    // desktop lives on the virtual display, so that is where the window
    // rectangles are as well as the pixels; pairing the panel's own bounds with
    // those rectangles would compute coverage against a space no window is in
    // and book the result as fact.
    if state.windowObservationEnabled {
      observeWindows(for: key, on: target.surface, through: transform)
    }
    if state.telemetryEnabled, !state.sampleInFlight {
      state.sampleInFlight = true
      captureExposure(for: key, on: target, through: transform)
    }
    persistExposureHistoryIfDue(at: now)
  }

  /// Re-checks the WINDOW half of a displayed nomination on the fast loop.
  ///
  /// On the sampling clock alone the mask stayed frozen against window geometry
  /// for up to a minute, so a dim sat on whatever slid under it after a move,
  /// which is what burn-in looks like. This re-reads the window list and re-runs
  /// the pure rule against the cached panel grid. Gated on a mask being
  /// DISPLAYED: a nomination appearing one slot late is fine, one lingering a
  /// slot too long is the defect.
  ///
  /// Books NOTHING. Owner hours accumulate at the nominal sampling interval
  /// per observation in `observeWindows`; booking here would multiply them by
  /// the refresh rate. Refreshing the shared observer is safe because its
  /// ages are wall-clock spans, not per-call accumulation.
  private func refreshNominationGeometry(
    for key: String, state: inout PerDisplay, on target: OledTelemetryTarget,
    at now: SuspendingClock.Instant
  ) {
    guard state.nominatedMask != nil, state.detectionDimmingEnabled,
      state.windowObservationEnabled
    else { return }
    if let last = state.lastNominationRefreshAt,
      now - last < Self.nominationGeometryInterval { return }
    state.lastNominationRefreshAt = now
    guard let transform = Self.transform(target),
      let cached = latestSamples[key]
    else { return }
    let windows = CGWindowListSource(displayID: target.surface).onScreenWindows()
    var observer = observers[key] ?? WindowObserver()
    let observation = observer.observe(windows, through: transform, at: Date())
    observers[key] = observer
    latestObservations[key] = observation
    latestWindows[key] = windows
    // `cells` is already panel-native (re-binned at accept time), matching
    // what `renominate` derives before calling the same rule.
    state.nominatedMask = StaticRegionDetector.nominate(
      recentGrid: cached.cells, observation: observation, thresholds: .default)
  }

  /// The panel-to-surface resolution against the topology AS IT STANDS NOW.
  ///
  /// Read fresh rather than carried: this is the re-check side, called after the
  /// capture's ~70 ms suspension, and its whole job is to notice that the world
  /// moved. The tick's own resolution comes from the sample the tick already
  /// took, so one tick never mixes two instants.
  ///
  /// No model means no topology, which resolves every panel to itself: the same
  /// degradation to the pre-seam behaviour `MirrorTopologyStore` documents, and
  /// the safe direction here, since a target that has stopped matching drops the
  /// sample.
  private func telemetryTarget(for id: CGDirectDisplayID) -> OledTelemetryTarget {
    OledTelemetryTarget(
      panel: id, topology: model?.mirrorTopology.topology() ?? MirrorTopology([]))
  }

  /// THE suspension verdict for telemetry, in one place and derived from the
  /// engine's own published state: `.suspended` IS mirrored (OC13), and every
  /// dim state is a panel that is not showing what a capture would measure.
  ///
  /// The one exception is a panel showing a synthesized size, decided by
  /// `OledTelemetryTarget` rather than here: telemetry is measurement, the panel
  /// is lit with no overlay over it, and its hours and wear signal already keep
  /// running through that suspension (SS8). A user mirror stays out.
  ///
  /// The lock is checked separately because lock dim is a PREF: a locked display
  /// with `oledLockDim` off sits at `.active` and is skipped regardless. Sleep
  /// and battery are the two conditions the engine takes no input from at all.
  ///
  /// **`CGDisplayIsAsleep` cannot see a panel blanked at the monitor itself, and
  /// this gate inherits that hole [MEASURED].** A DPMS-off panel stays in both
  /// display lists, keeps `CGDisplayIsAsleep` false and reports full resolution,
  /// so the check below passes over a dark panel and a capture returns the
  /// still-composited framebuffer. Panel hours over-count by a scalar; here the
  /// exposure map and the per-app attribution book wear against SPECIFIC cells
  /// and SPECIFIC apps that emitted nothing, and both are persisted.
  ///
  /// Bounded, not fixed, because a blanked panel is indistinguishable at every
  /// layer we can observe and does not self-recover (CLAUDE.md §2). HID idle
  /// time is the bound: with nobody typing, the engine leaves `.active` at the
  /// idle threshold and sampling stops. **The uncovered case is a second
  /// display**, where the user works on one panel while the other sits blanked,
  /// holding idle at zero. **A synthesized size widens that hole knowingly**:
  /// the engine's mirror input holds `.suspended` whatever the idle counter
  /// says. Do not "fix" this with a readback or a DPMS probe; see A-15 and §2.
  private func samplingQualifies(dimState: OledDimState, on target: OledTelemetryTarget) -> Bool {
    guard !resetting, target.samplingMayRun(dimState: dimState), !lockObserver.isLocked
    else { return false }
    // The panel's own sleep, never the surface's: a virtual display has no
    // panel to sleep, and the wear being measured is the glass's.
    guard CGDisplayIsAsleep(target.panel) == 0 else { return false }
    return !OledCareSignalSources.onLowBattery()
  }

  /// Display geometry for the transform, from `CGDisplayBounds`: the same source
  /// `CGWindowListSource` subtracts its origin from, so a window rect and a
  /// luminance cell land in one coordinate system. `NSScreen.frame` is
  /// bottom-left and would put every window on the wrong half of the panel.
  ///
  /// Nil, never a default, on a zero size or a rotation that is not a right
  /// angle: the first is a mid-reconfiguration reading and the second is one
  /// this feature declines to describe (RT7) rather than round into a
  /// scrambled wear history.
  // Internal, not private: the hero's ghost overlay maps window corners
  // through the same transform the accumulation paths use, one construction
  // for one convention.
  static func transform(for id: CGDirectDisplayID) -> PanelSpaceTransform? {
    transform(OledTelemetryTarget(panel: id, topology: MirrorTopology([])))
  }

  /// The telemetry path's transform: **geometry from the surface, rotation from
  /// the panel**. They differ only while a synthesized size is engaged, where
  /// the desktop is drawn on a virtual display and shown on the panel's glass.
  ///
  /// Size from the surface, because it normalizes coordinates and every
  /// coordinate this pass sees (window rectangles, the captured image) is in the
  /// surface's space. Rotation from the panel, because the wear space is the
  /// glass's manufactured orientation and only the panel has one.
  ///
  /// The mapping stays sound across the size change: `panelNativeGrid` re-bins
  /// proportionally and never reads `displaySize`, and the synthesized ladder
  /// holds each rung's aspect within 2 percent of native, so the re-bin carries
  /// at most that much skew. It TOLERATES the skew rather than correcting it. A
  /// rung that breaks aspect deliberately needs its own ruling here, not a
  /// silent fall-through into cells that no longer line up with the glass.
  static func transform(_ target: OledTelemetryTarget) -> PanelSpaceTransform? {
    let size = CGDisplayBounds(target.surface).size
    guard size.width > 0, size.height > 0 else { return nil }
    guard let rotation = DisplayRotation(degrees: CGDisplayRotation(target.panel))
    else { return nil }
    return PanelSpaceTransform(displaySize: size, rotation: rotation)
  }

  /// Constructed at the point of use rather than stored: the source is a display
  /// ID and one method, and IDs reassign across a replug. This cannot go stale,
  /// because the ID it gets is the one this tick resolved.
  private func observeWindows(
    for key: String, on surface: CGDirectDisplayID, through transform: PanelSpaceTransform
  ) {
    let windows = CGWindowListSource(displayID: surface).onScreenWindows()
    // Mutated IN PLACE: `observe` is mutating on a value type, and a local copy
    // would discard every window's age on return, so the stationary threshold
    // could never be reached.
    var observer = observers[key] ?? WindowObserver()
    let observation = observer.observe(windows, through: transform, at: Date())
    observers[key] = observer
    latestObservations[key] = observation
    latestWindows[key] = windows

    // OC18's attribution over time. Booked at the NOMINAL interval for the
    // exposure path's reason: an observation stands for one sampling slot, and
    // the wall-clock gap since the last one can be an hour if the panel was
    // locked. No epoch check, unlike `finishExposureCapture`: this path is
    // synchronous on the main actor, so a mid-capture delete has nothing in
    // flight to race.
    var owners = ownerHoursAccumulator(for: key)
    let before = owners.hours.totalSeconds
    owners.accumulate(observation, elapsed: Self.seconds(Self.samplingInterval))
    ownerHours[key] = owners

    // The model's other inputs run on this permission-free clock too, not only
    // beside a measured sample: the wallpaper source logs each recompute with
    // the Screen Recording preflight inline, which is the standing evidence that
    // the estimate's inputs stay readable while the grant is absent.
    let appearanceIsDark =
      NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    _ = wallpaper.panelGrid(for: surface, appearanceIsDark: appearanceIsDark, through: transform)
    // Only a booked observation dirties the store: an all-uncovered panel adds
    // nothing, and marking it dirty would re-encode an unchanged value.
    if owners.hours.totalSeconds > before { unsavedExposureKeys.insert(key) }
  }

  private func forgetWindowObservation(for key: String) {
    observers.removeValue(forKey: key)
    latestObservations.removeValue(forKey: key)
    latestWindows.removeValue(forKey: key)
  }

  /// **The capture reads the SURFACE, the result is booked to the PANEL.**
  /// ScreenCaptureKit does not list a mirrored display at all (measured: the
  /// panel is online, awake and reporting its native descriptor, and simply
  /// absent from `SCShareableContent.displays`), so asking for the panel while a
  /// synthesized size is engaged returns nil on every tick, forever, and the
  /// exposure map stops growing with nothing to say so.
  ///
  /// Attribution never rides the surface's own `persistenceKey`: a virtual
  /// display has no EDID, so its key is derived from a display ID that changes
  /// every time the display is recreated. The panel's key is the only stable
  /// identity in the pair, and booking to it once is also what keeps one desktop
  /// from being counted twice.
  private func captureExposure(
    for key: String, on target: OledTelemetryTarget, through transform: PanelSpaceTransform
  ) {
    let epoch = exposureEpoch
    log.debug("""
    OLED care: exposure capture issued for display \(target.panel, privacy: .public) \
    (surface \(target.surface, privacy: .public))
    """)
    // One shot, not a loop. `self` is deliberately not held across the await,
    // the driver loop's rule: the sampler is a separate object, so awaiting
    // through it retains the sampler and not this coordinator.
    Task { @MainActor [weak self] in
      guard let sampler = self?.sampler else { return }
      let sample = await sampler.sample(displayID: target.surface)
      self?.finishExposureCapture(sample, for: key, on: target, through: transform, epoch: epoch)
    }
  }

  /// Everything the capture's suspension can invalidate is re-checked here.
  /// ~70 ms is long enough for the display to lock, mirror, sleep, dim, be
  /// reconfigured, be un-enrolled, or have its history deleted, and a sample
  /// taken before any of those is exposure the panel did not emit.
  private func finishExposureCapture(
    _ sample: LuminanceSampler.Sample?, for key: String, on target: OledTelemetryTarget,
    through transform: PanelSpaceTransform, epoch: Int
  ) {
    states[key]?.sampleInFlight = false
    guard let sample, epoch == exposureEpoch else { return }
    // Re-resolved, never re-used: a synthesized size can be disengaged inside
    // the suspension, which moves the desktop back onto the panel and changes
    // both the surface the sample came from and the qualification that let it
    // run. An unequal target describes a machine the sample was not taken of,
    // so it is dropped rather than attributed.
    let current = telemetryTarget(for: target.panel)
    guard current == target else { return }
    let id = target.panel
    guard let state = states[key], state.telemetryEnabled, state.lastDisplayID == id,
      let dimState = dimStates[key], samplingQualifies(dimState: dimState, on: current)
    else { return }
    // Geometry can change under a capture without the display departing (a
    // rotation, a mode switch). The grid was reduced through the OLD geometry,
    // so it is binned rather than re-mapped through geometry it never saw.
    guard Self.transform(current) == transform else { return }

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
    // Re-binned once here for the live view and the pair; `accumulate` does
    // the same internally and does not expose its result.
    let panelGrid = transform.panelNativeGrid(
      fromDisplayGrid: sample.grid, cols: sample.cols, rows: sample.rows)
    latestSamples[key] = (panelGrid, Date())
    bookComparisonPair(for: key, on: current, measured: panelGrid, through: transform)
    // Detection dimming's luminance half nominates here, off the sampling clock:
    // the grid changes once a minute, so recomputing faster reaches the same
    // answer. The window half does NOT wait for it.
    renominate(for: key, grid: sample.grid, cols: sample.cols, rows: sample.rows,
               through: transform)
    log.debug("""
    OLED care: exposure sample accepted for display \(id, privacy: .public) \
    (\(accumulator.map.sampleCount, privacy: .public) total)
    """)
  }

  /// EM2: the modelled grid is booked only beside an accepted measured sample,
  /// so both sides of the comparison cover identical instants and a grant
  /// outage stops them together. Runs inside the accepted branch, so the
  /// epoch, pref, ID, transform and qualification re-checks have all passed.
  private func bookComparisonPair(
    for key: String, on target: OledTelemetryTarget,
    measured: [Double], through transform: PanelSpaceTransform
  ) {
    // A fresh list, not `latestObservations`: observation is a separate pref
    // and its last snapshot can be minutes old, while the model's claim is
    // about this instant. The call is the same sub-millisecond one the
    // observation path makes.
    //
    // Both inputs come off the SURFACE, like the measured side they are
    // compared against: the window rectangles are in its space, and a mirrored
    // panel has no `NSScreen` for the wallpaper lookup to match at all, so
    // asking about the panel here would compare a measured desktop against a
    // model that fell back to the appearance prior.
    let windows = CGWindowListSource(displayID: target.surface).onScreenWindows()
    let appearanceIsDark =
      NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let wallpaperCells = wallpaper.panelGrid(
      for: target.surface, appearanceIsDark: appearanceIsDark, through: transform)
    let modelled = ExposureModel.modelledGrid(
      inputs: ExposureModelInputs(
        windows: windows, wallpaperCells: wallpaperCells, appearanceIsDark: appearanceIsDark),
      through: transform)

    var comparison = comparisonStore(for: key)
    let before = comparison.pairCount
    // The NOMINAL interval, `finishExposureCapture`'s reason: a pair stands
    // for one sampling slot.
    comparison.addPair(
      measured: measured, modelled: modelled,
      elapsed: Self.seconds(Self.samplingInterval), at: Date())
    guard comparison.pairCount > before else {
      log.debug("""
      OLED care: comparison pair refused for display \(target.panel, privacy: .public)
      """)
      return
    }
    comparisons[key] = comparison
    unsavedExposureKeys.insert(key)
  }

  // MARK: - The checkup's field hold

  /// A checkup field is on this display: pause its care until the field comes
  /// down (`endCheckupField`). Idempotent, so a re-show over a field already up
  /// is not a second hold to release.
  ///
  /// Ticks straight away because the field is drawn the instant the caller
  /// returns and the loop is at its 2 s cadence whenever nothing is dimmed:
  /// without this an overlay stays on the panel for the first two seconds.
  func beginCheckupField(identityKey key: String) {
    guard checkupFieldHolds.insert(key).inserted else { return }
    guard let model, !model.isSafeMode, !resetting, driver != nil else { return }
    tick()
  }

  /// The field is down: care resumes from whatever the other signals say.
  ///
  /// No tick here, unlike `beginCheckupField`. The confirmation re-show hides
  /// the field and puts it straight back up inside one main-actor turn, so a
  /// tick between the two would flash an overlay for nothing.
  func endCheckupField(identityKey key: String) {
    checkupFieldHolds.remove(key)
  }

  /// Why this display's care is paused. One reader over both sets, so the
  /// surfaces that report the pause cannot answer differently.
  ///
  /// The checkup wins the tie, though the two cannot co-occur: a mirroring
  /// display is filtered out of the checkup's targets before it can be picked.
  func suspensionReason(for persistenceKey: String) -> OledCareSuspensionReason {
    if checkupSuspensions.contains(persistenceKey) { return .checkup }
    if synthesisSuspensions.contains(persistenceKey) { return .synthesizedSize }
    return .mirrored
  }

  // MARK: - The checkup's bookings

  /// CK17: every showing is booked to the display's exposure record with its
  /// on-time, as a uniform grid. Booked as EMISSION, not a sample: `sampleCount`
  /// counts 60 s readings and the OLED Care page says so, so an eight-second
  /// showing must not advance it. The sampling path's telemetry and dim/mirror
  /// guards are skipped: they ask whether a capture would describe the glass,
  /// and the panel wore this light whether or not anything is measuring.
  func bookCheckupShowing(identityKey key: String, luminance: Double, seconds: TimeInterval) {
    // A non-finite luminance would not be refused downstream: the grid builder
    // clamps with `min`/`max`, which pass a NaN straight through to full white.
    guard seconds.isFinite, seconds > 0, luminance.isFinite else { return }
    let transform = checkupBookingTransform(for: key)
    var accumulator = exposureAccumulator(for: key)
    accumulator.bookEmission(
      displayGrid: CheckupExposureBooking.panelGrid(luminance: luminance),
      cols: PanelGrid.cols, rows: PanelGrid.rows, through: transform,
      elapsed: seconds, at: Date())
    accumulators[key] = accumulator
    unsavedExposureKeys.insert(key)
    // Straight through, not the debounced flush: with nothing measuring, or in
    // safe mode, no sampling pass will carry this key to disk.
    saveExposureHistory(for: key)
    log.info("""
    checkup showing booked: \(key, privacy: .public) \(luminance, privacy: .public) \
    \(seconds, privacy: .public)s
    """)
  }

  /// The enrolled transform, then the live display list, then a stand-in whose
  /// size is never read: a uniform grid is invariant under every rotation.
  private func checkupBookingTransform(for key: String) -> PanelSpaceTransform {
    let id = states[key]?.lastDisplayID
      ?? model?.allControlledStates.first { $0.display.persistenceKey == key }?.id
    if let id, let transform = Self.transform(telemetryTarget(for: id)) { return transform }
    return PanelSpaceTransform(
      displaySize: CGSize(width: PanelGrid.cols, height: PanelGrid.rows), rotation: .standard)
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
    // `PanelHoursTracker`'s spelling: engine state, not a `PrefName` case, since
    // nothing routes accumulated wear through `SettingsActions`.
    "oledExposureMap.\(persistenceKey)"
  }

  private static func ownerHoursKeyName(_ persistenceKey: String) -> String {
    "oledOwnerHours.\(persistenceKey)"
  }

  private static func modelComparisonKeyName(_ persistenceKey: String) -> String {
    "oledModelComparison.\(persistenceKey)"
  }

  /// One live store per key, `hoursTracker(for:)`'s rule and reason.
  private func comparisonStore(for key: String) -> ModelComparison {
    if let existing = comparisons[key] { return existing }
    let comparison = loadModelComparison(for: key)
    comparisons[key] = comparison
    return comparison
  }

  /// `loadExposureMap`'s taxonomy, unchanged: quarantine what a later build
  /// could migrate, start over on junk.
  private func loadModelComparison(for key: String) -> ModelComparison {
    guard let data = UserDefaults.standard.data(forKey: Self.modelComparisonKeyName(key)) else {
      return .empty
    }
    do {
      return try JSONDecoder().decode(ModelComparison.self, from: data)
    } catch let failure as OledStoreDecodeFailure {
      quarantine(key, reason: "model comparison", failure: failure)
      return .empty
    } catch {
      log.error("""
      OLED care: stored model comparison for \(key, privacy: .public) is unreadable \
      (\(error.localizedDescription, privacy: .public)); starting over
      """)
      return .empty
    }
  }

  /// A `cells` array of the wrong length throws out of `ExposureMap.init(from:)`
  /// BY DESIGN, since decoding it would hand the health view a map that traps
  /// the first time it is indexed, so an unreadable store starts over rather
  /// than propagating.
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
  /// scaled down: a per-owner total nobody can decode is not worth propagating a
  /// failure over. The quarantine split is NOT scaled down, because the two
  /// stores share one dirty set and one write, so holding one back while
  /// overwriting the other would leave a display's history half-migrable.
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

  /// Both halves of a panel's exposure history, the per-cell map and the
  /// per-owner series, ride ONE dirty set: they are written on the same tick and
  /// destroyed by the same delete, so a second set would be state kept in
  /// agreement by discipline. Either store can legitimately be absent, because
  /// telemetry and window observation are separate prefs.
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
    if let comparison = comparisons[key] {
      if let data = try? JSONEncoder().encode(comparison) {
        UserDefaults.standard.set(data, forKey: Self.modelComparisonKeyName(key))
      } else {
        log.error("OLED care: could not encode the model comparison for \(key, privacy: .public)")
      }
    }
  }

  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds)
      + Double(duration.components.attoseconds) / 1e18
  }
}
