import CoreGraphics
import Observation
import os

/// Drag-perf diagnostics: one log line per post-coalescing pipeline stage
/// (target adoption, DDC write start/end). Cheap (~30 Hz during a drag) and
/// the fastest way to localize a "slider moves but hardware doesn't" report:
/// `log show --predicate 'subsystem == "com.rydersel.Candela"'`.
let dragPerfLog = Logger(subsystem: "com.rydersel.Candela", category: "dragperf")

/// Path-selection/HDR diagnostics (mode changes, settle completion, cache
/// refreshes).
let pathLog = Logger(subsystem: "com.rydersel.Candela", category: "path")

/// The non-DDC brightness endpoints a controller can route through. `hdr`,
/// `shade` and `gamma` are optional: nil means the feature is degraded
/// (spec §6) — HDR routing never engages, or the software leg silently
/// drops. The native applier is required; when the DisplayServices shim is
/// unavailable the app injects a closure that returns false. The DDC applier
/// is not held here — it is built per submit from the controller's writer
/// (Task 3), so `rebind(writer:panelIdentity:)` takes effect on the very next
/// write.
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

/// What a reset path learned about a display's HDR before it starts writing.
public enum HDRResetDisengage: Sendable, Equatable {
  /// The display was measured out of HDR after everything the disengage did,
  /// so the DDC register is not locked by HDR. `restoreAfterward` is true when
  /// HDR was live with no Candela mode recording it: someone set it elsewhere,
  /// and a reset that clears this app's settings hands it back at the end.
  case disengaged(restoreAfterward: Bool)
  /// The panel's HDR state is not known: another transition took the display
  /// mid-flight, or the drop was issued and the display did not leave HDR.
  /// A caller must neither write DDC on the strength of this nor re-engage,
  /// because both bet on a state nothing here established.
  case unknown
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
public final class BrightnessController: PendingWireDraining {
  public private(set) var brightness: Double = 1.0

  /// The maximum a panel is assumed to accept until it reports one of its own
  /// (fork parity). Named rather than repeated, because it is written in two
  /// places now — the initial value below and the reset in
  /// `rebind(writer:panelIdentity:)` — and a reset that drifted from the
  /// default would put a display into a state no freshly discovered display
  /// can be in.
  private static let assumedMaxDDC: UInt16 = 100

  public private(set) var maxDDCValue: UInt16 = BrightnessController.assumedMaxDDC

  /// What this display's brightness reads have proved (B3). Published so the
  /// diagnostics section can say "this display accepts commands but does not
  /// answer reads" rather than showing last-written values as though the panel
  /// had reported them.
  ///
  /// Scope: this is the verdict of the most recent pass that actually ASKED
  /// the panel something, not the worst thing ever observed on this display.
  /// The distinction is the whole correctness argument, so both halves:
  ///
  /// - A pass that attempts nothing must not touch it. `refreshFromHardware`
  ///   returns early under the native path, `unavailableDDC`, and role
  ///   `.builtIn` — a display that answered zeros once would otherwise look
  ///   pristine again simply because the next pass never reached the wire.
  ///   The assignments below therefore sit AFTER every such early return.
  /// - A pass that does ask supersedes the previous pass's verdict. A
  ///   monotonic worst-wins fold across passes reads "this display does not
  ///   reply" about a panel that just replied — a false sentence produced by
  ///   the feature built to stop false sentences. `worse` is still exactly
  ///   right for folding WITHIN a pass and across this display's sibling
  ///   controllers (`DDCReadEvidence.worst`); it was the scope of the fold,
  ///   never the ordering, that was wrong.
  ///
  /// This controller reads one code, once, per pass, so the within-pass fold
  /// here is trivial and the assignments are plain. `DDCValueController`,
  /// which retries, has to spell the fold out.
  public private(set) var readEvidence: DDCReadEvidence = .notAttempted

  /// Whether `maxDDCValue` came from the PANEL or is the assumed default
  /// (B5). `maxDDCValue` defaults to 100, which is indistinguishable from a
  /// real read of 100 — and on a write-only panel the assumption is always the
  /// true story. Presenting an assumed maximum as a reported one is exactly the
  /// honesty gap this feature exists to close, so the provenance is recorded
  /// beside the number rather than inferred from it.
  public private(set) var didReadMaxDDC = false

  /// Mirror of `prefs.hdrMode`, published for the panel (`DisplayPrefs` is
  /// plain UserDefaults and not observable). Change it via `setHDRMode`.
  public private(set) var hdrMode: HDRMode

  /// The fork's `usesNativeBrightness` gate (dossier §10), corrected by #52:
  /// HDR is currently live, WHOEVER engaged it — System Settings can turn HDR
  /// on with `hdrMode` still `.off`, and DDC writes cannot land there. The
  /// live-state half is empirically load-bearing the other way too: with HDR
  /// off the MAG341C answers `DisplayServicesSetBrightness` with SUCCESS but
  /// changes nothing, so native must never be routed on mode alone.
  /// Role `.builtIn` is constitutively native (Task 10): the built-in panel
  /// has no DDC wire and no combined/software routing — every path-selection
  /// consumer (applyPaths, step's combined math, handleReconfigure) short-
  /// circuits to the native leg through this one gate.
  ///
  /// Now a CALL into the shared table (B1) rather than a second copy of it: the
  /// rule and its evidence live in `BrightnessPathPolicy.usesNative`, which is
  /// pinned against the full table by
  /// `theStandalonePredicateAgreesWithTheTableEverywhere`.
  private var usesNative: Bool {
    BrightnessPathPolicy.usesNative(role: role, isHDRActive: cachedHDRActive)
  }

  /// Whether the display reports HDR capability — a published mirror of the
  /// async-refreshed cache (T10 fix round 1). Computed off the stored cache,
  /// so SwiftUI reads are observation-tracked and the panel's HDR menu can
  /// disable itself on non-HDR displays.
  public var supportsHDR: Bool { cachedSupportsHDR }

  /// Whether HDR is live on the display right now — published mirror of the
  /// async-refreshed cache, same pattern as `supportsHDR`. The panel's badge
  /// reads STATE from here; `hdrMode` is only the POLICY, so an externally
  /// toggled HDR (mode still `.off`) still reports engaged.
  public var isHDREngaged: Bool { cachedHDRActive }

  /// What is actually driving this display's brightness right now — the same
  /// answer `applyPaths` acts on, not a description of it (B1).
  ///
  /// Computed, not stored: it reads only cached scalars and prefs, and both of
  /// its invalidation signals already exist — `isHDREngaged` is observable, and
  /// any pref change bumps `prefsRevision`, which every pane body already reads.
  /// A stored mirror would need a third invalidation nobody would remember to
  /// fire, and a path that is stale is worse than no path at all: the whole
  /// point of the row is that it cannot lie.
  public var brightnessPath: BrightnessPath {
    BrightnessPathPolicy.path(pathInputs(tuning: prefs.tuning(for: .brightness)))
  }

  /// Takes the tuning as an argument rather than reading it: `applyPaths` runs
  /// on the 60 Hz drag path and already reads the tuning once for the DDC
  /// conversion, and `prefs.tuning(for:)` is six UserDefaults lookups plus a
  /// string parse. One read per call, as before this refactor.
  private func pathInputs(tuning: CommandTuning) -> BrightnessPathPolicy.Inputs {
    BrightnessPathPolicy.Inputs(
      role: role,
      isHDRActive: cachedHDRActive,
      forceSoftware: prefs.forceSoftware,
      avoidGamma: prefs.avoidGamma,
      disableCombinedBrightness: prefs.disableCombinedBrightness,
      unavailableDDC: tuning.unavailableDDC,
      switchingValue: switchingValue
    )
  }

  /// HDR state caches, refreshed by async tasks (init, mode changes,
  /// `noteHDRStateMayHaveChanged`) and only ever *read* on the
  /// synchronous keypress/drag paths — never awaited there.
  private(set) var cachedHDRActive = false
  private(set) var cachedSupportsHDR = false

  /// True from an HDR transition's start until its ~2 s settle window ends;
  /// gates `isNativeActive()` (reviews I5/I15) so the poller stays away while
  /// the display blanks and re-modes.
  @ObservationIgnored private var settleInProgress = false

  /// OLED care defers dim entry during a settle (OLED-care spec §8): an overlay
  /// applied while the display blanks and re-modes is dimming nothing, and the
  /// state machine would have to unwind it. Read-only.
  public var isHDRSettling: Bool { self.settleInProgress }

  /// Mutable so `rebind(writer:panelIdentity:)` can swap in the writer a
  /// replugged display gets from rediscovery; the DDC applier is built per
  /// submit, so a swap takes effect on the very next write.
  @ObservationIgnored private var writer: any DDCWriting
  /// Which physical panel `maxDDCValue`, `didReadMaxDDC` and `readEvidence`
  /// are evidence ABOUT — see `rebind(writer:panelIdentity:)`.
  @ObservationIgnored private var boundPanelIdentity: String?
  @ObservationIgnored private let backends: BrightnessBackends
  @ObservationIgnored private let prefs: DisplayPrefs
  /// Module-internal (not private) so in-module collaborators — `BrightnessSync`'s
  /// fan-out log — can name the display a controller belongs to.
  @ObservationIgnored let displayID: CGDirectDisplayID
  /// Sync's ambient-hunting deadband for the movement THIS controller has
  /// published as a source, advanced only by `BrightnessSync.fanOut`. It lives
  /// here rather than in a table beside the sync code so it shares the
  /// lifetime of the brightness it accumulates: a controller that goes away
  /// takes its residual with it, and nothing has to prune stale entries.
  ///
  /// That is lifetime, not identity. `performRefresh` reconciles on
  /// `CGDirectDisplayID` and REUSES the controller, so a display ID handed to
  /// a different panel arrives here as a rebind, and the residual is cleared
  /// in `rebind(writer:panelIdentity:)` alongside the other per-panel state.
  @ObservationIgnored var syncDeadband = SyncDeadband()
  /// Explicitly nonisolated (immutable, Sendable) so `isNativeActive()` can
  /// answer from the poller's nonisolated context without an executor hop.
  @ObservationIgnored private nonisolated let role: DisplayRole
  private let coalescer: BrightnessWriteCoalescer
  @ObservationIgnored private var issuedGeneration: UInt64 = 0
  /// The newest submit's TARGET, kept for `drainPendingWrites` to re-issue. The
  /// applier is deliberately not kept: see `resubmit`.
  @ObservationIgnored private var lastSubmittedTarget: HardwareTarget?
  /// Submits made by the drain's own retry. Excluded from `submissionMark` so a
  /// retry cannot look like someone else queueing work, which would make a round
  /// that retried unable to report a quiet wire even once it was quiet.
  @ObservationIgnored private var retriedSubmissions: UInt64 = 0
  /// Read at submit time to stamp each `PendingWrite.epoch`. Default `{ 0 }`
  /// pairs with the coalescer's accept-everything default gate, so call sites
  /// that never install an epoch pair keep the M1 behavior.
  @ObservationIgnored private var epochProvider: @Sendable () -> UInt64 = { 0 }
  /// The gate's other half, kept here as well as in the coalescer: a settle loop
  /// waits on it rather than on a clock. Default matches the coalescer's
  /// accept-everything default.
  @ObservationIgnored private var isEpochCurrent: @Sendable (UInt64) -> Bool = { _ in true }
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

