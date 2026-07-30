import CoreGraphics
import Observation
import os

/// Drag-perf diagnostics: one log line per post-coalescing pipeline stage
/// (target adoption, DDC write start/end). Cheap (~30 Hz during a drag) and
/// the fastest way to localize a "slider moves but hardware doesn't" report:
/// `log show --predicate 'subsystem == "com.rydersel.Candela"'`.
let dragPerfLog = Logger(subsystem: "com.rydersel.Candela", category: "dragperf")

/// Path-selection/HDR diagnostics (mode changes, boost engage/disengage,
/// settle completion, cache refreshes).
let pathLog = Logger(subsystem: "com.rydersel.Candela", category: "path")

/// The non-DDC brightness endpoints a controller can route through. `hdr`,
/// `shade` and `gamma` are optional: nil means the feature is degraded
/// (spec §6) — HDR routing/boost never engages, or the software leg silently
/// drops. The native applier is required; when the DisplayServices shim is
/// unavailable the app injects a closure that returns false. The DDC applier
/// is not held here — it is built per submit from the controller's writer
/// (Task 3), so `rebind(writer:)` takes effect on the very next write.
/// `readNative` is the native readback (re-review T10-B): role `.builtIn`
/// seeds from it at init and reads it in `refreshFromHardware` instead of DDC
/// (fork: `AppleDisplay.getAppleBrightness`); the app passes
/// `DisplayServices.getBrightness`, tests inject.
public struct BrightnessBackends {
  let applierNative: any BrightnessApplying
  let hdr: (any HDRToggling)?
  let shade: (any ShadeRendering)?
  let gamma: (any GammaApplying)?
  let readNative: (@Sendable (CGDirectDisplayID) -> Float?)?

  public init(
    applierNative: any BrightnessApplying,
    hdr: (any HDRToggling)?,
    shade: (any ShadeRendering)?,
    gamma: (any GammaApplying)?,
    readNative: (@Sendable (CGDirectDisplayID) -> Float?)? = nil
  ) {
    self.applierNative = applierNative
    self.hdr = hdr
    self.shade = shade
    self.gamma = gamma
    self.readNative = readNative
  }
}

/// Single source of truth for one display's brightness (spec §5: every input
/// funnels through here; every surface renders from `brightness`).
///
/// Task 6 path selection (fork order, dossier dimming-math §2/§10), evaluated
/// synchronously from cached state on every `setBrightness`:
/// 1. native (HDR mode set AND HDR live) → `.native` hardware leg, full range;
/// 2. force-software → software leg only, full range;
/// 3. combined (default) → `DimmingMath.combinedSplit` across both legs;
/// 4. combined disabled → `.ddc` hardware leg, full range.
@MainActor @Observable
public final class BrightnessController {
  public private(set) var brightness: Double = 1.0
  public private(set) var maxDDCValue: UInt16 = 100

  /// Mirror of `prefs.hdrMode`, published for the panel (`DisplayPrefs` is
  /// plain UserDefaults and not observable). Change it via `setHDRMode`.
  public private(set) var hdrMode: HDRMode

  /// True while boost mode holds HDR engaged. Computed (review I8): a stored
  /// latch would miss externally-toggled HDR; the boost engage arm flips
  /// `cachedHDRActive` optimistically/synchronously, so the engaging keypress
  /// already reads true here for its HUD.
  public var hdrBoostActive: Bool { hdrMode == .boost && cachedHDRActive }

  /// The fork's `usesNativeBrightness` gate (dossier §10): an HDR mode is set
  /// AND HDR is currently live. The second half is empirically load-bearing:
  /// with HDR off the MAG341C answers `DisplayServicesSetBrightness` with
  /// SUCCESS but changes nothing, so native must never be routed on mode alone.
  /// Role `.builtIn` is constitutively native (Task 10): the built-in panel
  /// has no DDC wire and no combined/software routing — every path-selection
  /// consumer (applyPaths, step's combined math, handleReconfigure) short-
  /// circuits to the native leg through this one gate.
  private var usesNative: Bool { role == .builtIn || (hdrMode != .off && cachedHDRActive) }

  /// Whether the display reports HDR capability — a published mirror of the
  /// async-refreshed cache (T10 fix round 1). Computed off the stored cache,
  /// so SwiftUI reads are observation-tracked and the panel's HDR menu can
  /// disable itself on non-HDR displays.
  public var supportsHDR: Bool { cachedSupportsHDR }

  /// HDR state caches, refreshed by async tasks (init, mode changes, boost
  /// transitions, `noteHDRStateMayHaveChanged`) and only ever *read* on the
  /// synchronous keypress/drag paths — never awaited there.
  private(set) var cachedHDRActive = false
  private(set) var cachedSupportsHDR = false

  /// True from an HDR transition's start until its ~2 s settle window ends;
  /// gates `isNativeActive()` (reviews I5/I15) so the poller stays away while
  /// the display blanks and re-modes.
  @ObservationIgnored private var settleInProgress = false