  /// The 0…1 brightness portion this controller last SUBMITTED on the DDC leg,
  /// before tuning maps it onto the register, or nil while it has never driven
  /// that leg at all.
  ///
  /// The nil is as load-bearing as the number (#143). A register Candela has
  /// never written is a register the user set with the monitor's own buttons,
  /// and the hand-back must not stomp it; a register Candela drove to the
  /// combined-mode floor is one Candela owes back. Kept in the PORTION domain
  /// rather than the raw domain so `invert` and the min/max overrides cannot
  /// make "full range" mean different things on the two sides of the
  /// comparison: portion 1 is the brightest the panel is configured to go,
  /// whatever register value that lands on.
  @ObservationIgnored private var submittedDDCPortion: Double?

  /// The software side of a pref re-apply that is waiting for its register write
  /// to land (#146), or nil when nothing is held. Exposed (internal) so a test
  /// can await the handover instead of polling for it.
  @ObservationIgnored private(set) var heldSoftwareLeg: Task<Void, Never>?

  /// Supersession token for `heldSoftwareLeg`, in the shape `dimToken` already
  /// uses for the lock-dim ramp: anything that writes the software leg, clears
  /// it, or re-runs path selection invalidates a held re-apply, so a hold that
  /// resumes after the world moved on is a no-op rather than a stale write. The
  /// task is not cancelled, only disarmed; it still has to resume to let go of
  /// its continuation.
  @ObservationIgnored private var softwareLegToken: UInt64 = 0

  /// The engine boundary (DT15). Consulted for anything that needs a display
  /// with a DESKTOP — the shade window and the gamma activity enforcer — and
  /// never for the DDC or gamma write targets, which stay the raw panel ID.
  @ObservationIgnored private let mirrorTopology: any MirrorTopologyProviding

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
  /// Pause between the wire-settling rounds a restore runs before it re-engages
  /// HDR. Sized in `WireQuiescence` to outlast a reconfiguration's write gate;
  /// internal so tests can shrink it.
  @ObservationIgnored var wireSettlePause: Duration = .milliseconds(400)
  /// Monotonic supersession token for `setHDRMode`'s post-await mutations
  /// (final review wave). Comparing `hdrMode` instead is ABA-prone: a parked
  /// `.alwaysOn` call resumes to find the mode back at `.alwaysOn` after an
  /// `.off` → `.alwaysOn` round trip and waves its stale rollback through,
  /// clobbering the transition that actually owns the state. Bumped by every
  /// transition start (`beginHDRTransition`).
  @ObservationIgnored private var hdrTransitionGeneration: UInt64 = 0
  /// Init-time HDR cache refresh; tests await it before priming so two
  /// refreshes can't interleave and double-run the C1 clearing.
  @ObservationIgnored private(set) var initialHDRRefresh: Task<Void, Never>?
  /// Test seam: observes every hardware submit before the coalescer's own
  /// duplicate-skip (the boundary-walk tests assert at the submit level).
  ///
  /// The APPLIER rides along so the target/applier pairing is observable where
  /// it is chosen. Every mismatch this codebase can produce is born here, in
  /// `applyPaths`; the appliers' own guards only see it two layers later, as a
  /// dropped write and a log line (#148).
  @ObservationIgnored var _onSubmit: ((HardwareTarget, any BrightnessApplying) -> Void)?

  public init(
    writer: any DDCWriting,
    backends: BrightnessBackends,
    prefs: DisplayPrefs,
    displayID: CGDirectDisplayID,
    role: DisplayRole = .external,
    store: (any BrightnessStoring)? = nil,
    storageKey: String? = nil,
    legacyKey: String? = nil,
    panelIdentity: String? = nil,
    // Defaulted to an empty store, whose resolution is the identity function:
    // an unwired engine degrades to exactly today's behaviour. Appended LAST so
    // every existing construction site compiles unchanged.
    mirrorTopology: any MirrorTopologyProviding = MirrorTopologyStore()
  ) {
    self.mirrorTopology = mirrorTopology
    self.writer = writer
    self.backends = backends
    self.prefs = prefs
    self.displayID = displayID
    self.role = role
    // Seeded at construction so the FIRST rebind is not mistaken for a panel
    // swap; `nil` is the honest answer for callers with no notion of panel
    // identity, and nil == nil means they never reset on rebind.
    self.boundPanelIdentity = panelIdentity
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
      if !prefs.disableCombinedBrightness, !prefs.forceSoftware, initial < s {
        // Park-at-s, every launch (review I12): the termination hook removes
        // software dimming at quit, so restoring a software-zone value would
        // show un-dimmed glass under a low slider. Publish only — the store
        // keeps the saved value. forceSoftware displays are exempt (backlog
        // #4): their whole range IS the software leg, so the rationale never
        // applies and the park would silently raise brightness each launch.
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
    // Ends the coalescer's drain loop (after any pending write lands) so the
    // coalescer and its task don't outlive the controller.
    coalescer.finishSubmissions()
  }

  // MARK: - Hardware readback

  /// A read while WE hold a temporary dim reads our own write, not the user's
  /// value: the dim is a multiplier on the way to the hardware and never
  /// touches `brightness` or the store, so adopting the register back would
  /// fold it in permanently and `endTemporaryDim` would then "restore" to the
  /// corrupted number. Reached on every reconfiguration
  /// (`AppModel.performRefresh`'s kept branch), which a lock dim can outlast.
  public func refreshFromHardware() async {
    guard temporaryDimFactor == nil else { return }
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
    let tuning = prefs.tuning(for: .brightness)
    guard !tuning.unavailableDDC else { return }
    // Fork parity: reads use only the FIRST remap code.
    //
    // Split into three named outcomes (B3) where there used to be one `guard`
    // with a compound condition. No DDC traffic changes — same call, same
    // single attempt, same early returns — but "the panel never replied" and
    // "the panel replied with zeros" stop collapsing into the same silence.
    // Only the second is the MAG 341C's write-only signature, and the old
    // shape could not tell the diagnostics pane which one happened.
    //
    // Assignment, not a fold against the previous value: everything above this
    // line has already returned for the passes that ask nothing, so reaching
    // here means the panel WAS asked, and this pass's answer is the current
    // fact about it. Folding across passes instead published "does not reply"
    // about panels that had since replied (see `readEvidence`).
    guard let result = await writer.read(command: tuning.remapCodes.first ?? VCP.brightness) else {
      readEvidence = .noReply
      return
    }
    // `(0, 0)` and `max == 0` are FAILED reads, not a brightness of zero — the
    // MAG341C answers every read this way, and the fork's unvalidated read
    // clobbers saved values to 0. Recorded rather than merely rejected (B3).
    guard result.max > 0 else {
      readEvidence = .allZeros
      return
    }
    readEvidence = .answered
    maxDDCValue = result.max
    // B5: from here on `maxDDCValue` is the panel's own answer, not the 100
    // default. Set only on the answered arm — every other exit leaves the
    // assumption standing, and says so.
    didReadMaxDDC = true
    // Read mirrors write (fork convDDCToValue): un-apply curve/invert through
    // the same tuning, or a tuned readable panel adopts a corrupted
    // brightness at every launch. Identical to M3 when the tuning is unset
    // (curve 1.0, no invert, min 0, effective max = read max clamped to 100).
    let raw = DimmingMath.ddcToValue(
      result.current,
      minDDC: Double(tuning.minDDCOverride),
      maxDDC: Double(tuning.effectiveMaxDDC(readMax: Int(result.max))),
      curve: tuning.curveMultiplier,
      invert: tuning.invert
    )
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
    applyPaths()
    persist(clamped)
  }

  //  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
  /// One brightness-key step: one OSD-chiclet step (fork:
  /// `Display.calcNewBrightness`): 16 chiclets, quarter-chiclet bias,
  /// ceil-snap so off-boundary values snap in the direction of travel.
  /// `isFine` steps a quarter chiclet (Opt+Shift). The plain chiclet math
  /// runs on EVERY path (M2 transplant, plan scope decision 2);
  /// `DimmingMath.stepCombined` is wired only behind the app-level
  /// `separateCombinedScale` default (review M39).
  ///
  /// Stepping does not distinguish a fresh press from key-repeat — the HDR
  /// Boost gate that once needed that distinction is gone.
  @discardableResult
  public func step(isUp: Bool, isFine: Bool) -> Double {
    let value: Double
    if prefs.separateCombinedScale, !usesNative, !prefs.forceSoftware,
       !prefs.disableCombinedBrightness {
      value = DimmingMath.stepCombined(current: brightness, isUp: isUp, isFine: isFine)
    } else {
      // D3: one shared 16-chiclet step for brightness/volume/contrast
      // (DimmingMath.stepValue). Fine is flat ±0.01 — fork PARITY for plain
      // DDC externals (the fork's calcNewValue path, OtherDisplay.swift:509);
      // it diverges from Candela M2's every-path grid math, and from the
      // fork only on the native/forceSoftware paths, where the fork
      // grid-snaps fine at 1/64 (0.0156 vs 0.01 per press — imperceptible).
      value = DimmingMath.stepValue(current: brightness, isUp: isUp, isFine: isFine)
    }
    setBrightness(value)
    return value
  }

  // MARK: - Path selection

  /// The four-way fork contract (dossier §2/§10), decided synchronously from
  /// cached state — `cachedHDRActive` is never awaited on the drag path.
  ///
  /// The BRANCH now lives in `BrightnessPathPolicy` and this switches over its
  /// answer (B1). That is what makes the diagnostics pane structurally unable to
  /// drift from the engine: there is one table, and the engine is what runs it.
  /// The order the fork's contract depends on is preserved inside the policy,
  /// where it is pinned by `BrightnessPathPolicyTests`; a `switch` here is
  /// order-free by construction.
  ///
  /// **Takes no VALUE argument, deliberately.** Every leg has to derive from the
  /// same effective value, and a parameter is exactly how that broke once:
  /// `handleReconfigure` recomputed the software split from raw `brightness`
  /// and re-applied an UNDIMMED software leg while the DDC leg held a temporary
  /// dim, leaving a half-lifted dim on a locked screen that the coordinator's
  /// re-assert could not repair (`beginTemporaryDim` no-ops on an unchanged
  /// factor). With nothing to pass, a caller cannot pass the wrong thing. The
  /// `delivery` argument carries no value; it only says which legs this call is
  /// allowed to write, and both of them still derive from `effectiveBrightness`.
  ///
  /// Returns the DDC portion this call put on the register, or nil when the
  /// selected path wrote none. `reapplyAfterPrefChange` needs the direction the
  /// register moved in and must not re-derive it: a second site computing the
  /// combined split is a second copy of the table.
  @discardableResult
  private func applyPaths(_ delivery: LegDelivery = .both) -> Double? {
    supersedeHeldSoftwareLeg()
    let value = effectiveBrightness
    let tuning = prefs.tuning(for: .brightness)
    switch BrightnessPathPolicy.path(pathInputs(tuning: tuning)) {
    case .native:
      guard delivery.writesRegister else { return nil }
      // Local native-leg write: record the expected echo at call time (I15)
      // and invalidate any queued adoption (I9).
      echo.withLock { state in
        state.value = value
        state.generation += 1
        state.converging = false
      }
      submitHardware(.native(Float(value)), applier: backends.applierNative)
      return nil

    case .software:
      // `applySoftware` re-reads `avoidGamma` itself; the backend carried on the
      // path is for REPORTING. Left alone deliberately — routing the backend
      // through here would be a behaviour change wearing a refactor's clothes.
      if delivery.writesSoftware { applySoftware(value) }
      return nil

    case let .combined(switching, _):
      // No `unavailableDDC` guard here any more, and its absence is the point:
      // ruling R-A makes `.combined` unreachable with a dead DDC leg, so the old
      // inner `if !tuning.unavailableDDC` was dead code that also implied the
      // opposite. That state is `.softwareOnly` below, which is where the
      // skipped submit now lives.
      let split = DimmingMath.combinedSplit(value: value, switching: switching)
      var submitted: Double?
      if delivery.writesRegister {
        submitDDCBrightness(portion: split.ddc, tuning: tuning)
        submitted = split.ddc
      }
      if delivery.writesSoftware { applySoftware(split.sw) }
      return submitted

    case let .softwareOnly(_, .ddcTurnedOff, dimsBelow):
      // Combined mode with its DDC brightness command turned off: the register
      // write is skipped and the software leg still runs — but on the COMBINED
      // SPLIT value, never on the raw value. `applySoftware(value)` here would
      // silently convert this display to full-range software dimming, which is a
      // different feature. `PathSelectionTests` pins it under the name
      // `aDisabledBrightnessCommandWritesNoDDCButStillFixesTheSoftwareLeg`.
      if delivery.writesSoftware {
        applySoftware(DimmingMath.combinedSplit(value: value, switching: dimsBelow).sw)
      }
      return nil

    case .hardware:
      guard delivery.writesRegister else { return nil }
      submitDDCBrightness(portion: value, tuning: tuning)
      return value

    case .unavailable:
      // DDC brightness turned off with no software leg left to carry the value —
      // combined mode disabled, or combined mode with a zero-width software band.
      // The old code expressed the first of those as a bare `guard … else
      // { return }` and reached the second by handing the software leg a flat 1;
      // it is now a NAMED state the pane can report.
      return nil
    }
  }

  /// Which legs one `applyPaths` call may write.
  ///
  /// Only #146's ordering asks for anything but `.both`, and it asks for both
  /// halves in turn: the register alone first, then the software side once that
  /// write has landed. Nothing on the drag path ever splits them.
  private enum LegDelivery {
    case both
    case register
    case software

    var writesRegister: Bool { self != .software }
    var writesSoftware: Bool { self != .register }
  }

  /// M4 tuning on the DDC leg: min/max overrides, 9-step curve, invert. The
  /// effective max clamps the read max to 100 (fork DDC_MAX_DETECT_LIMIT) —
  /// with the default read max of 100 this is byte-identical to M3.
  private func brightnessRaw(_ portion: Double, tuning: CommandTuning) -> UInt16 {
    DimmingMath.valueToDDC(
      portion,
      minDDC: Double(tuning.minDDCOverride),
      maxDDC: Double(tuning.effectiveMaxDDC(readMax: Int(maxDDCValue))),
      curve: tuning.curveMultiplier,
      invert: tuning.invert
    )
  }

  /// The ONE door to the brightness register, so `submittedDDCPortion` cannot
  /// drift from what was actually put on the wire: a submit that recorded
  /// nothing would make the display look like one Candela never drove, and
  /// `handBackDDCLegIfAbandoned` would then leave it at the floor (#143).
  private func submitDDCBrightness(portion: Double, tuning: CommandTuning) {
    submittedDDCPortion = portion
    submitHardware(
      .ddc(raw: brightnessRaw(portion, tuning: tuning)),
      applier: brightnessApplier(tuning: tuning)
    )
  }

  private func brightnessApplier(tuning: CommandTuning) -> any BrightnessApplying {
    DDCCommandApplier(writer: writer, command: VCP.brightness, remapCodes: tuning.remapCodes)
  }

  private func submitHardware(_ target: HardwareTarget, applier: any BrightnessApplying) {
    _onSubmit?(target, applier)
    issuedGeneration += 1
    // Kept so a write the queue completed without applying can be re-issued,
    // with a fresh epoch stamp and a freshly built applier. Only the NEWEST
    // matters: an older one that never landed was superseded by this, which is
    // the value the panel should end up at.
    lastSubmittedTarget = target
    coalescer.submit(
      .init(target: target, applier: applier, epoch: epochProvider(), generation: issuedGeneration)
    )
  }

  /// Where this display's pixels actually are: itself, or its mirror master.
  /// Read fresh on every use — the topology is a sample of one instant and a
  /// cached copy would be a promise about a machine that has moved on.
  ///
  /// **In a mirror set, every member's controller resolves to the SAME id**, so
  /// they all drive one shade window and one gamma enforcer position, each
  /// memoising its own `lastAppliedSw` as applied. Two controllers therefore
  /// believe they own a surface only the last writer actually set. This is not a
  /// defect to fix: a mirror set is ONE framebuffer, so one dimming surface is
  /// the only physically meaningful answer — dimming a slave separately from its
  /// master is not a thing the hardware can do. Recorded because the memo makes
  /// it look like two independent applies succeeded, and someone reading
  /// `lastAppliedSw` for a slave will otherwise expect a surface of its own.
  private var drawableDisplayID: CGDirectDisplayID {
    mirrorTopology.drawableDisplayID(for: displayID)
  }

  /// The software leg, inline and synchronous on the main actor. `sw` is the
  /// raw 0…1 software value; the backend receives the transformed physical
  /// multiplier (dossier §3: the transform applies before any gamma/shade
  /// write). Deduped on the last-applied sw value.
  ///
  /// DT17: the dedupe memo is now written ONLY when the backend says the write
  /// landed. Before, `lastAppliedSw` was set before the backend was even asked,
  /// so a shade that could not be created (a mirror slave has no `NSScreen`)
  /// dimmed nothing and then deduped every identical retry away forever — the
  /// display stayed bright while the engine reported the value as applied.
  private func applySoftware(_ sw: Double) {
    supersedeHeldSoftwareLeg()
    guard lastAppliedSw != sw else { return }
    let transformed = DimmingMath.swTransform(sw, allowZero: prefs.allowZeroSwBrightness)
    let drawable = drawableDisplayID
    let landed: Bool
    if prefs.avoidGamma {
      // `?? true` is "no backend is configured, so there is nothing that could
      // have failed" — the same meaning the optional chain had before.
      landed = backends.shade.map {
        $0.setShadeAlpha(DimmingMath.shadeAlpha(fromValue: transformed), on: drawable)
      } ?? true
    } else if let gamma = backends.gamma {
      preGammaApplyHook?()
      // The WRITE target stays the RAW panel ID; only the enforcer resolves.
      landed = gamma.applyGammaScale(transformed, on: displayID, enforcerOn: drawable)
    } else {
      landed = true
    }
    if landed {
      lastAppliedSw = sw
    } else {
      // Left nil rather than set, so the next identical value is attempted
      // again instead of being deduped into silence.
      lastAppliedSw = nil
      pathLog.error(
        "Software dimming did not land on display \(self.displayID, privacy: .public) (drawable \(drawable, privacy: .public))"
      )
    }
  }

  /// C1 (MUST-HAVE): run on EVERY transition into the native path —
  /// `setHDRMode(.alwaysOn)` and an externally-toggled HDR discovered by
  /// `noteHDRStateMayHaveChanged`. Without it the screen
  /// stays dimmed by a gamma table HDR ignores (gamma is broken under HDR)
  /// and the sw dedupe blocks recovery. The fork does this via
  /// `setSwBrightness(1)` on every mode change. Candela deliberately does
  /// NOT mirror the fork's clearing of the user's forceSw/avoidGamma prefs
  /// on entering always-on — those are per-display user choices (documented
  /// divergence).
  private func clearSoftwareLeg() {
    // Not merely belt-and-braces over `applyPaths`: the engage arm clears the
    // leg and then AWAITS the HDR toggle, so a hold left armed here would fire
    // during that suspension and re-dim a display on its way into HDR.
    supersedeHeldSoftwareLeg()
    let drawable = drawableDisplayID
    backends.shade?.removeShade(for: drawable)
    backends.gamma?.applyGammaScale(1.0, on: displayID, enforcerOn: drawable)
    lastAppliedSw = nil
  }

  /// Native-entry brightness assert (hardware round 1): every door INTO the
  /// native path ends by re-submitting the published value on the native leg.
  /// Without it the display inherits whatever the DisplayServices register
  /// happened to hold — on the MAG341C, a leftover 0.5 from an earlier session
  /// — while the panel keeps showing the user's value.
  ///
  /// DIVERGENCE from the fork: the fork adopts that stale register instead and
  /// lets its poller drag the slider to the hardware. Spec §5 makes the
  /// controller the source of truth, so Candela pushes the other way. Going
  /// through `applyPaths` (not a bare submit) also writes the echo slot, so the
  /// poller reads the assert back as an echo rather than an external change.
  private func assertNativeEntryBrightness() {
    applyPaths()
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
    // #83: `.off` is actionable whenever HDR is LIVE, not only when Candela's
    // own mode says Candela engaged it. HDR turned on in System Settings leaves
    // `hdrMode` at `.off`, so a plain inequality guard returned early and left
    // the app with no path at all to drop HDR — while the reset paths that call
    // this were relying on it to unlock the DDC register before writing.
    //
    // The engage arm has handled the mirror-image case since backlog #8; this
    // is the exit catching up. Ruling: Candela's mode and the system's HDR state
    // stay in sync, so `.off` means the display leaves HDR whoever put it there.
    //
    // The inequality still guards the case it exists for — a mode the display
    // is ALREADY in is still a no-op, so a reset does not drive a pointless
    // re-mode across every attached panel.
    //
    // Symmetric on purpose. The panel's HDR button reads the STATE (#84), so
    // with HDR switched off in System Settings under a stale `.alwaysOn` the
    // button offers "HDR On" — and a mode-only guard would return early and
    // leave that click dead.
    //
    // NOT preceded by a refresh, though the cache can be stale (R3). That was
    // tried: an await here is a suspension point BEFORE `beginHDRTransition`
    // takes the supersession token, and it broke the overlapping-transition
    // guarantees. The engage arm's own post-refresh re-check remains the answer
    // to a stale cache. See #87.
    let observed: HDRMode = cachedHDRActive ? .alwaysOn : .off
    guard mode != previous || mode != observed else { return }
    prefs.hdrMode = mode
    hdrMode = mode
    pathLog.log("hdrMode \(previous.rawValue) -> \(mode.rawValue) display=\(self.displayID)")
    if mode == .alwaysOn {
      if cachedHDRActive {
        // Backlog #8: HDR is already live (externally toggled while mode was
        // .off) — no setHDR, no settle window (the state change already
        // happened; a 2 s window would just gate the poller off for nothing).
        // Generation bump at door entry (R3): a user-initiated transition
        // START supersedes any parked stale continuation; deliberately NOT
        // beginHDRTransition() — there is no re-mode, so settleInProgress
        // stays untouched.
        clearSoftwareLeg()
        hdrTransitionGeneration &+= 1
        let generation = hdrTransitionGeneration
        await refreshHDRCaches()
        guard hdrTransitionGeneration == generation else { return }
        if cachedHDRActive {
          assertNativeEntryBrightness()
          return
        }
        // Stale cache (R3): HDR was externally disabled between the panel's
        // last refresh and this call. Fall through to the normal engage arm
        // below — committing `.alwaysOn` without engaging (and with no
        // rollback) would persist a lying mode. clearSoftwareLeg re-runs
        // there harmlessly.
      }
      // Entering the native path: C1 clearing, then engage HDR and hold the
      // poller off until the settle window ends.
      clearSoftwareLeg()
      beginHDRTransition()
      let generation = hdrTransitionGeneration
      // ISSUED, not achieved (#65). The backend reports that it took the lock
      // and assigned `preferHDRModes`; whether the panel switched is a separate
      // question, and it is asked below after the settle.
      let issued = await backends.hdr?.setHDR(displayID: displayID, enabled: true) ?? false
      // Supersession guard (fix round 2; generation token final wave): this
      // body is a bare async func and the panel spawns one unserialized Task
      // per mode change, so nothing serializes them. If a newer transition
      // started while we were suspended, it owns the state now; mutating it
      // here (stale rollback, clearing the newer transition's settle flag,
      // re-firing applyPaths) would be an orphaned-continuation clobber.
      guard hdrTransitionGeneration == generation else { return }
      // The measured answer to "is this display in HDR now". A write that was
      // never issued cannot have achieved anything, so that arm skips the read
      // rather than paying for a panel enumeration to learn what it knows.
      var achieved = false
      if issued {
        // Optimistic for the settle window only: the poller is gated off and
        // the native leg has to believe it is live to hold the value.
        cachedHDRActive = true
        try? await Task.sleep(for: settleDelay)
        guard hdrTransitionGeneration == generation else { return } // post-settle
        settleInProgress = false
        await refreshHDRCaches(measured: true)
        guard hdrTransitionGeneration == generation else { return }
        achieved = cachedHDRActive
      }
      if achieved {
        assertNativeEntryBrightness()
      } else {
        // Engage failed (T8 carry-over, adjudicated M3 blocker): the mode was
        // committed optimistically above, so roll BOTH the published mirror
        // and the pref back — otherwise a display that can't engage HDR
        // persists a lying `.alwaysOn` across launches and the badge/menu
        // misreport permanently. The C1 clearing already ran, so after the
        // caches settle, re-apply the current value through the normal path;
        // without it the screen is stranded un-dimmed under a low slider.
        // No `resetDuplicateState()` here (deliberate asymmetry vs the
        // disengage arm): neither way of reaching this arm switched modes, so
        // the last recorded DDC value still reflects the register.
        //
        // TWO ways of reaching it, and they are different facts (#65). The
        // write was never issued (no panel, or the MonitorPanel lock was busy),
        // or it was issued, returned success, and the display did not switch.
        // The second is the class CLAUDE.md §2 names, and before #65 it was not
        // reachable at all: the arm was chosen from the write's own return.
        let reason = issued
          ? "was accepted and the display did not switch"
          : "was never issued"
        pathLog.error(
          "setHDRMode(.alwaysOn) \(reason, privacy: .public): rolling back to \(previous.rawValue) display=\(self.displayID)"
        )
        prefs.hdrMode = previous
        hdrMode = previous
        settleInProgress = false
        await refreshHDRCaches()
        guard hdrTransitionGeneration == generation else { return } // backlog #1: same fence as the success arm
        applyPaths()
      }
    } else {
      // Leaving the native path (`.alwaysOn` → `.off`, the only remaining exit
      // now that Boost is gone).
      beginHDRTransition()
      _ = await performHDRExit(generation: hdrTransitionGeneration)
    }
  }

  /// The exit sequence, with the transition token already taken by the caller:
  /// drop HDR, wait the settle out, re-apply the current value through the
  /// normal path, and leave the mirror holding a measured answer.
  ///
  /// The duplicate memo is reset first: hardware left HDR at its own brightness
  /// level, so the last DDC value we recorded no longer reflects the register
  /// (I10).
  ///
  /// Shared by the mode door and the reset door so the two cannot drift: what
  /// differs between them is only WHO decides there is something to do, and
  /// that decision is made before this runs.
  ///
  /// Returns whether it ran to the end. FALSE means a newer transition took the
  /// display mid-flight, so this call knows nothing about where the panel ended
  /// up: `cachedHDRActive` was set optimistically on the way in and the measured
  /// refresh at the bottom never ran. A caller that treats that as "HDR is off"
  /// is asserting the one thing it failed to learn.
  @discardableResult
  private func performHDRExit(generation: UInt64) async -> Bool {
    // Optimistic for the duration: the legs have to stop treating the display as
    // native while it leaves HDR.
    //
    // ONE RULE FOR EVERY BAIL BELOW: assume the register is LOCKED. A bail means
    // a newer transition took the display and this call established nothing, and
    // between the two available wrong answers only one can do damage. Believing
    // HDR is live routes brightness native, so nothing writes DDC and nothing
    // writes a gamma table onto a panel that may be in HDR; believing it is off
    // licenses both. The cost of being wrong this way is a brightness write that
    // goes nowhere on a DDC-only panel, and it is bounded: every transition that
    // can supersede this one ends with a measured refresh, and a reconfiguration
    // refreshes the mirror as well.
    //
    // These are the file's only post-fence mutations, and they are deliberate:
    // the fences exist to stop a stale call from asserting state it does not
    // know, which is exactly what leaving the optimistic false behind would be.
    cachedHDRActive = false
    _ = await backends.hdr?.setHDR(displayID: displayID, enabled: false)
    // Same supersession fence as the engage arm (final wave): the post-await
    // block clears `settleInProgress` and fires `applyPaths`, both of which
    // belong to whichever transition is current.
    guard hdrTransitionGeneration == generation else {
      cachedHDRActive = true // assume locked: see the rule above
      return false
    }
    try? await Task.sleep(for: settleDelay)
    guard hdrTransitionGeneration == generation else {
      cachedHDRActive = true // assume locked: see the rule above
      return false // post-settle
    }
    settleInProgress = false
    coalescer.resetDuplicateState()
    applyPaths()
    // Measured, for the reason the engage arm is: a write that returned success
    // is evidence of nothing. This arm does not roll back on a disengage that
    // did not take (that belongs to the stale-mode question, not here), but the
    // mirror it leaves behind is the panel's answer rather than the request's.
    await refreshHDRCaches(measured: true)
    return hdrTransitionGeneration == generation
  }

  /// The reset paths' HDR disengage: makes the DISPLAY leave HDR, and asks the
  /// display rather than the stored mode whether there is anything to do.
  ///
  /// Deliberately NOT `setHDRMode(.off)`. That door decides from the stored
  /// mode and the cached mirror, which is right for a request a person made
  /// about a policy and wrong here. The mirror lags a System Settings toggle
  /// until the reconfigure lands, and in that window every input the mode door
  /// consults says "already off" while the panel is in HDR: the request
  /// evaporates, the reset's own D29 unmute goes into a register the monitor
  /// still has locked, and a write-only panel ACKs the loss. So the physical
  /// state is measured here, past the backend's cache, and it is the only thing
  /// this decision reads.
  ///
  /// On an external display Candela's stored mode is cleared whatever the panel
  /// turns out to be doing: it is a setting, and clearing settings is what the
  /// button does. (The built-in has no HDR mode to clear and returns early.)
  ///
  /// The result is evidence, not a request. `.disengaged` is only reported off
  /// the back of a MEASURED read taken after everything this call did, and only
  /// when no other transition was seen driving this display, so a caller may
  /// treat it as "the register is not locked". Anything else is `.unknown`, and
  /// the caller must then neither write DDC nor re-engage, because a transition
  /// that raced this call can leave the panel in HDR while every optimistic
  /// mirror here says otherwise.
  ///
  /// The bound on that promise, stated rather than implied: it describes the
  /// display as of this call. Nothing here can stop a transition that begins
  /// after it returns, and the app's own reset latch does not cover the panel's
  /// HDR button. What this rules out is a reset proceeding on a state it never
  /// established.
  ///
  /// `alsoInvalidating` takes this display's other wire controllers, and it is
  /// as load-bearing as the disengage itself. Each queue skips a write whose
  /// value its memo says is already in the register, and under HDR an I2C write
  /// is ACKed and swallowed: a memo built through an HDR window therefore
  /// records values that never reached the panel. Left standing, the reset's own
  /// unmute would be skipped as a duplicate of a write that never landed, and
  /// the skip would be reported as applied. A rebind clears those memos too, but
  /// it is neither synchronous with this nor ordered before the unmute: it lands
  /// when a display is rediscovered, which is not a thing this path can wait
  /// for. Doing it here is what puts the clearing between the HDR window and the
  /// write that depends on it.
  public func disengageHDRForReset(
    alsoInvalidating siblings: [any PendingWireDraining]
  ) async -> HDRResetDisengage {
    defer {
      // Unconditional, including the built-in's early return and the
      // nothing-to-do arm: what makes a memo untrustworthy is the HDR window it
      // was built through, which is in the past by the time anyone asks.
      resetWriteMemo()
      for sibling in siblings { sibling.resetWriteMemo() }
    }
    guard role == .external else { return .disengaged(restoreAfterward: false) }
    // An observation, not a transition, so it takes the capture-and-compare
    // fence rather than the token: bumping the generation here would supersede
    // a transition still parked on its own await.
    let observed = hdrTransitionGeneration
    await refreshHDRCaches(measured: true)
    let wasLive = cachedHDRActive
    let raced = hdrTransitionGeneration != observed
    // Read AFTER the await, and cleared unconditionally. A transition landing
    // in the read window writes this mode, and a clear decided from the value
    // that predated it would skip: on the per-display path nothing else in the
    // reset touches this key, so the mode would survive the reset it exists to
    // be cleared by and re-engage HDR at the next launch.
    let previous = hdrMode
    prefs.hdrMode = .off
    hdrMode = .off
    pathLog.log(
      "reset HDR disengage: live=\(wasLive, privacy: .public) raced=\(raced, privacy: .public) mode \(previous.rawValue) -> 0 display=\(self.displayID)"
    )
    // Nothing to drop, and the measured read that says so is itself the
    // evidence the register is free. `raced` disqualifies it: the answer
    // describes a display another transition has since moved.
    if !wasLive, !raced { return .disengaged(restoreAfterward: false) }
    beginHDRTransition()
    let completed = await performHDRExit(generation: hdrTransitionGeneration)
    guard completed else {
      pathLog.error(
        "reset HDR disengage was superseded: display=\(self.displayID) HDR state is unknown, so nothing below may write DDC"
      )
      return .unknown
    }
    // `cachedHDRActive` is a measured answer here, and only here: the exit ran
    // to its own confirmation read.
    if cachedHDRActive {
      pathLog.error(
        "reset HDR disengage did not take: display=\(self.displayID) is still in HDR, so DDC writes below it would be swallowed"
      )
      return .unknown
    }
    // The drop took, and yet: something else was driving this display's HDR
    // while this ran, and it is free to drive it again the moment this returns.
    // A reset writes DDC on the strength of this answer, so the display has to
    // be one nobody else is touching, not merely one that measured off a moment
    // ago.
    guard !raced else {
      pathLog.error(
        "reset HDR disengage raced another transition on display=\(self.displayID): the drop took, but the state is not this call's to vouch for"
      )
      return .unknown
    }
    // The restore question, answered from the mode this reset found: HDR that
    // was live with nothing here recording it was set somewhere else, and this
    // reset borrowed it rather than owning it.
    return .disengaged(restoreAfterward: wasLive && previous == .off)
  }

  /// Puts back HDR that was live before a reset and that Candela did not turn
  /// on (#83), recording no mode for it.
  ///
  /// The reset paths drop HDR first so the DDC register is unlocked for the
  /// D29 unmute below them. That is not negotiable; what is, is whether the
  /// display stays out of HDR afterwards. Ruling: it does not, when the user
  /// engaged HDR in System Settings. A reset clears **Candela's** settings, and
  /// the display's HDR was never one of them.
  ///
  /// Which is also why this is not `setHDRMode(.alwaysOn)`: that persists
  /// `.alwaysOn`, so a reset promising to clear settings would end by writing
  /// one, and the app would then claim an opinion the user expressed somewhere
  /// else. Leaving `hdrMode` at `.off` under live HDR is the honest record, and
  /// it is a state the brightness path already handles (`usesNative` routes
  /// native under externally-engaged HDR).
  ///
  /// Otherwise the engage arm's machinery exactly: C1 clearing, the settle
  /// window with the poller gated off, and the measured check (#65). There is
  /// no rollback, because there is no mode to roll back to. A restore that does
  /// not take leaves the display where the disengage left it and says so.
  ///
  /// `alsoDraining` is load-bearing and not a convenience. Re-engaging HDR
  /// locks the DDC register, and a DDC submit is queued rather than sent: it
  /// rides a coalescer that drains on its own task, so the reset's unmute can
  /// still be in flight when this is called. Measured 2026-08-11: the queued
  /// writes reached the panel after the re-engage, the last of them more than a
  /// second later, and were swallowed while the app recorded an unmuted
  /// display, which is the strand D29 exists to prevent. So this settles its own
  /// queue and every controller handed to it (the caller's siblings on the same
  /// wire: volume, contrast) before the engage goes out. No default value on
  /// purpose: a caller with nothing in flight says so by passing an empty list.
  ///
  /// A queue that cannot be settled SKIPS the re-engage, loudly. That is the
  /// safe direction by a wide margin: the cost is a display left out of HDR
  /// that the user set in System Settings, visible and one click from fixed,
  /// against a monitor stranded silent behind a locked register with the app
  /// reporting it unmuted.
  public func restoreExternalHDR(alsoDraining siblings: [any PendingWireDraining]) async {
    guard role == .external else { return }
    guard await WireQuiescence.settle(
      [self] + siblings,
      betweenRounds: wireSettlePause,
      isWireOpen: { [weak self] in self?.isWireOpen ?? true }
    ) else {
      pathLog.error(
        "not re-engaging HDR on display=\(self.displayID): a queued write could not be confirmed as applied, and re-engaging would lock the register over it"
      )
      return
    }
    clearSoftwareLeg()
    beginHDRTransition()
    let generation = hdrTransitionGeneration
    let issued = await backends.hdr?.setHDR(displayID: displayID, enabled: true) ?? false
    guard hdrTransitionGeneration == generation else { return }
    if issued {
      cachedHDRActive = true
      try? await Task.sleep(for: settleDelay)
      guard hdrTransitionGeneration == generation else { return }
    }
    settleInProgress = false
    await refreshHDRCaches(measured: true)
    guard hdrTransitionGeneration == generation else { return }
    if cachedHDRActive {
      assertNativeEntryBrightness()
    } else {
      pathLog.error(
        "restoreExternalHDR did not take: display=\(self.displayID) was in HDR before the reset and is not now"
      )
      // The C1 clearing above took the software leg down for an HDR entry that
      // did not happen, so the screen would otherwise sit un-dimmed under a low
      // slider. Same recovery as the engage-failure arm.
      applyPaths()
    }
  }

  /// Re-evaluates the cached HDR state (Task 4's topology loop calls this for
  /// every surviving display after `HDRToggling.displaysReconfigured()`).
  /// Detecting an externally-toggled HDR entry runs the C1 clearing.
  public func noteHDRStateMayHaveChanged() async {
    let wasNative = usesNative
    // Capture only — this is a state *observation*, not a transition, so it
    // must not bump the token: an HDR toggle itself provokes a reconfigure,
    // and superseding here would strand the very transition that caused it
    // (its post-settle block would bail with `settleInProgress` stuck true).
    // Guarding still applies: a transition that started during the refresh
    // owns the state, so the entry work below is no longer ours to do.
    let generation = hdrTransitionGeneration
    await refreshHDRCaches()
    guard hdrTransitionGeneration == generation else { return }
    if !wasNative, usesNative {
      clearSoftwareLeg()
      assertNativeEntryBrightness()
    }
  }

  /// Reconfigure re-apply (review I11): the WindowServer rebuilt display
  /// state, so re-capture the gamma baseline (the app-side loop calls
  /// `resetAllGamma()` once per event BEFORE this, so the table is OS-owned —
  /// the T5 ordering contract), re-pin shade frames, and re-run the software
  /// leg for the current value. Skipped under the native path per C1.
  public func handleReconfigure(recapture: Bool = true) async {
    // recapture: false is the interference-accept path — at accept time the
    // interfering app may own the table, and capturing that as the baseline
    // bakes its curve in (poisoned-baseline amendment, progress.md:51). The
    // next real reconfiguration recaptures normally.
    if recapture {
      backends.gamma?.recaptureDefaultTable(on: displayID)
    }
    backends.shade?.repinFrames()
    lastAppliedSw = nil
    guard !usesNative else { return }
    // `effectiveBrightness`, never raw `brightness`: a reconfiguration during a
    // temporary dim (a replug, a sibling display's HDR flip, a bus drop) would
    // otherwise re-apply the software leg UNDIMMED while the hardware leg still
    // holds the dim, which on a locked screen is a partially lifted dim.
    let value = effectiveBrightness
    let sw: Double
    if prefs.forceSoftware {
      sw = value
    } else if !prefs.disableCombinedBrightness {
      sw = DimmingMath.combinedSplit(value: value, switching: switchingValue).sw
    } else {
      return // pure-DDC path has no software leg to re-apply
    }
    applySoftware(sw)
  }

  /// Marks an HDR transition's start: the poller gate drops and any queued
  /// adoption is invalidated (the native leg's echo expectations no longer
  /// hold while the display re-modes).
  ///
  /// Bumping the generation is what SUPERSEDES an older transition still
  /// parked on its own await: without it, the older call would clear
  /// `settleInProgress` mid-window and re-apply against state it no longer
  /// owns.
  private func beginHDRTransition() {
    hdrTransitionGeneration &+= 1
    settleInProgress = true
    echo.withLock { state in
      state.value = nil
      state.generation += 1
      state.nativeActive = false
      state.converging = false
    }
  }

  ///
  /// `measured: true` reads the panel now, past the backend's 2 s cache. Every
  /// decision about whether a transition ACHIEVED anything has to pass it (#65):
  /// the cached read is fine for keeping the mirror roughly fresh, and useless
  /// as evidence, because a cache filled during the transition would answer with
  /// the transition's own optimism.
  private func refreshHDRCaches(measured: Bool = false) async {
    if let hdr = backends.hdr {
      cachedSupportsHDR = await hdr.supportsHDR(displayID: displayID)
      cachedHDRActive = measured
        ? await hdr.measuredHDREnabled(displayID: displayID)
        : await hdr.isHDREnabled(displayID: displayID)
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

  public func submissionMark() -> UInt64 { issuedGeneration &- retriedSubmissions }

  public func drainPendingWrites() async -> Bool {
    // SNAPSHOT, never a re-read: `appliedThrough` is a suspension, and anything
    // submitted while it runs (a poller fan-out, a key, a dimming step) would
    // otherwise be compared against a generation nothing ever waited on. That
    // reads as a failure, retries a write that was never owed, and hands the
    // settle loop a false reason to decline the restore.
    let first = issuedGeneration
    await coalescer.waitUntilCompleted(through: first)
    if await coalescer.appliedThrough() >= first { return true }
    guard let target = lastSubmittedTarget else { return false }
    retriedSubmissions &+= 1
    resubmit(target)
    let second = issuedGeneration
    await coalescer.waitUntilCompleted(through: second)
    return await coalescer.appliedThrough() >= second
  }

  /// Re-issues a target the queue completed without applying, with the applier
  /// REBUILT rather than replayed. A rebind between the original submit and
  /// this one hands out a fresh `IOAVService`, and the captured applier still
  /// holds the old one: the retry would then write into a service that has been
  /// replaced, which either fails (and burns the settle's rounds) or is
  /// acknowledged by nothing that reaches the panel. Appliers are built per
  /// submit everywhere else for exactly this reason.
  private func resubmit(_ target: HardwareTarget) {
    switch target {
    case .ddc:
      submitHardware(target, applier: brightnessApplier(tuning: prefs.tuning(for: .brightness)))
    case .native:
      submitHardware(target, applier: backends.applierNative)
    }
  }

  /// Swaps the stored DDC writer (used by both the hardware write leg and
  /// `refreshFromHardware`) after a display rediscovery, and — only when
  /// `panelIdentity` says the panel on the other end has CHANGED — drops the
  /// three read-derived facts that were evidence about the old one.
  ///
  /// The coalescer's duplicate memo resets UNCONDITIONALLY: rediscovered
  /// hardware is in a state we did not write through the service we now hold,
  /// so re-asserting the current value must not be skipped as a duplicate
  /// (review I10). That is true of every rebind, panel swap or not, and is why
  /// it sits outside the identity check.
  ///
  /// WHAT RESETS ON A PANEL CHANGE, and why each one has to:
  ///
  /// - `didReadMaxDDC` (B5) was introduced write-once-true. A display that
  ///   replugs into a read-failing state would keep reporting "this maximum
  ///   was read from the panel" on the strength of a read from a previous
  ///   binding — the exact class of untruth the diagnostics work exists to
  ///   remove.
  /// - `readEvidence` (B3) goes back to `.notAttempted`, the floor: we have
  ///   asked THIS panel nothing. Not a weakening of worst-wins — that fold
  ///   governs a pass and this display's sibling controllers, and neither
  ///   survives a swapped monitor.
  /// - `maxDDCValue` back to `assumedMaxDDC`. Adding this one is a correction:
  ///   the earlier ruling reset the provenance flag and left the number, on
  ///   the grounds that the number feeds the write path. But that leaves the
  ///   motivating scenario alive on the write path itself — a previous panel
  ///   that reported 80 would leave the NEW panel's writes scaled against 80
  ///   indefinitely (the new panel never reports, so nothing ever corrects it)
  ///   while `didReadMaxDDC` says "assumed". Two facts about one number, only
  ///   one of them honest, and the dishonest one is the one on the wire.
  ///
  /// WHY A PANEL IDENTITY AND NOT THE WRITER. The first version of this reset
  /// fired on every `rebind` call. `AppModel.performRefresh` rebinds every
  /// KEPT display on EVERY pass — wake, reconfiguration, menu open — not only
  /// on replug, so that dropped a readable panel's reported maximum several
  /// times a session, with the recovering re-read a no-op unless
  /// `startupAction == .read` and useless on a write-only panel. Comparing the
  /// writer instead does not work: `DisplayDiscovery.discover()` builds a
  /// fresh `Arm64DDCService` per pass, and the `IOAVService` inside it is
  /// freshly created per pass too (a CFTypeRef compared by pointer), so
  /// neither object nor service identity is stable across a plain refresh.
  /// `Arm64Service.serviceLocation` is stable, but it names the PORT and so is
  /// unchanged in precisely the swap this reset exists for.
  ///
  /// `ExternalDisplay.persistenceKey` — EDID UUID, falling back to
  /// productName/manufacturer/serial — is what discovery already computes to
  /// tell panels apart, and is the key this controller's `storageKey` is
  /// derived from. Its known limitation is inherited: identical twins can
  /// share an EDID UUID and would not be told apart here (they already share a
  /// saved value and a prefs domain, so this is not the first casualty of
  /// that). The cost of the narrower trigger is that the SAME panel rebound
  /// through a DDC-hostile new route keeps its old verdict until the next read
  /// pass supersedes it — which, for this controller, is the very next refresh
  /// (`refreshFromHardware` here is ungated on `startupAction`).
  public func rebind(writer: any DDCWriting, panelIdentity: String?) {
    self.writer = writer
    if panelIdentity != boundPanelIdentity {
      boundPanelIdentity = panelIdentity
      maxDDCValue = Self.assumedMaxDDC
      didReadMaxDDC = false
      readEvidence = .notAttempted
      // Sync's held movement is about the panel that was moving, not the one
      // now on the wire.
      syncDeadband.reset()
    }
    coalescer.resetDuplicateState()
    // Dropped with the memo and for the memo's own reason: it names a write
    // issued through a service we no longer hold, so re-issuing it would put a
    // stale target on a fresh wire.
    lastSubmittedTarget = nil
  }

  /// Installs the display-reconfiguration epoch pair: `provider` is read at
  /// submit time to stamp each `PendingWrite`; `isCurrent` gates the drain so
  /// a write issued before a reconfiguration never lands on rebuilt hardware.
  public func setEpochProvider(
    _ provider: @escaping @Sendable () -> UInt64,
    isCurrent: @escaping @Sendable (UInt64) -> Bool
  ) {
    epochProvider = provider
    isEpochCurrent = isCurrent
    coalescer.setEpochGate(isCurrent)
  }

  /// Whether the wire is open right now: the same gate the coalescer consults
  /// before applying, asked ahead of time so a settle loop can wait for it
  /// instead of sleeping a guessed length of time.
  private var isWireOpen: Bool { isEpochCurrent(epochProvider()) }

  // MARK: - Startup/wake/quit restore (D5)

  /// Wake-restore prerequisite: without the memo reset, repeat passes are
  /// duplicate-skipped and never hit the wire.
  public func resetWriteMemo() {
    coalescer.resetDuplicateState()
  }

  /// D5's "stored (= ever-touched)" gate for the restore pass's brightness
  /// leg (fork isTouched; review R4): true once a session ever published a
  /// value for this display. Fresh displays publish an ASSUMED default (1.0)
  /// over an empty store — a restore pass must never write that.
  /// `AppModel.performRestorePass` checks this instead of reaching into the
  /// store. (A successful `.read` also persists, marking the command
  /// ever-touched — harmless: the restored value came from the panel itself.)
  public var hasStoredValue: Bool {
    guard let store, let storageKey else { return false }
    return store.savedBrightness(for: storageKey) != nil
  }

  // MARK: - Temporary dim (OLED care lock dim)

  /// A multiplier applied to the published value on its way to the hardware,
  /// or nil when nothing is dimming. Owned by whoever called
  /// `beginTemporaryDim`; OLED care's lock dim is the only caller today.
  ///
  /// Deliberately NOT expressed as a `setBrightness` to a lower value. That
  /// would overwrite `brightness` and the persisted store, which are the user's
  /// value and the only truth a write-only panel has: a crash or a force-quit
  /// while dimmed would then make the dim permanent, and a slider moved during
  /// the dim would have nothing to be restored to.
  ///
  /// Scope of the "a process that dies while dimmed still reopens correctly"
  /// claim: it is unconditional for a write-only panel, where the store IS the
  /// truth. On a panel that answers DDC reads (the Dell here), the hazard is a
  /// readback of a register we dimmed, and it is not confined to launch:
  /// `refreshFromHardware` also runs on every reconfiguration, which a lock dim
  /// outlasts. THIS process is covered, because that function returns early
  /// while a dim is outstanding. What is left is a readback by a process that
  /// did not set the dim: the next launch after a crash or force-quit, which
  /// finds the register still down with no factor recorded anywhere. The store
  /// is right either way; the readback is what would overwrite it.
  public private(set) var temporaryDimFactor: Double?

  /// The ONE place the temporary dim is folded in. Everything that computes a
  /// leg's value starts here; `brightness` is the user's number and is never
  /// what reaches the hardware while a dim is outstanding.
  private var effectiveBrightness: Double {
    brightness * (temporaryDimFactor ?? 1)
  }

  /// Supersession token for `rampTemporaryDim`. Bumped by every EXPLICIT change
  /// of the dim state, so an in-flight ramp that resumes after one is a no-op
  /// even if nobody cancelled its task. That is what makes "a restore is never
  /// re-dimmed by a step that was already in the air" a property of the type
  /// rather than of the caller's cancel ordering.
  @ObservationIgnored private var dimToken: UInt64 = 0

  /// Test seam: the ramp's step spacing. `LockDimRamp.stepInterval` in
  /// production; tests shrink it, exactly as they shrink `settleDelay`.
  @ObservationIgnored var lockDimRampInterval: Duration = LockDimRamp.stepInterval

  /// Applies a temporary dim immediately. Idempotent for an unchanged factor,
  /// and supersedes any ramp in flight.
  public func beginTemporaryDim(factor: Double) {
    dimToken &+= 1
    applyDimFactor(factor)
  }

  /// Fades the temporary dim to `target` over `LockDimRamp.duration`, applying
  /// the FIRST step synchronously so the dim starts on this turn of the run
  /// loop and `temporaryDimFactor` is non-nil the moment this returns (a caller
  /// polling it cannot catch a window where a ramp is running but no dim is
  /// recorded). The returned task carries the remaining steps.
  ///
  /// Cancelling the task stops it, but the token is what makes it SAFE: any
  /// `beginTemporaryDim`, `endTemporaryDim` or newer ramp invalidates this one,
  /// so a step that was already suspended when the user unlocked cannot land
  /// after the restore.
  @discardableResult
  public func rampTemporaryDim(to target: Double) -> Task<Void, Never> {
    dimToken &+= 1
    let mine = dimToken
    var remaining = LockDimRamp.factors(to: target)[...]
    if let first = remaining.first {
      applyDimFactor(first)
      remaining = remaining.dropFirst()
    }
    return Task { @MainActor [weak self] in
      for factor in remaining {
        let interval: Duration
        // Strong self confined to the non-suspending half of the iteration and
        // dropped before the sleep, the same shape the OLED care driver uses:
        // a binding whose scope covered the await would retain the controller
        // across every suspension.
        do {
          guard let self, self.dimToken == mine, !Task.isCancelled else { return }
          self.applyDimFactor(factor)
          interval = self.lockDimRampInterval
        }
        do { try await Task.sleep(for: interval) } catch { return }
      }
    }
  }

  /// Restores the published value exactly, immediately, and supersedes any ramp
  /// in flight. Deliberately NOT ramped: someone who has just unlocked wants
  /// their screen back now, and only the dim-in fades.
  ///
  /// Safe to call when nothing is dimmed (a no-op), which is what lets the
  /// teardown paths call it unconditionally: unlock, losing enrollment,
  /// settings reset and quit. Departure is NOT one of them: a departed
  /// display's controller is gone, so `endAllLockDims` skips it and the next
  /// arrival's restore pass is what puts the panel back.
  public func endTemporaryDim() {
    dimToken &+= 1
    guard temporaryDimFactor != nil else { return }
    temporaryDimFactor = nil
    lastAppliedSw = nil
    coalescer.resetDuplicateState()
    applyPaths()
  }

  /// The one place a dim factor is set. Private so the token discipline above
  /// cannot be bypassed: a public setter that skipped the bump would let a
  /// stale ramp step outlive the thing that superseded it.
  ///
  /// The memo clears run ONLY on the transition out of "no dim". Between ramp
  /// steps they would be waste: consecutive steps carry different values, which
  /// the duplicate memo and the software dedupe both let through on their own,
  /// and resetting per step defeats the memo's one useful job here (two ramp
  /// steps that round to the SAME register value should collapse to one write).
  /// The transition still needs them, for the reason `reapplyAfterPrefChange`
  /// gives: what should be on the wire changes while the published value does
  /// not, so a suppressed write would leave the display where it was.
  private func applyDimFactor(_ factor: Double) {
    let clamped = min(max(factor, 0), 1)
    guard temporaryDimFactor != clamped else { return }
    let starting = temporaryDimFactor == nil
    temporaryDimFactor = clamped
    if starting {
      lastAppliedSw = nil
      coalescer.resetDuplicateState()
    }
    applyPaths()
  }

  /// Re-asserts the current value on whatever path is live (the restore
  /// pass's brightness leg). Routed through `applyPaths`, not a bare submit,
  /// so the echo slot stays honest for the poller; the software leg re-apply
  /// dedupes to a no-op.
  ///
  /// Deliberately NOT gated on `hasStoredValue` — the R4 gate lives in
  /// `AppModel.performRestorePass`, which must skip this call for a display
  /// whose published value is still the assumed 1.0 default over an empty
  /// store.
  public func reassertHardware() {
    applyPaths()
  }

  // MARK: - Settings re-apply (D28)

  /// Which software backend the CURRENT prefs select, if any. Pure DDC and the
  /// native path have no software leg at all — that `.none` is exactly what
  /// `handleReconfigure`'s early `return` failed to act on.
  private enum SoftwareBackendChoice { case none, gamma, shade }

  /// A projection of the same table (B1) — the third copy of the rule, retired.
  ///
  /// `.softwareOnly` must answer with its backend exactly as `.software` and
  /// `.combined` do: folding it into `.none` would strand a scaled gamma table
  /// installed forever, because `reapplyAfterPrefChange` tears down only the
  /// backend this does NOT name.
  ///
  /// RECORDED BEHAVIOUR CHANGE, `.unavailable → .none`.
  /// `BrightnessPath` cannot tell apart the two engine states that reach
  /// `.unavailable(.ddcTurnedOffWithNoSoftwareLeg)`, and the pre-refactor
  /// prefs-shaped version answered them differently:
  ///
  /// - (A) combined DISABLED + `unavailableDDC` — answered `.none`, as here.
  /// - (B) combined ON + `unavailableDDC` + `switchingValue == 0` (pref point
  ///   −8, "pure hardware") — answered `.gamma`/`.shade`, because that arm keys
  ///   off `!disableCombinedBrightness` alone. This now answers `.none` too.
  ///
  /// Safe TODAY because the only consumer is `reapplyAfterPrefChange`, and in
  /// state (B) `combinedSplit`'s hardware branch always wins, so the software
  /// leg is pinned at `sw == 1` — "reset gamma to 1.0 / remove the shade" and
  /// "apply sw 1" land on the same screen. `PathSelectionTests` pins that
  /// equivalence rather than leaving it assumed
  /// (`combinedWithDDCOffAndAZeroWidthBandLeavesNoDimmingBehind`).
  ///
  /// It stops being safe the moment a consumer other than
  /// `reapplyAfterPrefChange` acts differently on `.none` than on
  /// `.gamma`/`.shade` — a backend-liveness readout, say, or anything that
  /// treats `.none` as "this display has no software leg configured" rather
  /// than "nothing needs to be left installed". At that point state (B) needs a
  /// distinguishable path, not a distinguishable branch here.
  private var softwareBackendChoice: SoftwareBackendChoice {
    switch BrightnessPathPolicy.path(pathInputs(tuning: prefs.tuning(for: .brightness))) {
    case .native, .hardware, .unavailable:
      .none
    case let .software(backend), let .combined(_, backend), let .softwareOnly(backend, _, _):
      backend == .overlay ? .shade : .gamma
    }
  }

  /// The ONE door for "a pref that affects dimming just changed" (D28).
  ///
  /// `handleReconfigure(recapture:)` is NOT that door and must not be used for
  /// it: it re-runs the software leg only, and returns before applying anything
  /// in pure-DDC mode. This entry point instead:
  ///
  /// 1. tears down whichever software backend the new prefs do NOT select —
  ///    `applySoftware` writes one backend and never clears the other, so
  ///    without this a gamma→shade switch double-dims and a switch to pure DDC
  ///    leaves a scaled table installed forever;
  /// 2. clears the software dedupe and the coalescer's duplicate memo, so a
  ///    re-apply at an unchanged value still reaches the wire;
  /// 3. re-runs FULL path selection for the current published value, writing
  ///    both legs (in the order the next-but-one paragraph fixes);
  /// 4. hands the brightness register back at full range if the new path has
  ///    stopped driving it (#143), which is the same obligation as step 1
  ///    applied to the OTHER leg: the abandoned backend has to be torn down,
  ///    and for DDC "torn down" means parked where software dimming assumes it
  ///    is rather than left at the combined-mode floor.
  ///
  /// The published `brightness` is untouched: a mode switch is a re-conversion
  /// of the same perceptual value, never a reset to 100% (D4).
  ///
  /// Deliberately does NOT recapture the gamma baseline: step 1 hands the table
  /// back at scale 1.0 whenever gamma is being abandoned, and a settings edit is
  /// not a WindowServer rebuild. (Re-capturing on settings edits is a possible
  /// refinement — the baseline can otherwise go stale for a user who never
  /// replugs — but it is a behavior change, not part of this fix.)
  ///
  /// STILL SYNCHRONOUS, which D28 requires, but the software side may now finish
  /// later than the call returns: see the ordering below.
  ///
  /// THE ORDERING (#146), which is one rule and not two. The register write
  /// drains off-actor and takes ~17 ms on the MAG; everything on the software
  /// side is inline and lands at once. So the leg that is going DOWN has to go
  /// first, or the display renders a frame from the old register under the new
  /// table and overshoots both endpoints:
  ///
  /// - the register RISES (the #143 hand-back, and any pref change that raises
  ///   it): the software side goes first, inline, exactly as before, and the
  ///   in-flight state is the old register under the new, dimmer table;
  /// - the register DROPS (turning hardware control back on at a value the
  ///   combined split puts at the register's floor): the software side is HELD
  ///   until the write lands. Whatever is dimming the display now keeps dimming
  ///   it in the meantime, so the in-flight state is the OLD state, unchanged,
  ///   rather than a bright composite of the two.
  ///
  /// Held means the whole software side, teardown included, not just the
  /// re-apply. Tearing an abandoned backend down is itself a brightening, so
  /// holding only the re-apply would move the flash rather than remove it, and
  /// keeping the pair together is also what preserves step 1's no-double-dim
  /// property: the old backend is still the only one dimming until both run.
  ///
  /// The cost of the hold is that a display whose register write is slow keeps
  /// its previous dimming for that long. That is the correct trade: it is the
  /// state the user was already looking at.
  public func reapplyAfterPrefChange() {
    coalescer.resetDuplicateState()
    // Read BEFORE the submit below, which overwrites it.
    let parked = submittedDDCPortion ?? 1
    let submitted = applyPaths(.register)
    guard let submitted, submitted < parked else {
      applySoftwareSideOfPrefChange()
      return
    }
    holdSoftwareLegUntilRegisterLands()
  }

  /// Everything in `reapplyAfterPrefChange` except the register write: tear down
  /// the backend the new prefs do NOT select, clear the software dedupe,
  /// re-apply the software leg, and hand the register back if the new path has
  /// stopped driving it (steps 1, 3 and 4, plus the software half of step 2).
  ///
  /// `.software` delivery, never `.both`: the register has already been written
  /// by the caller, and a second submit of the same target would put a duplicate
  /// on a write-only bus for nothing.
  private func applySoftwareSideOfPrefChange() {
    let choice = softwareBackendChoice
    let drawable = drawableDisplayID
    if choice != .shade { backends.shade?.removeShade(for: drawable) }
    if choice != .gamma { backends.gamma?.applyGammaScale(1.0, on: displayID, enforcerOn: drawable) }
    lastAppliedSw = nil
    applyPaths(.software)
    handBackDDCLegIfAbandoned()
  }

  /// Parks the software side until the register write just submitted has landed
  /// (#146). The generation is captured now, so a write submitted later cannot
  /// extend the wait.
  ///
  /// Every dequeued target completes its generation, duplicates and stale epochs
  /// included, so this cannot park forever on a write the coalescer chose not to
  /// put on the wire.
  private func holdSoftwareLegUntilRegisterLands() {
    let generation = issuedGeneration
    softwareLegToken &+= 1
    let mine = softwareLegToken
    heldSoftwareLeg = Task { @MainActor [weak self] in
      await self?.coalescer.waitUntilCompleted(through: generation)
      guard let self, self.softwareLegToken == mine else { return }
      self.heldSoftwareLeg = nil
      self.applySoftwareSideOfPrefChange()
    }
  }

  /// Disarms a held software side. Called from every door that writes the
  /// software leg or re-runs path selection, so "the world moved on" is checked
  /// in one place rather than at each hold's resume.
  private func supersedeHeldSoftwareLeg() {
    softwareLegToken &+= 1
  }

  /// Hands the brightness register back at full range when the newly selected
  /// path has stopped driving it (#143).
  ///
  /// Without this the teardown is one-directional: turning "Use hardware (DDC)
  /// control" back ON writes the register immediately, while turning it OFF
  /// wrote nothing at all, so software dimming ran on top of a panel already at
  /// its hardware minimum. At 40% combined that is DDC 0, and at 100% software
  /// there is nothing left to brighten with, because the gamma table is already
  /// at 1.0. The app reported 100% over a panel at its minimum backlight.
  ///
  /// ORDER IS THE CONTRACT, and it is the opposite of the intuitive one: this
  /// runs AFTER `applyPaths`, never before. This write only ever RAISES the
  /// register, and the software leg it hands over to only ever LOWERS what the
  /// register emits, so:
  ///
  /// - raise first and the intermediate state is a full-range register under
  ///   the old, brighter gamma table: at 90% that is raw 100 under gamma 1.0,
  ///   a flash to full brightness for as long as the two writes are apart, and
  ///   the D4 failure hardware checklist item 54 forbids by name;
  /// - raise second and the intermediate state is the old register under the
  ///   new, dimmer table, which is never brighter than either endpoint.
  ///
  /// No ordering is transient-free. The software leg is inline and synchronous
  /// while the register write drains off-actor through the coalescer, so the
  /// two land milliseconds apart whatever we do. What the ordering buys is that
  /// the gap sits INSIDE the two endpoints instead of overshooting past both.
  ///
  /// The mirror image of this rule, a pref change that DROPS the register while
  /// the software leg brightens, is #146, and it cannot be fixed by reordering
  /// two synchronous statements: `reapplyAfterPrefChange` holds the software
  /// side until the register write has actually landed. Same rule stated once:
  /// the leg that goes down goes first.
  ///
  /// Gated on `unavailableDDC` exactly as `restoreFullRangeDDC` is: a command
  /// the display has declared it does not support, or the user has switched
  /// off, is not one to write on the way out. That leaves the tuning grid's own
  /// Off switch able to strand a display the same way this fixes, which is the
  /// same shape as D29 rule 1 (undo the disabling effect BEFORE persisting the
  /// value that disables it) and belongs in that control, not here.
  private func handBackDDCLegIfAbandoned() {
    guard role == .external, !usesNative else { return }
    // Only a register THIS controller drove below full range is ours to hand
    // back. nil is a panel whose brightness the user set on the monitor itself.
    guard let parked = submittedDDCPortion, parked < 1 else { return }
    let tuning = prefs.tuning(for: .brightness)
    guard !tuning.unavailableDDC else { return }
    guard !BrightnessPathPolicy.path(pathInputs(tuning: tuning)).drivesDDCBrightness else { return }
    submitDDCBrightness(portion: 1, tuning: tuning)
  }

  /// Quit restore: write the register's FULL-RANGE equivalent of the
  /// published value — software dimming is being torn down at quit, so
  /// leaving the combined-mode DDC floor would strand the monitor dark
  /// (StatusItemController's M4 note). Best-effort: skipped under the native
  /// path (DDC is dead there) and for forceSoftware/disabled displays.
  /// Synchronous by design (backlog flag 8, endorsed): callable straight from
  /// `applicationWillTerminate` — the submit is a nonisolated lock store and
  /// the coalescer drains off-actor, so the quit path's barrier (Task 10)
  /// only has to keep the process alive until the write lands, never block
  /// the main thread on DDC I/O.
  ///
  /// Reads `brightness`, so a quit during a temporary dim writes the UNDIMMED
  /// value: the register is handed back to the user's setting on the way out.
  /// That is a backstop, not the contract. The owner of the dim still ends it
  /// explicitly at teardown, because this call returns early on three paths
  /// (native included, which is where an HDR display's dim lives).
  public func restoreFullRangeDDC() {
    guard role == .external, !usesNative, !prefs.forceSoftware else { return }
    let tuning = prefs.tuning(for: .brightness)
    guard !tuning.unavailableDDC else { return }
    coalescer.resetDuplicateState()
    submitDDCBrightness(portion: brightness, tuning: tuning)
  }

  /// Test seam: observes the coalescer's duplicate-memo reset counter (the
  /// disengage contract "duplicate memo reset recorded" is asserted with it).
  nonisolated func _duplicateResetCount() -> UInt64 {
    coalescer.duplicateResetCount()
  }

  /// The last brightness target that actually reached this display's hardware
  /// (B4), or nil if nothing has — nothing submitted, everything failed, or a
  /// reset invalidated what had landed.
  ///
  /// `nonisolated` over the coalescer's existing lock, exactly like
  /// `_duplicateResetCount()`: no executor hop for what a settings row reads
  /// during a refresh. Public rather than a test seam because the diagnostics
  /// section is a real (later-task) consumer.
  public nonisolated func lastAppliedTarget() -> HardwareTarget? {
    coalescer.lastAppliedTarget()
  }

  /// Whether the most recent apply ATTEMPT on this display failed (B4).
  ///
  /// The fact this exposes was previously computed and discarded on every
  /// single write: `DDCCommandApplier` returns a `Bool`, the coalescer used it
  /// to decide whether to advance its duplicate memo, and then it was gone.
  /// "This monitor is ignoring us" was observable to the code and unsayable to
  /// the user.
  public nonisolated func lastApplyFailed() -> Bool {
    coalescer.lastApplyFailed()
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
    /// a controller-level `rebind(writer:panelIdentity:)` takes effect on the
    /// next submitted write (the applier is rebuilt at submit, not held here).
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
  /// applying and only records the outcome if no reset intervened.
  ///
  /// `lastFailed` rides in the same slot (B4). Until now the `Bool` an applier
  /// returned advanced this memo and was then dropped on the floor, so nothing
  /// anywhere could say "the last write to this display failed" — the
  /// diagnostics section could not distinguish a panel that is accepting
  /// commands from one that has been refusing every one of them since the
  /// cable was plugged in. It is the LATEST attempt's outcome, not the worst
  /// one: a display that failed once and has worked ever since is working, and
  /// a latched flag would send someone hunting a cable that is fine. It is not
  /// a second piece of state needing a second lock — it is a second field of
  /// the fact this lock already guards, written in the same critical section
  /// under the same `resets` guard.
  private nonisolated let lastApplied =
    OSAllocatedUnfairLock<(target: HardwareTarget?, resets: UInt64, lastFailed: Bool)>(
      initialState: (nil, 0, false)
    )

  private var completedGeneration: UInt64 = 0
  /// The highest generation that actually reached hardware, was skipped because
  /// its exact target was already there, or was superseded by a newer write
  /// that did one of those. Compare it against the submitter's own counter to
  /// learn whether anything is still owed to the panel.
  private var appliedGeneration: UInt64 = 0
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
    // `lastApplied` comment. `lastFailed` clears with it: a reset means the
    // hardware is in a state we did not write, so a failure recorded against
    // the OLD wire is not a fact about the new one, and reporting it would
    // accuse a freshly plugged panel of a fault the previous one had.
    lastApplied.withLock { $0 = (nil, $0.resets + 1, false) }
  }

  /// Test seam: the `resets` version counter (bumps once per
  /// `resetDuplicateState`).
  nonisolated func duplicateResetCount() -> UInt64 {
    lastApplied.withLock { $0.resets }
  }

  /// The last target that actually reached hardware (B4). `nonisolated` over
  /// the lock this memo already lives in — `duplicateResetCount()` is the
  /// precedent, not new machinery, and reading it must not require an
  /// executor hop into the drain's actor for what is a settings-pane refresh.
  ///
  /// `nil` means nothing has landed: either nothing was ever submitted, or
  /// every attempt failed, or a reset invalidated what had landed. All three
  /// are honestly "we cannot name a value that is on this panel".
  nonisolated func lastAppliedTarget() -> HardwareTarget? {
    lastApplied.withLock { $0.target }
  }

  /// Whether the most recent apply ATTEMPT failed (B4) — see `lastApplied`.
  /// Distinct from `lastAppliedTarget() == nil`, which cannot separate "the
  /// write failed" from "we never wrote".
  nonisolated func lastApplyFailed() -> Bool {
    lastApplied.withLock { $0.lastFailed }
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
  /// See `appliedGeneration`. Read AFTER a `waitUntilCompleted` for the
  /// generation in question, or it answers about a queue still in flight.
  func appliedThrough() -> UInt64 { appliedGeneration }

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
      // Whether this target ends up ON the wire, which is a different fact from
      // its generation completing. Every dequeued target completes (the
      // deadlock rule below), including the two skips, so a caller that waits
      // for completion and concludes "the value is on the panel" is trusting a
      // counter that says nothing of the kind. `appliedGeneration` is the fact
      // itself, and it is the one the reset paths wait on.
      var landed = false
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
          //
          // The outcome `Bool` is now KEPT rather than dropped (B4). Review
          // I1's guard covers the failure flag too, not just the target: a
          // reset that raced this apply means the failure was against the old
          // wire, and recording it afterwards would make a freshly rebound
          // panel report a fault it never had. Both fields therefore move
          // together, inside one critical section, or neither does.
          let didApply = await write.applier.apply(write.target)
          landed = didApply
          lastApplied.withLock { state in
            guard state.resets == memo.resets else { return }
            state.lastFailed = !didApply
            if didApply {
              state.target = write.target
            }
          }
        } else {
          // Skipped because this exact target is already on the wire, which is
          // the state the caller wanted: landed, without a redundant write.
          landed = true
        }
      }
      if landed {
        // A superseded older write is covered without being dequeued: the newer
        // target replaced it in the slot precisely because it is the value that
        // should be on the panel, and its generation is higher.
        appliedGeneration = max(appliedGeneration, write.generation)
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