  /// Mutable so `rebind(writer:)` can swap in the writer a replugged display
  /// gets from rediscovery; the DDC applier is built per submit, so a swap
  /// takes effect on the very next write.
  @ObservationIgnored private var writer: any DDCWriting
  @ObservationIgnored private let backends: BrightnessBackends
  @ObservationIgnored private let prefs: DisplayPrefs
  @ObservationIgnored private let displayID: CGDirectDisplayID
  /// Explicitly nonisolated (immutable, Sendable) so `isNativeActive()` can
  /// answer from the poller's nonisolated context without an executor hop.
  @ObservationIgnored private nonisolated let role: DisplayRole
  private let coalescer: BrightnessWriteCoalescer
  @ObservationIgnored private var issuedGeneration: UInt64 = 0
  /// Read at submit time to stamp each `PendingWrite.epoch`. Default `{ 0 }`
  /// pairs with the coalescer's accept-everything default gate, so call sites
  /// that never install an epoch pair keep the M1 behavior.
  @ObservationIgnored private var epochProvider: @Sendable () -> UInt64 = { 0 }
  /// Last-written brightness is the only truth on write-only DDC panels, so it
  /// is persisted here and restored at init — without it the panel opens at
  /// the default on every launch.
  private let store: (any BrightnessStoring)?
  private let storageKey: String?

  /// Software-leg dedupe memo — the fork's `.SwBrightness` skip, critical at
  /// 60 Hz drag rates because every software apply reprograms the gamma table
  /// or shade. In-memory only, deliberately not pref-persisted like the
  /// fork's (review M35): a fresh controller always applies its first value.
  @ObservationIgnored private var lastAppliedSw: Double?

  /// Gamma-interference hook (Task 9 wires the monitor): invoked ONLY when
  /// the gamma backend — not the shade — is about to apply and the sw dedupe
  /// did not skip. The C1 clearing's restore-to-1.0 bypasses it on purpose:
  /// it is a restore, not a dim, and must never be suspected as interference.
  @ObservationIgnored public var preGammaApplyHook: (@MainActor () -> Void)?

  /// Expected-native echo slot (Task 7 contract; reviews I9/I15). One lock
  /// backs all three nonisolated poller accessors:
  /// - `value`/`generation`: every local native-leg write stores its value at
  ///   press/call time and bumps the generation, so adoptions queued before a
  ///   local write are discarded as stale (I9);
  /// - `nativeActive`: false from an HDR transition's start, true only when
  ///   the settle window has completed (I5/I15);
  /// - `converging`: an external adoption is still easing toward its target,
  ///   so the poller must not discard reads as echoes until the snap (M33).
  private struct EchoState: Sendable {
    var value: Double?
    var generation: UInt64 = 0
    var nativeActive = false
    var converging = false
  }

  private nonisolated let echo = OSAllocatedUnfairLock(initialState: EchoState())

  /// HDR settle window (ENGINEERING-NOTES: the display blanks and re-modes
  /// for ~2 s after an HDR toggle). Internal so tests can shrink it.
  @ObservationIgnored var settleDelay: Duration = .seconds(2)
  /// The in-flight boost engage/disengage task; tests await it to observe
  /// post-settle state deterministically.
  @ObservationIgnored private(set) var hdrTransitionTask: Task<Void, Never>?
  /// Init-time HDR cache refresh; tests await it before priming so two
  /// refreshes can't interleave and double-run the C1 clearing.
  @ObservationIgnored private(set) var initialHDRRefresh: Task<Void, Never>?
  /// Test seam: observes every hardware submit before the coalescer's own
  /// duplicate-skip (the boundary-walk tests assert at the submit level).
  @ObservationIgnored var _onSubmit: ((HardwareTarget) -> Void)?

  public init(
    writer: any DDCWriting,
    backends: BrightnessBackends,
    prefs: DisplayPrefs,
    displayID: CGDirectDisplayID,
    role: DisplayRole = .external,
    store: (any BrightnessStoring)? = nil,
    storageKey: String? = nil,
    legacyKey: String? = nil
  ) {
    self.writer = writer
    self.backends = backends
    self.prefs = prefs
    self.displayID = displayID
    self.role = role
    self.store = store
    self.storageKey = storageKey
    self.coalescer = BrightnessWriteCoalescer()
    self.hdrMode = prefs.hdrMode

    if role == .builtIn {
      // Role `.builtIn` bypasses the migration/first-run/park-at-s block
      // entirely (re-review T10-C): macOS owns built-in brightness across
      // launches, and a literal shared init would park a MacBook panel at s
      // every launch. Seed from a live native read instead (fallback 1.0);
      // never write the store.
      brightness = Double(min(max(backends.readNative?(displayID) ?? 1.0, 0), 1))
    } else {
      // Migration + first-run (scope decision 4; reviews I12/I13).
      let s = DimmingMath.switchingValue(fromPoint: prefs.combinedSwitchingPoint)
      var initial: Double
      if let store, let storageKey, let saved = store.savedBrightness(for: storageKey) {
        initial = min(max(saved, 0), 1)
      } else if let store, let storageKey, let legacyKey,
                let legacy = store.savedBrightness(for: legacyKey) {
        // One-time M2 → M3 migration: the legacy value was pure-DDC, which is
        // the upper [s, 1] band of the combined scale. The legacy key is left
        // in place and ignored from here on.
        initial = s + min(max(legacy, 0), 1) * (1 - s)
        store.saveBrightness(initial, for: storageKey)
      } else {
        // Fresh display (review I13): the fork's rule is s + convDDCToValue(100)
        // * (1 - s) = 1.0. The 0.5 property default would mean "hardware
        // minimum" on the combined scale.
        initial = 1.0
      }
      if !prefs.disableCombinedBrightness, initial < s {
        // Park-at-s, every launch (review I12): the termination hook removes
        // software dimming at quit, so restoring a software-zone value would
        // show un-dimmed glass under a low slider. Publish only — the store
        // keeps the saved value.
        initial = s
      }
      brightness = initial
    }

    if backends.hdr != nil {
      initialHDRRefresh = Task { [weak self] in
        await self?.noteHDRStateMayHaveChanged()
      }
    }
  }

  deinit {
    hdrTransitionTask?.cancel()
    // Ends the coalescer's drain loop (after any pending write lands) so the
    // coalescer and its task don't outlive the controller.
    coalescer.finishSubmissions()
  }

  // MARK: - Hardware readback

  public func refreshFromHardware() async {
    if role == .builtIn {
      // The built-in panel has no DDC wire — the native read is the only
      // truth (fork: `AppleDisplay.getAppleBrightness`). Publish only; no
      // store (macOS owns built-in brightness across launches).
      if let value = backends.readNative?(displayID) {
        brightness = Double(min(max(value, 0), 1))
      }
      return
    }
    // Under the native path the DDC brightness register is locked by the
    // monitor (and unreadable); adopting it would corrupt combined state.
    guard !usesNative else { return }
    guard let result = await writer.read(command: VCP.brightness), result.max > 0 else {
      return
    }
    maxDDCValue = result.max
    let raw = Double(min(result.current, result.max)) / Double(result.max)
    if !prefs.disableCombinedBrightness {
      // C2 (dossier §7): a readable panel's DDC value lives in the upper
      // [s, 1] band of the combined scale — adopting current/max directly
      // would map DDC 50% to "combined 0.5", i.e. DDC 0, corrupting the
      // store. DDC 0 is consistent with ANY software-zone value, so a zero
      // read keeps the saved value.
      guard result.current > 0 else { return }
      let s = switchingValue
      brightness = s + raw * (1 - s)
    } else {
      brightness = raw
    }
    // A readable panel's hardware value is truth, so the store must adopt it
    // too — otherwise the saved number goes stale and the next launch
    // restores an outdated brightness.
    persist(brightness)
  }

  // MARK: - Brightness input

  /// Synchronous by design: state updates immediately, hardware writes
  /// coalesce latest-wins — a 60 Hz slider drag must never queue stale DDC
  /// writes (each write holds the DDC actor for ~20 ms, more on retries).
  ///
  /// The hardware write must not require the main actor for any step after
  /// this call returns: during a slider drag the main run loop sits in
  /// event-tracking mode, which starves main-actor task execution until
  /// mouseup — so the handoff is a synchronous, nonisolated store into a
  /// lock-protected slot; the coalescer drains on the global executor. The
  /// software leg runs inline right here (also synchronous): that immediacy
  /// is the drag-smoothness payoff of software dimming.
  public func setBrightness(_ value: Double) {
    let clamped = min(max(value, 0), 1)
    brightness = clamped
    applyPaths(clamped)
    persist(clamped)
  }

  //  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
  /// One brightness-key step. The boost state machine consumes the press
  /// first (fresh presses at the range ends toggle HDR, fork
  /// `HDRBoost.consumeBrightnessKey`); otherwise one OSD-chiclet step (fork:
  /// `Display.calcNewBrightness`): 16 chiclets, quarter-chiclet bias,
  /// ceil-snap so off-boundary values snap in the direction of travel.
  /// `isFine` steps a quarter chiclet (Opt+Shift). The plain chiclet math
  /// runs on EVERY path (M2 transplant, plan scope decision 2);
  /// `DimmingMath.stepCombined` is wired only behind the app-level
  /// `separateCombinedScale` default (review M39).
  @discardableResult
  public func step(isUp: Bool, isFine: Bool, isFresh: Bool = true) -> Double {
    if let boosted = consumeBoostKey(isUp: isUp, isFresh: isFresh) {
      return boosted
    }
    let value: Double
    if prefs.separateCombinedScale, !usesNative, !prefs.forceSoftware,
       !prefs.disableCombinedBrightness {
      value = DimmingMath.stepCombined(current: brightness, isUp: isUp, isFine: isFine)
    } else {
      var stepSize: Double = (isUp ? 1 : -1) / 16.0
      let delta = stepSize / 4
      if isFine {
        stepSize = delta
      }
      value = min(max(0, (((brightness + delta) / stepSize).rounded(.up)) * stepSize), 1)
    }
    setBrightness(value)
    return value
  }

  // MARK: - Path selection

  /// The four-way fork contract (dossier §2/§10), decided synchronously from
  /// cached state — `cachedHDRActive` is never awaited on the drag path.
  private func applyPaths(_ value: Double) {
    if usesNative {
      // Local native-leg write: record the expected echo at call time (I15)
      // and invalidate any queued adoption (I9).
      echo.withLock { state in
        state.value = value
        state.generation += 1
        state.converging = false
      }
      submitHardware(.native(Float(value)), applier: backends.applierNative)
      return
    }
    if prefs.forceSoftware {
      applySoftware(value)
      return
    }
    if !prefs.disableCombinedBrightness {
      let split = DimmingMath.combinedSplit(value: value, switching: switchingValue)
      submitHardware(
        .ddc(raw: DimmingMath.valueToDDC(split.ddc, minDDC: 0, maxDDC: Double(maxDDCValue))),
        applier: DDCBrightnessApplier(writer: writer)
      )
      applySoftware(split.sw)
      return
    }
    submitHardware(
      .ddc(raw: DimmingMath.valueToDDC(value, minDDC: 0, maxDDC: Double(maxDDCValue))),
      applier: DDCBrightnessApplier(writer: writer)
    )
  }

  private func submitHardware(_ target: HardwareTarget, applier: any BrightnessApplying) {
    _onSubmit?(target)
    issuedGeneration += 1
    coalescer.submit(
      .init(target: target, applier: applier, epoch: epochProvider(), generation: issuedGeneration)
    )
  }

  /// The software leg, inline and synchronous on the main actor. `sw` is the
  /// raw 0…1 software value; the backend receives the transformed physical
  /// multiplier (dossier §3: the transform applies before any gamma/shade
  /// write). Deduped on the last-applied sw value.
  private func applySoftware(_ sw: Double) {
    guard lastAppliedSw != sw else { return }
    lastAppliedSw = sw
    let transformed = DimmingMath.swTransform(sw, allowZero: prefs.allowZeroSwBrightness, reverse: false)
    if prefs.avoidGamma {
      backends.shade?.setShadeAlpha(DimmingMath.shadeAlpha(fromValue: transformed), on: displayID)
    } else if let gamma = backends.gamma {
      preGammaApplyHook?()
      gamma.applyGammaScale(transformed, on: displayID)
    }
  }

  /// C1 (MUST-HAVE): run on EVERY transition into the native path —
  /// `setHDRMode(.alwaysOn)`, an externally-toggled HDR discovered by
  /// `noteHDRStateMayHaveChanged`, and boost engage. Without it the screen
  /// stays dimmed by a gamma table HDR ignores (gamma is broken under HDR)
  /// and the sw dedupe blocks recovery. The fork does this via
  /// `setSwBrightness(1)` on every mode change. Candela deliberately does
  /// NOT mirror the fork's clearing of the user's forceSw/avoidGamma prefs
  /// on entering always-on — those are per-display user choices (documented
  /// divergence).
  private func clearSoftwareLeg() {
    backends.shade?.removeShade(for: displayID)
    backends.gamma?.applyGammaScale(1.0, on: displayID)
    lastAppliedSw = nil
  }

  private var switchingValue: Double {
    DimmingMath.switchingValue(fromPoint: prefs.combinedSwitchingPoint)
  }

  private func persist(_ value: Double) {
    if let store, let storageKey {
      store.saveBrightness(value, for: storageKey)
    }
  }

  // MARK: - HDR state machine

  /// Panel entry point for the per-display HDR mode.
  public func setHDRMode(_ mode: HDRMode) async {
    // Role fence (T10 fix round 1, minor): HDR modes are external-display
    // machinery — the built-in is constitutively native already, and a call
    // here would persist a meaningless mode under the builtIn prefs key.
    guard role == .external else { return }
    let previous = hdrMode
    guard mode != previous else { return }
    let wasEngaged = cachedHDRActive
    prefs.hdrMode = mode
    hdrMode = mode
    pathLog.log("hdrMode \(previous.rawValue) -> \(mode.rawValue) display=\(self.displayID)")
    if mode == .alwaysOn {
      // Entering the native path: C1 clearing, then engage HDR and hold the
      // poller off until the settle window ends.
      clearSoftwareLeg()
      beginHDRTransition()
      let engaged = await backends.hdr?.setHDR(displayID: displayID, enabled: true) ?? false
      // Supersession guard (fix round 2): this body is a bare async func —
      // never stored in `hdrTransitionTask`, so `beginHDRTransition`'s cancel
      // cannot reach it, and the panel spawns one unserialized Task per menu
      // selection. If `hdrMode` moved while we were suspended, a newer
      // setHDRMode owns the state now; mutating it here (stale rollback,
      // clearing the newer transition's settle flag, re-firing applyPaths)
      // would be the orphaned-continuation clobber class T6 closed for the
      // boost tasks.
      guard hdrMode == mode else { return }
      if engaged {
        cachedHDRActive = true
        try? await Task.sleep(for: settleDelay)
        guard hdrMode == mode else { return } // supersession guard, post-settle
        settleInProgress = false
        await refreshHDRCaches()
      } else {
        // Engage failed (T8 carry-over, adjudicated M3 blocker): the mode was
        // committed optimistically above, so roll BOTH the published mirror
        // and the pref back — otherwise a display that can't engage HDR
        // persists a lying `.alwaysOn` across launches and the badge/menu
        // misreport permanently. The C1 clearing already ran, so after the
        // caches settle, re-apply the current value through the normal path;
        // without it the screen is stranded un-dimmed under a low slider.
        // No `resetDuplicateState()` here (deliberate asymmetry vs the
        // disengage arm): a failed engage means no mode switch occurred, so
        // the last recorded DDC value still reflects the register.
        pathLog.error(
          "setHDRMode(.alwaysOn) engage failed: rolling back to \(previous.rawValue) display=\(self.displayID)"
        )
        prefs.hdrMode = previous
        hdrMode = previous
        settleInProgress = false
        await refreshHDRCaches()
        applyPaths(brightness)
      }
    } else if previous == .alwaysOn || (previous == .boost && wasEngaged) {
      // Leaving the native path: drop HDR, wait out the settle, then re-apply
      // the current value through the normal path. The duplicate memo is
      // reset first — hardware left HDR at its own brightness level, so the
      // last DDC value we recorded no longer reflects the register (I10).
      cachedHDRActive = false
      beginHDRTransition()
      _ = await backends.hdr?.setHDR(displayID: displayID, enabled: false)
      try? await Task.sleep(for: settleDelay)
      settleInProgress = false
      coalescer.resetDuplicateState()
      applyPaths(brightness)
      await refreshHDRCaches()
    } else {
      // Fourth door into the native path (review fix round 1, minor 3):
      // `.off → .boost` while HDR is already externally live. "Was native"
      // must be judged against the PREVIOUS mode — `hdrMode` is already
      // updated, and `cachedHDRActive` may already be true from an external
      // toggle — so entering here runs the C1 clearing like every other door.
      let wasNative = previous != .off && cachedHDRActive
      await refreshHDRCaches()
      if !wasNative, usesNative {
        clearSoftwareLeg()
      }
    }
  }

  /// Re-evaluates the cached HDR state (Task 4's topology loop calls this for
  /// every surviving display after `HDRToggling.displaysReconfigured()`).
  /// Detecting an externally-toggled HDR entry runs the C1 clearing.
  public func noteHDRStateMayHaveChanged() async {
    let wasNative = usesNative
    await refreshHDRCaches()
    if !wasNative, usesNative {
      clearSoftwareLeg()
    }
  }

  /// Reconfigure re-apply (review I11): the WindowServer rebuilt display
  /// state, so re-capture the gamma baseline (the app-side loop calls
  /// `resetAllGamma()` once per event BEFORE this, so the table is OS-owned —
  /// the T5 ordering contract), re-pin shade frames, and re-run the software
  /// leg for the current value. Skipped under the native path per C1.
  public func handleReconfigure() async {
    backends.gamma?.recaptureDefaultTable(on: displayID)
    backends.shade?.repinFrames()
    lastAppliedSw = nil
    guard !usesNative else { return }
    let sw: Double
    if prefs.forceSoftware {
      sw = brightness
    } else if !prefs.disableCombinedBrightness {
      sw = DimmingMath.combinedSplit(value: brightness, switching: switchingValue).sw
    } else {
      return // pure-DDC path has no software leg to re-apply
    }
    applySoftware(sw)
  }

  /// Fork `HDRBoost.consumeBrightnessKey` (HDRControl.swift:86-128): a fresh
  /// up-press at 100% engages HDR, a fresh down-press at 0 while engaged
  /// disengages. Returns the HUD value when the press was consumed, nil to
  /// step normally. Key-repeat NEVER toggles (fork contract) — the gate reads
  /// only cached state, so it costs nothing on the keypress path.
  private func consumeBoostKey(isUp: Bool, isFresh: Bool) -> Double? {
    // The boost gate requires `.external` (Task 10): the built-in never
    // routes HDR boost, so its steps must never consume a press.
    guard role == .external, hdrMode == .boost, cachedSupportsHDR, isFresh else { return nil }
    if !cachedHDRActive, isUp, brightness >= 0.999 {
      engageBoost()
      return 1.0
    }
    if cachedHDRActive, !isUp, brightness <= 0.001 {
      disengageBoost()
      return 1.0
    }
    return nil
  }

  private func engageBoost() {
    pathLog.log("boost engage display=\(self.displayID)")
    // Optimistic, synchronous flip (I8): the engaging press's HUD reads
    // hdrBoostActive == true in this very turn. Reverted with a log if the
    // spawned setHDR fails.
    cachedHDRActive = true
    clearSoftwareLeg() // C1, belt-and-braces
    beginHDRTransition()
    // Expected-native slot written at press time, not settle time (I15).
    echo.withLock { state in
      state.value = 1.0
      state.generation += 1
      state.converging = false
    }
    brightness = 1.0
    persist(1.0)
    let delay = settleDelay
    hdrTransitionTask = Task { [weak self] in
      guard let self, let hdr = self.backends.hdr, !Task.isCancelled else { return }
      let engaged = await hdr.setHDR(displayID: self.displayID, enabled: true)
      // Superseded by a newer transition: that transition owns the state now,
      // so bail before ANY side effect — including the failure revert (the
      // superseder already rewrote the caches this would clobber).
      guard !Task.isCancelled else { return }
      guard engaged else {
        pathLog.error("boost engage failed: setHDR(true) returned false; reverting display=\(self.displayID)")
        self.cachedHDRActive = false
        self.settleInProgress = false
        self.updateNativeActive()
        return
      }
      // Settle window: the display blanks and re-modes for ~2 s; only then
      // does the deferred native re-assert land (ENGINEERING-NOTES).
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self.settleInProgress = false
      self.submitHardware(.native(1.0), applier: self.backends.applierNative)
      await self.refreshHDRCaches()
    }
  }

  private func disengageBoost() {
    pathLog.log("boost disengage display=\(self.displayID)")
    cachedHDRActive = false // synchronous: native routing stops immediately
    beginHDRTransition()
    brightness = 1.0
    persist(1.0)
    // Hardware left HDR at its own brightness level — the duplicate memo's
    // last DDC value no longer reflects the register (review I10).
    coalescer.resetDuplicateState()
    let delay = settleDelay
    hdrTransitionTask = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      _ = await self.backends.hdr?.setHDR(displayID: self.displayID, enabled: false)
      // Superseded by a newer transition — no further side effects (see
      // engageBoost's task).
      guard !Task.isCancelled else { return }
      // Settle window before the hardware re-apply: a DDC write mid-modeswitch
      // is lost (ENGINEERING-NOTES).
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self.settleInProgress = false
      self.applyPaths(self.brightness)
      await self.refreshHDRCaches()
    }
  }

  /// Marks an HDR transition's start: the poller gate drops and any queued
  /// adoption is invalidated (the native leg's echo expectations no longer
  /// hold while the display re-modes).
  ///
  /// A new transition SUPERSEDES any in-flight settle task (review fix
  /// round 1): without the cancel, an orphaned engage task would clear
  /// `settleInProgress` mid-window and fire its deferred `.native(1.0)` after
  /// the state machine has already moved on (e.g. disengage or a panel
  /// `setHDRMode(.off)` inside the 2 s window).
  private func beginHDRTransition() {
    hdrTransitionTask?.cancel()
    settleInProgress = true
    echo.withLock { state in
      state.value = nil
      state.generation += 1
      state.nativeActive = false
      state.converging = false
    }
  }

  private func refreshHDRCaches() async {
    if let hdr = backends.hdr {
      cachedSupportsHDR = await hdr.supportsHDR(displayID: displayID)
      cachedHDRActive = await hdr.isHDREnabled(displayID: displayID)
    } else {
      cachedSupportsHDR = false
      cachedHDRActive = false
    }
    updateNativeActive()
  }

  private func updateNativeActive() {
    let active = usesNative && !settleInProgress
    echo.withLock { $0.nativeActive = active }
  }

  // MARK: - Poller contract (Task 7)

  /// Poller entry: eases the published value toward an externally-observed
  /// native brightness (Control Center, ambient) instead of jumping —
  /// dossier §10's asymptotic rule: snap within 0.01, else 1/3 of the gap
  /// with a 0.005 signed minimum step. Never submits a hardware write: the
  /// hardware already holds the external value, and writing back would fight
  /// its author.
  ///
  /// Returns the delta actually applied to published state — the eased step,
  /// not the full observed change, and 0 when the adoption was discarded as
  /// stale. `BrightnessSync` fans that delta out to the other displays.
  @discardableResult
  public func adoptExternal(_ value: Double, generation: UInt64) -> Double {
    // Generation check first (I9): an adoption queued before a local write
    // (e.g. during a starved drag) is stale — discard it entirely.
    let current = echo.withLock { $0.generation }
    guard current == generation else { return 0 }
    let previous = brightness
    let clamped = min(max(value, 0), 1)
    let diff = clamped - brightness
    let eased: Double
    let snapped: Bool
    if abs(diff) < 0.01 {
      eased = clamped
      snapped = true
    } else if diff > 0 {
      eased = brightness + max(diff / 3, 0.005)
      snapped = false
    } else {
      eased = brightness + min(diff / 3, -0.005)
      snapped = false
    }
    brightness = eased
    // DIVERGENCE (review M36): the fork persists the raw read; Candela
    // persists the eased value so published and stored state never diverge.
    persist(eased)
    echo.withLock { state in
      guard state.generation == generation else { return }
      state.value = eased
      state.converging = !snapped
    }
    return eased - previous
  }

  /// Poller echo check: the last locally-originated native value (or the
  /// adoption currently converging), generation-tagged so the poller can
  /// hand the generation back to `adoptExternal` (review I9).
  public nonisolated func expectedNative() -> (value: Double?, generation: UInt64) {
    echo.withLock { ($0.value, $0.generation) }
  }

  /// Poller gate: true only when the native path is active AND any HDR settle
  /// window has completed (reviews I5, I15). Constitutively true for role
  /// `.builtIn` (Task 10): the built-in is always on the native path and no
  /// HDR settle machinery ever runs for it.
  public nonisolated func isNativeActive() -> Bool {
    role == .builtIn || echo.withLock { $0.nativeActive }
  }

  /// True while an external adoption is still easing toward its target: the
  /// poller must keep polling (and not discard reads as echoes) until the
  /// snap fires (review M33).
  public nonisolated func isConvergingFromExternal() -> Bool {
    echo.withLock { $0.converging }
  }

  // MARK: - Plumbing

  public func waitForPendingWrites() async {
    await coalescer.waitUntilCompleted(through: issuedGeneration)
  }

  /// Swaps the stored DDC writer (used by both the hardware write leg and
  /// `refreshFromHardware`) after a display replug/rediscovery. The replugged
  /// hardware is in a state we didn't write, so the coalescer's duplicate
  /// memo is reset — otherwise re-asserting the current value would be
  /// skipped as a duplicate forever.
  public func rebind(writer: any DDCWriting) {
    self.writer = writer
    coalescer.resetDuplicateState()
  }

  /// Installs the display-reconfiguration epoch pair: `provider` is read at
  /// submit time to stamp each `PendingWrite`; `isCurrent` gates the drain so
  /// a write issued before a reconfiguration never lands on rebuilt hardware.
  public func setEpochProvider(
    _ provider: @escaping @Sendable () -> UInt64,
    isCurrent: @escaping @Sendable (UInt64) -> Bool
  ) {
    epochProvider = provider
    coalescer.setEpochGate(isCurrent)
  }

  /// Test seam: observes the coalescer's duplicate-memo reset counter (the
  /// disengage contract "duplicate memo reset recorded" is asserted with it).
  nonisolated func _duplicateResetCount() -> UInt64 {
    coalescer.duplicateResetCount()
  }
}

/// Drains hardware brightness targets off the main actor, coalescing
/// latest-wins: every write jumps straight to the newest target, as fast as
/// the hardware transaction allows (a DDC write's internal per-cycle sleeps
/// are the only pacing). Each target carries its own applier (DDC or native),
/// so one coalescer serves every hardware path. Deliberate product decision
/// (task-7 round 6): eased intermediate stepping made drags "feel slower" on
/// the MAG341C — the panel's DDC apply-path is the bottleneck, and the real
/// smoothness fix is M3 software dimming, not write-shaping.
///
/// Submission is a synchronous, nonisolated store into an
/// `OSAllocatedUnfairLock`-protected slot (newest-wins, the slot *is* the
/// pending-target buffer) — storing never requires an executor hop, so a
/// @MainActor caller can submit while the run loop is stuck in event-tracking
/// mode (the round-1 defect). The single drain loop dequeues the newest
/// target, so intermediates that arrive while a write is in flight are
/// dropped and the final value always lands. Each submitted target carries a
/// monotonic generation; `waitUntilCompleted(through:)` suspends until a
/// target with at least that generation has been applied or skipped (a newer
/// target superseding an older, dropped one completes the older generation
/// too — latest-wins).
actor BrightnessWriteCoalescer {
  struct PendingWrite: Sendable {
    let target: HardwareTarget
    /// Carried per write so one coalescer serves any hardware path — and so
    /// a controller-level `rebind(writer:)` takes effect on the next
    /// submitted write (the applier is rebuilt at submit, not held here).
    let applier: any BrightnessApplying
    /// Display-reconfiguration epoch stamped at submit time; the drain skips
    /// targets whose epoch is no longer current.
    let epoch: UInt64
    let generation: UInt64
  }

  private struct SubmissionState {
    var pending: PendingWrite?
    var finished = false
    var parkedDrain: CheckedContinuation<Void, Never>?
  }

  private enum NextAction {
    case target(PendingWrite)
    case finish
    case park
  }

  /// Newest-wins handoff slot shared with (nonisolated, synchronous) `submit`.
  private nonisolated let submissionLock = OSAllocatedUnfairLock(initialState: SubmissionState())

  /// Epoch gate consulted by the drain before applying. Lock-protected slot
  /// (same pattern as the submission slot) because the real checker is wired
  /// after construction via `setEpochGate`; the default accepts every epoch,
  /// which preserves M1 behavior for call sites without epochs.
  private nonisolated let epochGate: OSAllocatedUnfairLock<@Sendable (UInt64) -> Bool>

  /// Last target actually applied to hardware, for the duplicate-skip
  /// (round 2): re-sending the value already on the wire saturates the
  /// DDC/I2C bus for nothing. Compared via `HardwareTarget` `Equatable` —
  /// targets are what hit hardware, so the same target carried by a
  /// different applier is still a duplicate. `target` is `nil` until the
  /// first successful apply. Lives in a lock (not actor state) so
  /// `resetDuplicateState()` can clear it synchronously from any context.
  ///
  /// `resets` versions the memo against a reset racing an in-flight apply
  /// (review I1): a `resetDuplicateState()` that lands mid-apply must win
  /// over that apply's success — on a rebind the in-flight value reached the
  /// OLD hardware, so recording it would duplicate-skip the next same-value
  /// write to the new panel forever. The drain captures `resets` before
  /// applying and only records the target if no reset intervened.
  private nonisolated let lastApplied =
    OSAllocatedUnfairLock<(target: HardwareTarget?, resets: UInt64)>(initialState: (nil, 0))

  private var completedGeneration: UInt64 = 0
  private var waiters: [(generation: UInt64, continuation: CheckedContinuation<Void, Never>)] = []

  init(isEpochCurrent: @escaping @Sendable (UInt64) -> Bool = { _ in true }) {
    self.epochGate = OSAllocatedUnfairLock(initialState: isEpochCurrent)
    // Detached so the drain loop starts on the global executor regardless of
    // where the controller was created; a plain `Task {}` here could inherit
    // isolation from the initializing context.
    Task.detached { await self.drain() }
  }

  /// Installs the epoch checker post-init (nonisolated, synchronous — safe
  /// from the main actor without an executor hop). Governs every target
  /// drained after it lands in the slot.
  nonisolated func setEpochGate(_ isCurrent: @escaping @Sendable (UInt64) -> Bool) {
    epochGate.withLock { $0 = isCurrent }
  }

  /// Clears the duplicate memo (nonisolated, synchronous). A replugged
  /// monitor or an HDR exit returns hardware to a state we didn't write, so
  /// the memo must be clearable — otherwise the next write to the same value
  /// would be skipped forever (review I10).
  nonisolated func resetDuplicateState() {
    // Bumping `resets` invalidates any apply currently in flight — see the
    // `lastApplied` comment.
    lastApplied.withLock { $0 = (nil, $0.resets + 1) }
  }

  /// Test seam: the `resets` version counter (bumps once per
  /// `resetDuplicateState`).
  nonisolated func duplicateResetCount() -> UInt64 {
    lastApplied.withLock { $0.resets }
  }

  /// Synchronous and nonisolated on purpose — see the type comment.
  /// Generations must be issued monotonically by the (single) submitter.
  nonisolated func submit(_ write: PendingWrite) {
    let parked = submissionLock.withLock { state -> CheckedContinuation<Void, Never>? in
      guard !state.finished else { return nil }
      state.pending = write
      let parked = state.parkedDrain
      state.parkedDrain = nil
      return parked
    }
    parked?.resume()
  }

  /// Ends the drain loop once every already-submitted target has landed.
  nonisolated func finishSubmissions() {
    let parked = submissionLock.withLock { state -> CheckedContinuation<Void, Never>? in
      state.finished = true
      let parked = state.parkedDrain
      state.parkedDrain = nil
      return parked
    }
    parked?.resume()
  }

  /// Suspends until a target with generation >= `generation` has been written
  /// (or skipped as a duplicate or stale-epoch, or superseded). Returns
  /// immediately for generation 0 (nothing was ever submitted).
  func waitUntilCompleted(through generation: UInt64) async {
    guard generation > completedGeneration else { return }
    await withCheckedContinuation { waiters.append((generation, $0)) }
  }

  private func drain() async {
    while let write = await nextTarget() {
      dragPerfLog.log(
        "coalescer.target \(String(describing: write.target), privacy: .public) gen=\(write.generation)"
      )
      // Epoch gate: a target stamped before a display reconfiguration must
      // not land on rebuilt hardware — skip the applier, but still COMPLETE
      // the generation below (the M1 deadlock rule: every dequeued target
      // completes, so no waiter is ever left suspended). `lastApplied` does
      // not advance on a skip: the skipped target never hit hardware.
      let isEpochCurrent = epochGate.withLock { $0 }
      if isEpochCurrent(write.epoch) {
        // Duplicate-skip (round 2): never rewrite the target already on the
        // wire — duplicate re-sends saturate the bus for nothing. The
        // generation still completes.
        let memo = lastApplied.withLock { $0 }
        if write.target != memo.target {
          // Only a *successful* apply means the value is on the hardware.
          // Advancing `lastApplied` after a failed apply would make the next
          // identical target look like a duplicate and get skipped, leaving
          // brightness stuck at the old level until the user moved to a
          // different value. And only an apply with no intervening reset may
          // record its target: a reset that raced this apply means the value
          // landed on hardware we no longer trust (review I1) — the `resets`
          // captured in `memo` above detects that.
          if await write.applier.apply(write.target) {
            lastApplied.withLock { state in
              if state.resets == memo.resets {
                state.target = write.target
              }
            }
          }
        }
      }
      complete(write.generation)
    }
    // Drain exits only after `finishSubmissions` with the slot empty, and
    // every dequeued target completed its generation above — no waiter can
    // be left suspended.
  }

  /// Dequeues the newest target, parking (suspended, no polling) while the
  /// slot is empty. Returns nil once finished and empty.
  private func nextTarget() async -> PendingWrite? {
    while true {
      let action = submissionLock.withLock { state -> NextAction in
        if let pending = state.pending {
          state.pending = nil
          return .target(pending)
        }
        return state.finished ? .finish : .park
      }
      switch action {
      case let .target(pending):
        return pending
      case .finish:
        return nil
      case .park:
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          // Re-check under the lock before parking: a submit may have landed
          // between the dequeue attempt above and here.
          let resumeImmediately = submissionLock.withLock { state -> Bool in
            if state.pending != nil || state.finished {
              return true
            }
            state.parkedDrain = continuation
            return false
          }
          if resumeImmediately {
            continuation.resume()
          }
        }
      }
    }
  }

  private func complete(_ generation: UInt64) {
    completedGeneration = max(completedGeneration, generation)
    resumeSatisfiedWaiters()
  }

  private func resumeSatisfiedWaiters() {
    let satisfied = waiters.filter { $0.generation <= completedGeneration }
    guard !satisfied.isEmpty else { return }
    waiters.removeAll { $0.generation <= completedGeneration }
    for waiter in satisfied {
      waiter.continuation.resume()
    }
  }
}
