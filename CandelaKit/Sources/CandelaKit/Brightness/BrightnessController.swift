import CoreGraphics
import Observation
import os

/// Drag-perf diagnostics: one line per post-coalescing stage (target adoption, DDC
/// write start/end). Cheap at ~30 Hz during a drag, and the fastest way to localize
/// a "slider moves but hardware doesn't" report.
let dragPerfLog = Logger(subsystem: "com.rydersel.Candela", category: "dragperf")

/// Path-selection/HDR diagnostics (mode changes, settle completion, cache
/// refreshes).
let pathLog = Logger(subsystem: "com.rydersel.Candela", category: "path")

/// The non-DDC brightness endpoints a controller can route through. `hdr`, `shade`
/// and `gamma` are optional: nil means the feature is degraded, so HDR routing never
/// engages or the software leg silently drops. The native applier is required; when
/// the DisplayServices shim is unavailable the app injects a closure returning false.
///
/// The DDC applier is not held here. It is built per submit from the controller's
/// writer, so `rebind(writer:panelIdentity:)` takes effect on the very next write.
///
/// `readNative` is the native readback: role `.builtIn` seeds from it at init and
/// reads it in `refreshFromHardware` instead of DDC (fork:
/// `AppleDisplay.getAppleBrightness`).
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

/// Whether a DDC write can be trusted to reach a display right now, as measured
/// rather than as mirrored.
///
/// The three cases are not a tri-state mood: `.open` is the only one that
/// licenses a caller to report its write as landed, and the other two differ
/// only in what a person can be told to do about it.
public enum HDRWriteWindow: Sendable, Equatable {
  /// Measured out of HDR with no transition racing the read: the register is
  /// not locked, so a write that the wire then settles did reach the panel.
  case open
  /// Measured in HDR. DDC goes nowhere and the panel ACKs the loss, so a write
  /// sent now is a write nothing downstream can tell from a success.
  case locked
  /// A transition moved this display while the read was out. The answer
  /// describes a state that is nobody's to vouch for.
  case unknown
}

/// Single source of truth for one display's brightness (spec §5: every input
/// funnels through here; every surface renders from `brightness`).
///
/// Path selection in the fork's order, evaluated synchronously from cached state on
/// every `setBrightness`:
/// 1. native (HDR mode set AND HDR live) → `.native` hardware leg, full range;
/// 2. force-software → software leg only, full range;
/// 3. combined (default) → `DimmingMath.combinedSplit` across both legs;
/// 4. combined disabled → `.ddc` hardware leg, full range.
@MainActor @Observable
public final class BrightnessController: PendingWireDraining {
  public private(set) var brightness: Double = 1.0

  /// The maximum a panel is assumed to accept until it reports one of its own (fork
  /// parity). Named rather than repeated, because a reset that drifted from the
  /// initial value would put a display into a state no freshly discovered display
  /// can be in.
  private static let assumedMaxDDC: UInt16 = 100

  public private(set) var maxDDCValue: UInt16 = BrightnessController.assumedMaxDDC

  /// What this display's brightness reads have proved (B3). Published so the
  /// diagnostics section can say "this display accepts commands but does not answer
  /// reads" rather than showing last-written values as though the panel had reported
  /// them.
  ///
  /// The verdict of the most recent pass that actually ASKED the panel something,
  /// not the worst thing ever observed on this display:
  ///
  /// - A pass that attempts nothing must not touch it. `refreshFromHardware` returns
  ///   early under the native path, `unavailableDDC` and role `.builtIn`, so the
  ///   assignments below sit AFTER every such return. Otherwise a display that
  ///   answered zeros once looks pristine again because the next pass never reached
  ///   the wire.
  /// - A pass that does ask supersedes the previous pass's verdict. A worst-wins fold
  ///   across passes reads "this display does not reply" about a panel that just
  ///   replied. `worse` is still exactly right WITHIN a pass and across this display's
  ///   sibling controllers (`DDCReadEvidence.worst`); the scope of the fold was wrong,
  ///   never the ordering.
  ///
  /// This controller reads one code, once, per pass, so the within-pass fold here is
  /// trivial and the assignments are plain. `DDCValueController`, which retries, has
  /// to spell the fold out.
  public private(set) var readEvidence: DDCReadEvidence = .notAttempted

  /// Whether this display's DDC wire has stopped carrying writes
  /// (`DDCWireHealth`, WD1). An observable mirror of the health the coalescer
  /// folds, because SwiftUI cannot re-render on a lock. `noteWireHealthChanged()`
  /// is the only writer, and it copies rather than decides.
  public private(set) var isWireUnresponsive = false

  /// Whether `maxDDCValue` came from the PANEL or is the assumed default (B5).
  /// `maxDDCValue` defaults to 100, which is indistinguishable from a real read of
  /// 100, and on a write-only panel the assumption is always the true story. So the
  /// provenance is recorded beside the number rather than inferred from it.
  public private(set) var didReadMaxDDC = false

  /// Mirror of `prefs.hdrMode`, published for the panel (`DisplayPrefs` is
  /// plain UserDefaults and not observable). Change it via `setHDRMode`.
  public private(set) var hdrMode: HDRMode

  /// The fork's `usesNativeBrightness` gate: HDR is currently live, WHOEVER engaged
  /// it. System Settings can turn HDR on with `hdrMode` still `.off`, and DDC writes
  /// cannot land there. The live-state half is load-bearing the other way too: with
  /// HDR off the MAG341C answers `DisplayServicesSetBrightness` with SUCCESS and
  /// changes nothing, so native must never be routed on mode alone.
  ///
  /// Role `.builtIn` is constitutively native: no DDC wire and no combined or
  /// software routing, so every path-selection consumer (`applyPaths`, step's
  /// combined math, `handleReconfigure`) short-circuits through this one gate.
  ///
  /// A CALL into the shared table (B1), not a second copy of it: the rule and its
  /// evidence live in `BrightnessPathPolicy.usesNative`.
  private var usesNative: Bool {
    BrightnessPathPolicy.usesNative(role: role, isHDRActive: cachedHDRActive)
  }

  /// Whether the display reports HDR capability: a published mirror of the
  /// async-refreshed cache. Computed off the stored cache, so SwiftUI reads are
  /// observation-tracked and the panel's HDR menu can disable itself on non-HDR
  /// displays.
  public var supportsHDR: Bool { cachedSupportsHDR }

  /// Whether HDR is live on the display right now, same pattern as `supportsHDR`.
  /// The panel's badge reads STATE from here; `hdrMode` is only the POLICY, so an
  /// externally toggled HDR (mode still `.off`) still reports engaged.
  public var isHDREngaged: Bool { cachedHDRActive }

  /// What is actually driving this display's brightness right now: the same answer
  /// `applyPaths` acts on, not a description of it (B1).
  ///
  /// Computed, not stored. Both invalidation signals already exist (`isHDREngaged` is
  /// observable, and any pref change bumps `prefsRevision`), while a stored mirror
  /// would need a third one nobody would remember to fire. A stale path is worse than
  /// no path at all: the point of the row is that it cannot lie.
  public var brightnessPath: BrightnessPath {
    BrightnessPathPolicy.path(pathInputs(tuning: prefs.tuning(for: .brightness)))
  }

  /// Takes the tuning as an argument rather than reading it: `applyPaths` runs on
  /// the 60 Hz drag path and already reads it once for the DDC conversion, and
  /// `prefs.tuning(for:)` is six UserDefaults lookups plus a string parse.
  private func pathInputs(tuning: CommandTuning) -> BrightnessPathPolicy.Inputs {
    BrightnessPathPolicy.Inputs(
      role: role,
      isHDRActive: cachedHDRActive,
      forceSoftware: prefs.forceSoftware,
      avoidGamma: prefs.avoidGamma,
      disableCombinedBrightness: prefs.disableCombinedBrightness,
      unavailableDDC: tuning.unavailableDDC,
      switchingValue: switchingValue,
      wireUnresponsive: isWireUnresponsive
    )
  }

  /// HDR state caches, refreshed by async tasks (init, mode changes,
  /// `noteHDRStateMayHaveChanged`) and only ever *read* on the
  /// synchronous keypress/drag paths — never awaited there.
  private(set) var cachedHDRActive = false
  private(set) var cachedSupportsHDR = false

  /// What the last REFRESH observed, a different fact from `cachedHDRActive`:
  /// transitions write that one optimistically (an exit sets it false before the drop
  /// goes out, and back to true when it bails), so it moves on requests rather than
  /// observations.
  ///
  /// The memo invalidation is keyed to THIS one going true-to-false. Keyed to the
  /// optimistic mirror instead, an exit's own confirming refresh would see
  /// false-to-false and no edge would survive a transition that set the mirror on its
  /// way in.
  @ObservationIgnored private var observedHDRActive = false

  /// True from an HDR transition's start until its ~2 s settle window ends; gates
  /// `isNativeActive()` so the poller stays away while the display blanks and
  /// re-modes.
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
  /// Sync's ambient-hunting deadband for the movement THIS controller has published
  /// as a source, advanced only by `BrightnessSync.fanOut`. It lives here rather than
  /// in a table beside the sync code so it shares the lifetime of the brightness it
  /// accumulates: a controller that goes away takes its residual with it.
  ///
  /// That is lifetime, not identity. `performRefresh` reconciles on
  /// `CGDirectDisplayID` and REUSES the controller, so a display ID handed to a
  /// different panel arrives here as a rebind, which clears the residual.
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
  /// Read at submit time to stamp each `PendingWrite.epoch`. Default `{ 0 }` pairs
  /// with the coalescer's accept-everything default gate, so a call site that never
  /// installs an epoch pair keeps the old behaviour.
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

  /// Software-leg dedupe memo (the fork's `.SwBrightness` skip), critical at 60 Hz
  /// drag rates because every software apply reprograms the gamma table or shade.
  /// In-memory only, deliberately not pref-persisted like the fork's: a fresh
  /// controller always applies its first value.
  @ObservationIgnored private var lastAppliedSw: Double?

  /// The 0…1 brightness portion this controller last SUBMITTED on the DDC leg,
  /// before tuning maps it onto the register, or nil while it has never driven
  /// that leg at all.
  ///
  /// The nil is as load-bearing as the number. A register Candela has never written
  /// is one the user set with the monitor's own buttons, and the hand-back must not
  /// stomp it; a register Candela drove to the combined-mode floor is one Candela
  /// owes back. Kept in the PORTION domain so `invert` and the min/max overrides
  /// cannot make "full range" mean different things on the two sides of the
  /// comparison: portion 1 is the brightest the panel is configured to go.
  @ObservationIgnored private var submittedDDCPortion: Double?

  /// The single armed watch on the wire's verdict, or nil while none is armed.
  /// Internal so a test can await the outcome instead of polling for it, the
  /// way `heldSoftwareLeg` is.
  @ObservationIgnored private(set) var wireHealthWatch: Task<Void, Never>?

  /// The software side of a pref re-apply that is waiting for its register write to
  /// land, or nil when nothing is held. Internal so a test can await the handover
  /// instead of polling for it.
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

  /// The other write queues on this display's wire (its volume and contrast
  /// controllers), whose duplicate memos have to be dropped whenever an HDR window
  /// closes: a write ACKed while the register was locked was swallowed, so a memo
  /// built through the window names values the panel never took.
  ///
  /// Stored, and required at init, because the moment that needs them is not a call.
  /// The invalidation is keyed to the mirror's observed true-to-false edge in
  /// `refreshHDRCaches`, which runs from the init refresh and the reconfiguration loop
  /// as well as from the doors: HDR dropped in System Settings has no caller of ours
  /// to hand anything over. A parameter cannot reach those paths, and a setter called
  /// later could be forgotten in silence.
  ///
  /// A fact about the wire rather than about a call, so it never changes: a display's
  /// three controllers are built together and reused together, and a replug rebinds
  /// their writers in place rather than replacing the objects.
  @ObservationIgnored private let wireSiblings: [any PendingWireDraining]

  /// Gamma-interference hook: invoked ONLY when the gamma backend, not the shade, is
  /// about to apply and the software dedupe did not skip. The C1 clearing's
  /// restore-to-1.0 bypasses it on purpose: it is a restore, not a dim, and must
  /// never be suspected as interference.
  @ObservationIgnored public var preGammaApplyHook: (@MainActor () -> Void)?

  /// True while this display's picture is coming from a size Candela renders
  /// rather than from a mode the panel published (SS4). Injected because the
  /// pairing lives a layer up, in the app's synthesis coordinator, while the
  /// only door that can engage HDR is here.
  ///
  /// It gates the engage arm of `setHDRMode`, which is the half SS9 left open:
  /// SS9 refuses a synthesis engage while HDR is on, and nothing refused the
  /// reverse. Defaulting to false keeps every existing caller and every test
  /// on the pre-gate behaviour.
  @ObservationIgnored public var isShowingSynthesizedSize: @MainActor () -> Bool = { false }

  /// Expected-native echo slot. One lock backs all three nonisolated poller
  /// accessors:
  /// - `value`/`generation`: every local native-leg write stores its value at
  ///   press time and bumps the generation, so adoptions queued before a local write
  ///   are discarded as stale;
  /// - `nativeActive`: false from an HDR transition's start, true only once the
  ///   settle window has completed;
  /// - `converging`: an external adoption is still easing toward its target, so the
  ///   poller must not discard reads as echoes until the snap.
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
  /// Monotonic supersession token for `setHDRMode`'s post-await mutations. Comparing
  /// `hdrMode` instead is ABA-prone: a parked `.alwaysOn` call resumes to find the
  /// mode back at `.alwaysOn` after an `.off` to `.alwaysOn` round trip and waves its
  /// stale rollback through, clobbering the transition that owns the state. Bumped by
  /// every transition start (`beginHDRTransition`).
  @ObservationIgnored private var hdrTransitionGeneration: UInt64 = 0
  /// Init-time HDR cache refresh; tests await it before priming so two
  /// refreshes can't interleave and double-run the C1 clearing.
  @ObservationIgnored private(set) var initialHDRRefresh: Task<Void, Never>?
  /// Test seam: observes every hardware submit before the coalescer's own
  /// duplicate-skip.
  ///
  /// The APPLIER rides along so the target/applier pairing is observable where it is
  /// chosen. Every mismatch this codebase can produce is born here, in `applyPaths`;
  /// the appliers' own guards only see it two layers later, as a dropped write and a
  /// log line.
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
    // an unwired engine degrades to exactly today's behaviour.
    mirrorTopology: any MirrorTopologyProviding = MirrorTopologyStore(),
    // NO DEFAULT, and the only place the wire's other queues are named. See the
    // property: the invalidation edge fires on paths that have no caller, so
    // this cannot be a parameter on the doors, and an empty default would make
    // a display whose siblings were never wired look exactly like a display
    // that has none.
    wireSiblings: [any PendingWireDraining]
  ) {
    self.mirrorTopology = mirrorTopology
    self.wireSiblings = wireSiblings
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
      // Role `.builtIn` bypasses the migration/first-run/park-at-s block entirely:
      // macOS owns built-in brightness across launches, and a shared init would park
      // a MacBook panel at s every launch. Seed from a live native read instead
      // (fallback 1.0); never write the store.
      brightness = Double(min(max(backends.readNative?(displayID) ?? 1.0, 0), 1))
    } else {
      // Migration + first-run.
      let s = DimmingMath.switchingValue(fromPoint: prefs.combinedSwitchingPoint)
      var initial: Double
      if let store, let storageKey, let saved = store.savedBrightness(for: storageKey) {
        initial = min(max(saved, 0), 1)
      } else if let store, let storageKey, let legacyKey,
                let legacy = store.savedBrightness(for: legacyKey) {
        // One-time migration: the legacy value was pure-DDC, which is the upper
        // [s, 1] band of the combined scale. The legacy key is left in place and
        // ignored from here on.
        initial = s + min(max(legacy, 0), 1) * (1 - s)
        store.saveBrightness(initial, for: storageKey)
      } else {
        // Fresh display: the fork's rule is s + convDDCToValue(100) * (1 - s) = 1.0.
        // The 0.5 property default would mean "hardware minimum" on the combined
        // scale.
        initial = 1.0
      }
      if !prefs.disableCombinedBrightness, !prefs.forceSoftware, initial < s {
        // Park-at-s, every launch: the termination hook removes software dimming at
        // quit, so restoring a software-zone value would show un-dimmed glass under a
        // low slider. Publish only; the store keeps the saved value. forceSoftware
        // displays are exempt, because their whole range IS the software leg and the
        // park would silently raise brightness each launch.
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

  /// A read while WE hold a temporary dim reads our own write, not the user's value:
  /// the dim is a multiplier on the way to the hardware and never touches
  /// `brightness` or the store, so adopting the register back would fold it in
  /// permanently and `endTemporaryDim` would then "restore" to the corrupted number.
  /// Reached on every reconfiguration, which a lock dim can outlast.
  public func refreshFromHardware() async {
    guard temporaryDimFactor == nil else { return }
    if role == .builtIn {
      // The built-in panel has no DDC wire, so the native read is the only truth
      // (fork: `AppleDisplay.getAppleBrightness`). Publish only; no store, because
      // macOS owns built-in brightness across launches.
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
    // Three named outcomes (B3), so "the panel never replied" and "the panel replied
    // with zeros" do not collapse into the same silence. Only the second is the
    // MAG 341C's write-only signature, and the diagnostics pane has to say which
    // happened.
    //
    // Assignment, not a fold against the previous value: everything above this line
    // has already returned for the passes that ask nothing, so reaching here means
    // the panel WAS asked and this pass's answer is the current fact about it.
    // Folding across passes published "does not reply" about panels that had since
    // replied (see `readEvidence`).
    guard let result = await writer.read(command: tuning.remapCodes.first ?? VCP.brightness) else {
      readEvidence = .noReply
      return
    }
    // `(0, 0)` and `max == 0` are FAILED reads, not a brightness of zero: the
    // MAG341C answers every read this way, and the fork's unvalidated read clobbers
    // saved values to 0. Recorded rather than merely rejected (B3).
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
    // Read mirrors write (fork convDDCToValue): un-apply curve and invert through
    // the same tuning, or a tuned readable panel adopts a corrupted brightness at
    // every launch.
    let raw = DimmingMath.ddcToValue(
      result.current,
      minDDC: Double(tuning.minDDCOverride),
      maxDDC: Double(tuning.effectiveMaxDDC(readMax: Int(result.max))),
      curve: tuning.curveMultiplier,
      invert: tuning.invert
    )
    if !prefs.disableCombinedBrightness {
      // C2: a readable panel's DDC value lives in the upper [s, 1] band of the
      // combined scale. Adopting current/max directly would map DDC 50% to "combined
      // 0.5", i.e. DDC 0, corrupting the store. DDC 0 is consistent with ANY
      // software-zone value, so a zero read keeps the saved value.
      guard result.current > 0 else { return }
      let s = switchingValue
      brightness = s + raw * (1 - s)
    } else {
      brightness = raw
    }
    // A readable panel's hardware value is truth, so the store adopts it too:
    // otherwise the saved number goes stale and the next launch restores an outdated
    // brightness.
    persist(brightness)
  }

  // MARK: - Brightness input

  /// Synchronous by design: state updates immediately and hardware writes coalesce
  /// latest-wins, because a 60 Hz slider drag must never queue stale DDC writes (each
  /// write holds the DDC actor for ~20 ms, more on retries).
  ///
  /// The hardware write must not require the main actor for any step after this call
  /// returns: during a slider drag the main run loop sits in event-tracking mode,
  /// which starves main-actor task execution until mouseup. So the handoff is a
  /// synchronous, nonisolated store into a lock-protected slot and the coalescer
  /// drains on the global executor. The software leg runs inline right here, and that
  /// immediacy is the drag-smoothness payoff of software dimming.
  public func setBrightness(_ value: Double) {
    let clamped = min(max(value, 0), 1)
    brightness = clamped
    applyPaths()
    persist(clamped)
  }

  //  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
  /// One brightness-key step, one OSD chiclet (fork: `Display.calcNewBrightness`):
  /// 16 chiclets, quarter-chiclet bias, ceil-snap so off-boundary values snap in the
  /// direction of travel. `isFine` steps a quarter chiclet (Opt+Shift). The plain
  /// chiclet math runs on EVERY path; `DimmingMath.stepCombined` is wired only behind
  /// the app-level `separateCombinedScale` default.
  ///
  /// Stepping does not distinguish a fresh press from key-repeat: the HDR Boost gate
  /// that once needed that distinction is gone.
  @discardableResult
  public func step(isUp: Bool, isFine: Bool) -> Double {
    let value: Double
    if prefs.separateCombinedScale, !usesNative, !prefs.forceSoftware,
       !prefs.disableCombinedBrightness {
      value = DimmingMath.stepCombined(current: brightness, isUp: isUp, isFine: isFine)
    } else {
      // D3: one shared 16-chiclet step for brightness/volume/contrast
      // (DimmingMath.stepValue). Fine is flat ±0.01, which is fork PARITY for plain
      // DDC externals (its calcNewValue path). It diverges from the fork only on the
      // native/forceSoftware paths, where the fork grid-snaps fine at 1/64 (0.0156 vs
      // 0.01 per press, imperceptible).
      value = DimmingMath.stepValue(current: brightness, isUp: isUp, isFine: isFine)
    }
    setBrightness(value)
    return value
  }

  // MARK: - Path selection

  /// The four-way fork contract, decided synchronously from cached state:
  /// `cachedHDRActive` is never awaited on the drag path.
  ///
  /// The BRANCH lives in `BrightnessPathPolicy` and this switches over its answer
  /// (B1), which is what makes the diagnostics pane unable to drift from the engine:
  /// there is one table, and the engine is what runs it. The order the fork's
  /// contract depends on is preserved inside the policy; a `switch` here is order-free
  /// by construction.
  ///
  /// **Takes no VALUE argument, deliberately.** Every leg has to derive from the same
  /// effective value, and a parameter is exactly how that broke once:
  /// `handleReconfigure` recomputed the software split from raw `brightness` and
  /// re-applied an UNDIMMED software leg while the DDC leg held a temporary dim,
  /// leaving a half-lifted dim on a locked screen that the coordinator's re-assert
  /// could not repair (`beginTemporaryDim` no-ops on an unchanged factor). The
  /// `delivery` argument carries no value; it only says which legs this call may
  /// write, and both still derive from `effectiveBrightness`.
  ///
  /// Returns the DDC portion this call put on the register, or nil when the selected
  /// path wrote none. `reapplyAfterPrefChange` needs the direction the register moved
  /// in and must not re-derive it: a second site computing the combined split is a
  /// second copy of the table.
  @discardableResult
  private func applyPaths(_ delivery: LegDelivery = .both) -> Double? {
    supersedeHeldSoftwareLeg()
    let value = effectiveBrightness
    let tuning = prefs.tuning(for: .brightness)
    switch BrightnessPathPolicy.path(pathInputs(tuning: tuning)) {
    case .native:
      guard delivery.writesRegister else { return nil }
      // Local native-leg write: record the expected echo at call time and invalidate
      // any queued adoption.
      echo.withLock { state in
        state.value = value
        state.generation += 1
        state.converging = false
      }
      submitHardware(.native(Float(value)), applier: backends.applierNative)
      return nil

    case .software:
      // `applySoftware` re-reads `avoidGamma` itself; the backend carried on the
      // path is for REPORTING. Routing the backend through here would be a behaviour
      // change wearing a refactor's clothes.
      if delivery.writesSoftware { applySoftware(value) }
      return nil

    case let .combined(switching, _):
      // No `unavailableDDC` guard, and its absence is the point: ruling R-A makes
      // `.combined` unreachable with a dead DDC leg, so the old inner check was dead
      // code that also implied the opposite. That state is `.softwareOnly` below,
      // where the skipped submit lives.
      let split = DimmingMath.combinedSplit(value: value, switching: switching)
      var submitted: Double?
      if delivery.writesRegister {
        submitDDCBrightness(portion: split.ddc, tuning: tuning)
        submitted = split.ddc
      }
      if delivery.writesSoftware { applySoftware(split.sw) }
      return submitted

    case let .softwareOnly(_, _, dimsBelow):
      // Combined mode with no live hardware half: the command is off, or the wire
      // stopped answering. Both submit the same legs, so the reason is not matched on
      // here; it exists for the surfaces that have to SAY which one happened. The
      // register write is skipped and the software leg still runs, but on the COMBINED
      // SPLIT value: `applySoftware(value)` here would silently convert this display
      // to full-range software dimming, which is a different feature.
      if delivery.writesSoftware {
        applySoftware(DimmingMath.combinedSplit(value: value, switching: dimsBelow).sw)
      }
      return nil

    case .hardware:
      guard delivery.writesRegister else { return nil }
      submitDDCBrightness(portion: value, tuning: tuning)
      return value

    case .unavailable:
      // DDC brightness turned off with no software leg left to carry the value:
      // combined mode disabled, or combined mode with a zero-width software band.
      // A NAMED state, so the pane can report it.
      return nil
    }
  }

  /// Which legs one `applyPaths` call may write. Only the pref-change ordering asks
  /// for anything but `.both`, and it asks for both halves in turn: the register
  /// alone first, then the software side once that write has landed. Nothing on the
  /// drag path splits them.
  private enum LegDelivery {
    case both
    case register
    case software

    var writesRegister: Bool { self != .software }
    var writesSoftware: Bool { self != .register }
  }

  /// Tuning on the DDC leg: min/max overrides, 9-step curve, invert. The effective
  /// max clamps the read max to 100 (fork DDC_MAX_DETECT_LIMIT).
  private func brightnessRaw(_ portion: Double, tuning: CommandTuning) -> UInt16 {
    DimmingMath.valueToDDC(
      portion,
      minDDC: Double(tuning.minDDCOverride),
      maxDDC: Double(tuning.effectiveMaxDDC(readMax: Int(maxDDCValue))),
      curve: tuning.curveMultiplier,
      invert: tuning.invert
    )
  }

  /// The ONE door to the brightness register, so `submittedDDCPortion` cannot drift
  /// from what was actually put on the wire: a submit that recorded nothing would
  /// make the display look like one Candela never drove, and
  /// `handBackDDCLegIfAbandoned` would then leave it at the floor.
  private func submitDDCBrightness(portion: Double, tuning: CommandTuning) {
    submittedDDCPortion = portion
    submitHardware(
      .ddc(raw: brightnessRaw(portion, tuning: tuning)),
      applier: brightnessApplier(tuning: tuning)
    )
  }

  private func brightnessApplier(tuning: CommandTuning) -> any BrightnessApplying {
    #if DEBUG
      // Nothing on the rig can make a live display's wire fail on demand (WD6).
      // Wraps the real applier rather than the writer, so only BRIGHTNESS fails
      // and a rig leg can tell a dead command from a dead cable.
      if DebugDDCFailure.isFailing(persistenceKey: boundPanelIdentity) {
        return FailingDDCApplier()
      }
    #endif
    return DDCCommandApplier(writer: writer, command: VCP.brightness, remapCodes: tuning.remapCodes)
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
      .init(
        target: target, applier: applier, epoch: epochProvider(),
        generation: issuedGeneration,
        // Stamped on the main actor, where the HDR state lives; the drain that
        // reads it runs off the actor. Why one transaction early is safe:
        // `PendingWrite.hdrExcluded`.
        hdrExcluded: cachedHDRActive || settleInProgress
      )
    )
    if case .ddc = target { armWireHealthWatch() }
  }

  /// Watches for the wire's verdict changing while nobody is touching the app.
  /// Path selection reads `isWireUnresponsive` synchronously, so without this a
  /// display sits at the value of the write that killed it until the next event
  /// arrives to notice, and that write is usually the last one anybody makes.
  ///
  /// One watch at a time: during a drag every submit finds one already running,
  /// so a 60 Hz stream costs one task rather than one per event.
  private func armWireHealthWatch() {
    guard wireHealthWatch == nil else { return }
    wireHealthWatch = Task { @MainActor [weak self] in
      while true {
        guard let generation = self?.issuedGeneration, let coalescer = self?.coalescer else {
          return
        }
        await coalescer.waitUntilCompleted(through: generation)
        guard let self else { return }
        self.noteWireHealthChanged()
        // Anything submitted while this was suspended, including a write
        // `noteWireHealthChanged` just made, has an outcome nobody is waiting
        // on, so the loop goes round rather than leaving it unread.
        if self.issuedGeneration == generation {
          self.wireHealthWatch = nil
          return
        }
      }
    }
  }

  /// The ONE door for "this display's wire changed its verdict" (WD4).
  ///
  /// A transition changes which legs carry the value, so it is a
  /// dimming-affecting change under D28 and re-evaluates through
  /// `reapplyAfterPrefChange`. A bare `handleReconfigure` or a same-value
  /// `setBrightness` would leave the display at its DDC floor with a scaled
  /// table over it until something replugged it.
  private func noteWireHealthChanged() {
    let unresponsive = coalescer.wireHealth().isUnresponsive
    guard unresponsive != isWireUnresponsive else { return }
    isWireUnresponsive = unresponsive
    pathLog.log(
      "DDC brightness wire on display=\(self.displayID) is now \(unresponsive ? "unresponsive" : "answering", privacy: .public)"
    )
    // Native answers `.native` whatever the wire does, so no leg moved. The
    // mirror above is still updated: the panel says what it knows either way.
    guard !usesNative else { return }
    reapplyAfterPrefChange()
  }

  /// WD3's reset, from every route that means the wire deserves a fresh
  /// hearing. A successful apply is the fourth route and needs no call here:
  /// the health clears itself on the outcome.
  private func resetWireHealth() {
    coalescer.resetWireHealth()
    noteWireHealthChanged()
  }

  /// The app's wake handler calls this: the engine has no AppKit to observe
  /// `didWakeNotification` with, and a link rebuilt while the Mac slept has
  /// told us nothing yet (WD3).
  public func noteWake() {
    resetWireHealth()
  }

  /// Where this display's pixels actually are: itself, or its mirror master. Read
  /// fresh on every use, because the topology is a sample of one instant.
  ///
  /// **In a mirror set, every member's controller resolves to the SAME id**, so they
  /// all drive one shade window and one gamma enforcer position while each memoises
  /// its own `lastAppliedSw` as applied. Not a defect to fix: a mirror set is ONE
  /// framebuffer, so one dimming surface is the only physically meaningful answer.
  /// Recorded because the memo makes it look like two independent applies succeeded,
  /// and a reader of `lastAppliedSw` for a slave will expect a surface of its own.
  private var drawableDisplayID: CGDirectDisplayID {
    mirrorTopology.drawableDisplayID(for: displayID)
  }

  /// The companion ID the last gamma write went to, so a reconfigure can clear
  /// the baseline the island cached for it.
  ///
  /// Remembered rather than re-derived: a synthesis disengage destroys the virtual
  /// display and the topology stops naming it in the same breath, so by the time
  /// `handleReconfigure` runs there is nothing left to ask. Without this the island
  /// keeps a baseline keyed on an ID CoreGraphics is free to reissue, and a
  /// re-engaged slot would scale a new display's table against a destroyed one's.
  private var lastGammaCompanionID: CGDirectDisplayID?

  /// Every gamma write this controller makes, and the ONE place SS15's double
  /// write is decided.
  ///
  /// While a synthesis set is engaged the panel and the virtual display holding its
  /// framebuffer are two display IDs with two transfer tables. Measured: the slave's
  /// table stores and reads back changed, and whether it reaches the glass is not
  /// decidable from software, because scanout comes from the master's framebuffer. So
  /// both are written, which is what SS15 asks for.
  ///
  /// **This is not a free double write.** Zero, one or both tables may reach the
  /// glass, and software cannot tell which. Two LUTs in one scanout chain COMPOUND:
  /// 0.5 applied twice is 0.25, visibly darker than the value asked for. The hardware
  /// pass checks for doubled dimming as much as for missing dimming, and it decides
  /// the final single routing.
  ///
  /// Restricted to a SYNTHESIS set (SS1's pairing, never the mirror flags): in a
  /// mirror set the user built, the master is somebody else's desktop, and scaling its
  /// table would dim a display nobody asked about.
  ///
  /// The companion leg goes through the assumed-linear-baseline entry point, because
  /// the process that created a virtual display cannot read its table back and the
  /// ordinary leg refuses a display whose baseline it never captured.
  ///
  /// Only the PANEL's write decides the return value. The companion can refuse for
  /// reasons that say nothing about the dimming, and letting that answer `landed`
  /// would clear the dedupe memo and re-attempt on every drag event: the live-lock
  /// DT17's reporting rule exists to avoid.
  @discardableResult
  private func writeGammaScale(
    _ scale: Double, using gamma: any GammaApplying, enforcerOn drawable: CGDirectDisplayID
  ) -> Bool {
    let landed = gamma.applyGammaScale(scale, on: displayID, enforcerOn: drawable)
    if drawable != displayID, mirrorTopology.topology().isSynthesisSet(containing: displayID) {
      gamma.applyGammaScale(assumingLinearBaseline: scale, on: drawable, enforcerOn: drawable)
      lastGammaCompanionID = drawable
    }
    return landed
  }

  /// Hands this display's gamma tables back at scale 1.0, on every leg the dim
  /// wrote to.
  ///
  /// The interference-accept path abandons gamma for the shade for good and has to
  /// restore what it scaled. It cannot write the island directly: under an engaged
  /// synthesis pairing the dim wrote TWO tables (SS15), and a companion left scaled is
  /// a virtual display holding a dark framebuffer no other door hands back. Public
  /// because the accept hook lives in the app target.
  ///
  /// Deliberately does NOT clear `lastAppliedSw`: the caller follows with
  /// `handleReconfigure`, which owns that and the re-apply through the shade.
  public func handBackGammaTables() {
    guard let gamma = backends.gamma else { return }
    writeGammaScale(1.0, using: gamma, enforcerOn: drawableDisplayID)
  }

  /// The software leg, inline and synchronous on the main actor. `sw` is the raw 0…1
  /// software value; the backend receives the transformed physical multiplier, since
  /// the transform applies before any gamma or shade write. Deduped on the
  /// last-applied sw value.
  ///
  /// DT17: the dedupe memo is written ONLY when the backend says the write landed.
  /// Set before asking the backend, a shade that could not be created (a mirror slave
  /// has no `NSScreen`) dimmed nothing and then deduped every identical retry away
  /// forever, while the engine reported the value as applied.
  private func applySoftware(_ sw: Double) {
    supersedeHeldSoftwareLeg()
    guard lastAppliedSw != sw else { return }
    let transformed = DimmingMath.swTransform(sw, allowZero: prefs.allowZeroSwBrightness)
    let drawable = drawableDisplayID
    let landed: Bool
    if prefs.avoidGamma {
      // `?? true` is "no backend is configured, so nothing could have failed".
      landed = backends.shade.map {
        $0.setShadeAlpha(DimmingMath.shadeAlpha(fromValue: transformed), on: drawable)
      } ?? true
    } else if let gamma = backends.gamma {
      preGammaApplyHook?()
      // The WRITE target stays the RAW panel ID; only the enforcer resolves, and
      // an engaged synthesis set adds a second write (SS15, `writeGammaScale`).
      landed = writeGammaScale(transformed, using: gamma, enforcerOn: drawable)
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

  /// C1 (MUST-HAVE): runs on EVERY transition into the native path,
  /// `setHDRMode(.alwaysOn)` and an externally-toggled HDR discovered by
  /// `noteHDRStateMayHaveChanged` alike. Without it the screen stays dimmed by a
  /// gamma table HDR ignores (gamma is broken under HDR) and the software dedupe
  /// blocks recovery.
  ///
  /// DIVERGENCE: the fork also clears the user's forceSw/avoidGamma prefs on entering
  /// always-on. Candela does not; those are per-display user choices.
  private func clearSoftwareLeg() {
    // Not merely belt-and-braces over `applyPaths`: the engage arm clears the
    // leg and then AWAITS the HDR toggle, so a hold left armed here would fire
    // during that suspension and re-dim a display on its way into HDR.
    supersedeHeldSoftwareLeg()
    let drawable = drawableDisplayID
    backends.shade?.removeShade(for: drawable)
    // Through the same helper as the dim, so the restore reaches every table the
    // dim wrote: a synthesis companion left scaled is a virtual display holding
    // a dark framebuffer nothing else will ever hand back.
    if let gamma = backends.gamma {
      writeGammaScale(1.0, using: gamma, enforcerOn: drawable)
    }
    lastAppliedSw = nil
  }

  /// Every door INTO the native path ends by re-submitting the published value on
  /// the native leg. Without it the display inherits whatever the DisplayServices
  /// register happened to hold (on the MAG341C, a leftover 0.5 from an earlier
  /// session) while the panel keeps showing the user's value.
  ///
  /// DIVERGENCE from the fork: it adopts that stale register and lets its poller drag
  /// the slider to the hardware. Spec §5 makes the controller the source of truth, so
  /// Candela pushes the other way. Going through `applyPaths` rather than a bare
  /// submit also writes the echo slot, so the poller reads the assert back as an echo
  /// rather than an external change.
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
  ///
  /// Takes no sibling queues: the memos this can poison are dropped from the
  /// wire the controller was built with, on the mirror's observed true-to-false
  /// edge. A caller cannot know whether its call is about to close an HDR
  /// window, and it no longer has to.
  public func setHDRMode(_ mode: HDRMode) async {
    // Role fence: HDR modes are external-display machinery. The built-in is
    // constitutively native already, and a call here would persist a meaningless mode
    // under the builtIn prefs key.
    guard role == .external else { return }
    // SS9's missing half. HDR takes the data cable away, and a synthesized size is a
    // mirror set standing on that same display, so engaging one over the other leaves
    // a combination nothing in the app has measured: the panel in HDR as a mirror
    // slave with the pairing still up.
    //
    // Only the ENGAGE arm, and only while HDR is not already live. Refusing a request
    // that merely records a state System Settings has already produced would leave the
    // mirror lying about a display that IS in HDR. The exit is never refused; it is
    // the way out of exactly this state.
    //
    // The UI disables its engage control while a size is up, so only a click racing a
    // teardown reaches here, which is why the refusal is quiet rather than reported.
    if mode == .alwaysOn, !cachedHDRActive, isShowingSynthesizedSize() {
      pathLog.error(
        "setHDRMode(.alwaysOn) refused: a synthesized size is engaged display=\(self.displayID)"
      )
      return
    }
    let previous = hdrMode
    // `.off` is actionable whenever HDR is LIVE, not only when Candela's own mode
    // says Candela engaged it. HDR turned on in System Settings leaves `hdrMode` at
    // `.off`, so a plain inequality guard returned early and left the app no path at
    // all to drop HDR, while the reset paths were relying on it to unlock the DDC
    // register before writing. Ruling: Candela's mode and the system's HDR state stay
    // in sync, so `.off` means the display leaves HDR whoever put it there.
    //
    // The inequality still guards the case it exists for: a mode the display is
    // ALREADY in is a no-op, so a reset does not re-mode every attached panel.
    //
    // Symmetric on purpose. The panel's HDR button reads the STATE, so with HDR
    // switched off in System Settings under a stale `.alwaysOn` the button offers
    // "HDR On", and a mode-only guard would leave that click dead.
    //
    // NOT preceded by a refresh, though the cache can be stale (R3). That was tried:
    // an await here is a suspension point BEFORE `beginHDRTransition` takes the
    // supersession token, and it broke the overlapping-transition guarantees. The
    // engage arm's own post-refresh re-check remains the answer to a stale cache.
    let observed: HDRMode = cachedHDRActive ? .alwaysOn : .off
    guard mode != previous || mode != observed else { return }
    prefs.hdrMode = mode
    hdrMode = mode
    pathLog.log("hdrMode \(previous.rawValue) -> \(mode.rawValue) display=\(self.displayID)")
    if mode == .alwaysOn {
      if cachedHDRActive {
        // HDR is already live (externally toggled while the mode was `.off`): no
        // setHDR and no settle window, since the state change already happened and a
        // 2 s window would gate the poller off for nothing. The generation bump at
        // door entry (R3) supersedes any parked stale continuation; deliberately NOT
        // `beginHDRTransition()`, because there is no re-mode and `settleInProgress`
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
      // ISSUED, not achieved. The backend reports that it took the lock and assigned
      // `preferHDRModes`; whether the panel switched is asked below, after the
      // settle.
      let issued = await backends.hdr?.setHDR(displayID: displayID, enabled: true) ?? false
      // Supersession guard: this body is a bare async func and the panel spawns one
      // unserialized Task per mode change, so nothing serializes them. If a newer
      // transition started while we were suspended, it owns the state now; mutating it
      // here (stale rollback, clearing the newer transition's settle flag, re-firing
      // applyPaths) would be an orphaned-continuation clobber.
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
        // Engage failed: the mode was committed optimistically above, so roll BOTH
        // the published mirror and the pref back, or a display that cannot engage HDR
        // persists a lying `.alwaysOn` across launches and the badge and menu
        // misreport permanently. The C1 clearing already ran, so re-apply the current
        // value through the normal path once the caches settle; without it the screen
        // is stranded un-dimmed under a low slider.
        //
        // No memo drop written HERE (deliberate asymmetry with the disengage arm):
        // neither way of reaching this arm switched modes BY ITSELF, so the last
        // recorded DDC value normally still reflects the register. The interleaving
        // that falsifies "normally" is covered by the refresh below: an exit whose
        // drop had already taken, superseded by this engage past its own fences,
        // leaves the display OUT of HDR with memos built while the register was
        // locked, and the rollback's `refreshHDRCaches` then sees the mirror go
        // true-to-false and drops them. This arm only knows that ITS write did
        // nothing, not where the panel is.
        //
        // TWO ways of reaching it, and they are different facts. The write was never
        // issued (no panel, or the MonitorPanel lock was busy), or it was issued,
        // returned success, and the display did not switch. The second is a
        // reported success that was never achieved, the defect class this app
        // keeps hitting at every layer.
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
        guard hdrTransitionGeneration == generation else { return } // same fence as the success arm
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
  /// The duplicate memos are reset before the re-apply: hardware left HDR at its own
  /// brightness level, so the last DDC value we recorded no longer reflects the
  /// register. EVERY queue on this display's wire, not just this controller's, because
  /// a write issued while the register was locked is ACKed and swallowed, and the
  /// first thing under a reset or under a person's next click is usually the unmute:
  /// skipped as a duplicate of a write that never landed, and reported applied.
  ///
  /// Shared by the mode door and the reset door so the two cannot drift; what differs
  /// is only WHO decides there is something to do.
  ///
  /// Returns whether it ran to the end. FALSE means a newer transition took the
  /// display mid-flight, so this call knows nothing about where the panel ended up:
  /// `cachedHDRActive` was set optimistically on the way in and the measured refresh
  /// at the bottom never ran. A caller that treats that as "HDR is off" is asserting
  /// the one thing it failed to learn.
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
    // licenses both.
    //
    // The cost of being wrong this way is a brightness write that goes nowhere on a
    // DDC-only panel, and the honest bound on it is LOOSE: it stands until the next
    // reconfiguration or HDR transition refreshes the mirror, which may not be soon.
    // It is specifically NOT bounded by the superseding transition's own refresh,
    // which is measured false in both directions: an engage that was never issued ends
    // on the CACHED read (and the lock-busy arm returns before the cache is even
    // invalidated), and in the clobbering interleaving the superseder's refresh has
    // already happened by the time this write lands.
    //
    // These are the file's only post-fence mutations, and they are deliberate: the
    // fences exist to stop a stale call asserting state it does not know, which is
    // exactly what leaving the optimistic false behind would be.
    cachedHDRActive = false
    _ = await backends.hdr?.setHDR(displayID: displayID, enabled: false)
    // Same supersession fence as the engage arm: the post-await block clears
    // `settleInProgress` and fires `applyPaths`, both of which belong to whichever
    // transition is current.
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
    // KEPT after the invalidation moved to the mirror's edge, because of a window the
    // edge cannot see: the edge fires from `refreshHDRCaches`, and this path's refresh
    // is at the bottom, AFTER the re-apply. The re-apply is itself a DDC write whose
    // memo is stale (the panel left HDR at its own brightness level), so it has to
    // find the memos already dropped or it is skipped as a duplicate of a value the
    // register no longer holds. Between here and the refresh below nothing else in the
    // file knows the window is over.
    //
    // The refresh below fires the edge and drops them a second time, which costs one
    // redundant write and is the trade the reset door's overlap already takes.
    //
    // A bail above leaves them standing on purpose, in step with the assume-locked
    // rule one line up: a superseded call establishes nothing, including that the
    // window is over. The edge covers that instead, up to and including the
    // superseding engage's own rollback.
    invalidateWireMemos()
    applyPaths()
    // Measured, for the reason the engage arm is: a write that returned success is
    // evidence of nothing. This arm does not roll back a disengage that did not take,
    // but the mirror it leaves behind is the panel's answer rather than the
    // request's.
    await refreshHDRCaches(measured: true)
    return hdrTransitionGeneration == generation
  }

  /// Drops what every queue on this display's wire believes is in the register:
  /// this controller's memo and its siblings'.
  ///
  /// One rule, one definition, three moments that need it: the observed edge
  /// (every route out of HDR, including the ones with no caller of ours), the
  /// exit's own re-apply, and a reset asking about a window that closed before
  /// it was called. Over-invalidating costs a redundant write;
  /// under-invalidating leaves a swallowed value certified as landed, which on a
  /// write-only panel nothing downstream can detect.
  private func invalidateWireMemos() {
    resetWriteMemo()
    for sibling in wireSiblings { sibling.resetWriteMemo() }
  }

  /// Asks the display whether the DDC register is free, for a caller that is
  /// about to write it and must not report the write as landed unless it did.
  ///
  /// The read-only half of `disengageHDRForReset`: that door CHANGES the display (it
  /// drops HDR and clears the stored mode), which is right for a button whose job is
  /// clearing settings and wrong for one that promises only an unmute.
  ///
  /// Deliberately not `isHDREngaged`. That mirror is written optimistically by
  /// transitions and lags a System Settings toggle until the reconfiguration arrives,
  /// so a write licensed by it can go straight into a locked register.
  ///
  /// Drops the wire's duplicate memos for the reason the reset door does: a value
  /// ACKed and swallowed inside an HDR window nobody observed closing leaves a memo
  /// naming a value the register never took, and the first write over the top of one
  /// is usually the unmute.
  ///
  /// The bound, the same one the reset door carries: this describes the display as of
  /// this call. Nothing here stops a transition that begins after it returns, which is
  /// why a caller confirms afterwards rather than only asking first.
  public func hdrWriteWindow() async -> HDRWriteWindow {
    defer { invalidateWireMemos() }
    // The built-in takes no DDC at all, so the register question is moot; the
    // reset door returns early on the same test.
    guard role == .external else { return .open }
    // An observation, not a transition (the reset door's fence, same reason):
    // bumping the generation here would supersede a transition parked on its
    // own await.
    let observed = hdrTransitionGeneration
    await refreshHDRCaches(measured: true)
    guard hdrTransitionGeneration == observed else { return .unknown }
    return cachedHDRActive ? .locked : .open
  }

  /// The reset paths' HDR disengage: makes the DISPLAY leave HDR, and asks the
  /// display rather than the stored mode whether there is anything to do.
  ///
  /// Deliberately NOT `setHDRMode(.off)`. That door decides from the stored mode and
  /// the cached mirror, which is right for a request a person made about a policy and
  /// wrong here. The mirror lags a System Settings toggle until the reconfigure lands,
  /// and in that window every input the mode door consults says "already off" while
  /// the panel is in HDR: the request evaporates, the reset's own D29 unmute goes into
  /// a register the monitor still has locked, and a write-only panel ACKs the loss. So
  /// the physical state is measured here, past the backend's cache.
  ///
  /// On an external display Candela's stored mode is cleared whatever the panel turns
  /// out to be doing: it is a setting, and clearing settings is what the button does.
  /// (The built-in has no HDR mode to clear and returns early.)
  ///
  /// The result is evidence, not a request. `.disengaged` is reported only off a
  /// MEASURED read taken after everything this call did, and only when no other
  /// transition was seen driving this display, so a caller may treat it as "the
  /// register is not locked". Anything else is `.unknown`, and the caller must then
  /// neither write DDC nor re-engage. The bound: this describes the display as of this
  /// call, nothing here stops a transition that begins after it returns, and the app's
  /// reset latch does not cover the panel's own HDR button. What it rules out is a
  /// reset proceeding on a state it never established.
  ///
  /// The unconditional memo sweep below is as load-bearing as the disengage itself.
  /// Each queue skips a write whose value its memo says is already in the register,
  /// and under HDR an I2C write is ACKed and swallowed, so a memo built through an HDR
  /// window records values that never reached the panel: left standing, the reset's
  /// own unmute is skipped as a duplicate of a write that never landed and the skip is
  /// reported as applied. A rebind clears those memos too, but it lands when a display
  /// is rediscovered, so it is neither synchronous with this nor ordered before the
  /// unmute.
  ///
  /// NOT made redundant by the observed edge. That edge fires on a mirror going
  /// true-to-false, so it only sees a window some refresh OBSERVED as live, and the
  /// ordinary way to miss one is a coalesced pair: the app's topology stream reports
  /// once per quiet window and buffers the newest event, so HDR switched on and off
  /// again inside one window arrives as a single delivery showing only the final
  /// state. A non-measured read answering from the backend's cache lags the engage the
  /// same way. This path is about to write DDC on the strength of those memos and is
  /// the one place that can pay for certainty; dropping a memo the edge already
  /// dropped costs nothing.
  public func disengageHDRForReset() async -> HDRResetDisengage {
    defer { invalidateWireMemos() }
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

  /// Puts back HDR that was live before a reset and that Candela did not turn on,
  /// recording no mode for it.
  ///
  /// The reset paths drop HDR first so the DDC register is unlocked for the D29 unmute
  /// below them. Whether the display stays out of HDR afterwards is the negotiable
  /// part, and the ruling is that it does not: a reset clears **Candela's** settings,
  /// and HDR the user engaged in System Settings was never one of them.
  ///
  /// Which is why this is not `setHDRMode(.alwaysOn)`: that persists `.alwaysOn`, so a
  /// reset promising to clear settings would end by writing one. Leaving `hdrMode` at
  /// `.off` under live HDR is the honest record, and the brightness path already
  /// handles it (`usesNative` routes native under externally-engaged HDR).
  ///
  /// Otherwise the engage arm's machinery exactly: C1 clearing, the settle window with
  /// the poller gated off, and the measured check. No rollback, because there is no
  /// mode to roll back to; a restore that does not take leaves the display where the
  /// disengage left it and says so.
  ///
  /// Settling the WHOLE wire first is load-bearing, not a convenience. Re-engaging HDR
  /// locks the DDC register, and a DDC submit is queued rather than sent: it rides a
  /// coalescer that drains on its own task, so the reset's unmute can still be in
  /// flight when this is called. Measured 2026-08-11: the queued writes reached the
  /// panel after the re-engage, the last more than a second later, and were swallowed
  /// while the app recorded an unmuted display, which is the strand D29 exists to
  /// prevent. The queues come from the controller's wire rather than from the caller,
  /// because which queues share this register is a fact about the display, and a
  /// caller that has to remember it can forget.
  ///
  /// A queue that cannot be settled SKIPS the re-engage, loudly. That is the safe
  /// direction by a wide margin: a display left out of HDR is visible and one click
  /// from fixed, against a monitor stranded silent behind a locked register with the
  /// app reporting it unmuted.
  public func restoreExternalHDR() async {
    guard role == .external else { return }
    guard await WireQuiescence.settle(
      [self] + wireSiblings,
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

  /// One leg of a TRANSIENT HDR round trip another feature needs on this display,
  /// taken through the controller so the brightness stack sees the window it opens.
  ///
  /// Deliberately NOT `setHDRMode`. Nothing here is a preference: `hdrMode` and
  /// `prefs.hdrMode` are untouched, so a link renegotiation cannot rewrite the mode a
  /// person chose, and the `.off` door stays live afterwards because `cachedHDRActive`
  /// ends this call as a measured answer rather than the stale false the mode guard
  /// would return early on.
  ///
  /// DDC does not work while the display is in HDR, which is the whole reason for the
  /// routing. The transition token supersedes a parked transition, `settleInProgress`
  /// and the optimistic mirror take the brightness legs off DDC BEFORE the write goes
  /// out, and the wire's duplicate memos are dropped on the way out of every leg. A
  /// window the brightness stack never heard about leaves values ACKed, swallowed and
  /// recorded as landed, which on a write-only display nothing downstream can detect.
  ///
  /// Returns the MEASURED state after the settle, never the write's ACK. False
  /// whenever a newer transition took the display mid-flight: a superseded call
  /// established nothing, so it may not claim its leg landed.
  ///
  /// `settle` is the caller's, because the caller is the one that has to state its own
  /// worst case: six legs of a link bounce pay this window six times, inside a gate
  /// claim nothing else can take. Omit it to take `settleDelay`.
  @discardableResult
  public func setTransientHDR(_ enabled: Bool, settle: Duration? = nil) async -> Bool {
    guard role == .external else { return false }
    beginHDRTransition()
    let generation = hdrTransitionGeneration
    // Optimistic for the duration, in both directions, and written BEFORE the
    // await: the legs have to stop treating DDC as reachable while the display
    // enters HDR, and must not resume until the exit has been confirmed.
    cachedHDRActive = enabled
    _ = await backends.hdr?.setHDR(displayID: displayID, enabled: enabled)
    guard hdrTransitionGeneration == generation else {
      cachedHDRActive = true // assume locked: the exit path's rule, same reason
      return false
    }
    try? await Task.sleep(for: settle ?? settleDelay)
    guard hdrTransitionGeneration == generation else {
      cachedHDRActive = true // assume locked
      return false
    }
    settleInProgress = false
    // Unconditional, and on BOTH legs. The observed edge in `refreshHDRCaches`
    // only fires for a window some refresh saw live, and a bounce is precisely
    // the window that can open and close between two refreshes.
    invalidateWireMemos()
    await refreshHDRCaches(measured: true)
    guard hdrTransitionGeneration == generation else { return false }
    // No `clearSoftwareLeg` on the way in, so there is no cleared leg to
    // rebuild: leaving the window only needs the current value re-asserted
    // through whichever path applies now that the register is back.
    if !enabled { applyPaths() }
    return cachedHDRActive == enabled
  }

  /// Re-evaluates the cached HDR state; the topology loop calls it for every
  /// surviving display after `HDRToggling.displaysReconfigured()`. Detecting an
  /// externally-toggled HDR entry runs the C1 clearing.
  ///
  /// The EXIT direction has no work here and is not missing: an HDR window closing is
  /// handled inside `refreshHDRCaches`, where the observation is made. That covers HDR
  /// dropped in System Settings or on the display's own controls, which reaches
  /// Candela as a reconfiguration and leaves the wire's memos naming values the panel
  /// swallowed.
  public func noteHDRStateMayHaveChanged() async {
    let wasNative = usesNative
    // Capture only: this is a state *observation*, not a transition, so it must not
    // bump the token. An HDR toggle provokes a reconfigure of its own, and superseding
    // here would strand the very transition that caused it (its post-settle block
    // would bail with `settleInProgress` stuck true). Guarding still applies: a
    // transition that started during the refresh owns the state.
    let generation = hdrTransitionGeneration
    await refreshHDRCaches()
    guard hdrTransitionGeneration == generation else { return }
    if !wasNative, usesNative {
      clearSoftwareLeg()
      assertNativeEntryBrightness()
    }
  }

  /// Reconfigure re-apply: the WindowServer rebuilt display state, so re-capture the
  /// gamma baseline, re-pin shade frames, and re-run the software leg for the current
  /// value. Skipped under the native path per C1. Ordering contract: the app-side loop
  /// calls `resetAllGamma()` once per event BEFORE this, so the table is OS-owned.
  public func handleReconfigure(recapture: Bool = true) async {
    // recapture: false is the interference-accept path: at accept time the
    // interfering app may own the table, and capturing that as the baseline bakes its
    // curve in. The next real reconfiguration recaptures normally.
    if recapture {
      backends.gamma?.recaptureDefaultTable(on: displayID)
      // SS15's companion leg makes the island hold a baseline for a display this
      // controller does not own, and a synthesis disengage destroys that display
      // while CoreGraphics is free to reissue its ID. Dropping the baseline here
      // is what stops a re-engaged slot from scaling a new display's table
      // against a destroyed one's.
      if let companion = lastGammaCompanionID, companion != displayID {
        backends.gamma?.recaptureDefaultTable(on: companion)
        lastGammaCompanionID = nil
      }
    }
    backends.shade?.repinFrames()
    lastAppliedSw = nil
    // WD3: the WindowServer rebuilt this display's state, which is exactly the
    // moment a wire that stopped answering deserves to be asked again.
    let wasUnresponsive = isWireUnresponsive
    resetWireHealth()
    if wasUnresponsive, !usesNative {
      // The transition already ran the full D28 re-evaluation, which covers the
      // software leg below AND the register hand-back it cannot do. Re-running
      // the tail would write the same leg a second time, undimmed.
      return
    }
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

  /// `measured: true` reads the panel now, past the backend's 2 s cache. Every
  /// decision about whether a transition ACHIEVED anything has to pass it: the cached
  /// read keeps the mirror roughly fresh and is useless as evidence, because a cache
  /// filled during the transition answers with the transition's own optimism.
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
    // The DDC register just came back, whoever unlocked it. Keyed to the OBSERVED
    // edge rather than to a call because most routes out of HDR have no call of ours
    // in them: HDR switched off in System Settings or on the display's own controls
    // arrives as a reconfiguration, and an exit superseded by an engage that then
    // fails arrives as the rollback's refresh. Both leave memos naming values the
    // panel ACKed and swallowed while it was locked, and the first write over the top
    // of one is usually the unmute.
    //
    // Only true-to-false. An ENTRY is a window opening, and nothing built through it
    // exists yet.
    //
    // The bound, which is what keeps the reset door's own sweep: this sees windows a
    // refresh OBSERVED as live. A window that opened and closed between two refreshes
    // never sets the flag and so never produces an edge.
    let wasObservedActive = observedHDRActive
    observedHDRActive = cachedHDRActive
    // WD3's HDR route, on BOTH edges and in the one place that sees every one:
    // most routes through an HDR window (System Settings, the display's own
    // controls) make no call of ours. Entering counts too, because a write
    // submitted just before the engage is stamped countable and then fails on
    // the lock.
    let hdrEdge = wasObservedActive != cachedHDRActive
    defer { if hdrEdge { resetWireHealth() } }
    if wasObservedActive, !cachedHDRActive {
      // Logged because on a write-only panel this is the only observable that
      // separates the fix from the bug: the swallowed write and the skip that
      // certifies it both look like success from every other angle.
      pathLog.log(
        "HDR window closed on display=\(self.displayID): dropping the wire's duplicate memos"
      )
      invalidateWireMemos()
    }
    updateNativeActive()
  }

  private func updateNativeActive() {
    let active = usesNative && !settleInProgress
    echo.withLock { $0.nativeActive = active }
  }

  // MARK: - Poller contract

  /// Poller entry: eases the published value toward an externally-observed native
  /// brightness (Control Center, ambient) instead of jumping. The fork's asymptotic
  /// rule: snap within 0.01, else 1/3 of the gap with a 0.005 signed minimum step.
  /// Never submits a hardware write, because the hardware already holds the external
  /// value and writing back would fight its author.
  ///
  /// Returns the delta actually applied to published state: the eased step, not the
  /// full observed change, and 0 when the adoption was discarded as stale.
  /// `BrightnessSync` fans that delta out to the other displays.
  @discardableResult
  public func adoptExternal(_ value: Double, generation: UInt64) -> Double {
    // Generation check first: an adoption queued before a local write (during a
    // starved drag, say) is stale, so discard it entirely.
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
    // DIVERGENCE: the fork persists the raw read; Candela persists the eased value
    // so published and stored state never diverge.
    persist(eased)
    echo.withLock { state in
      guard state.generation == generation else { return }
      state.value = eased
      state.converging = !snapped
    }
    return eased - previous
  }

  /// Poller echo check: the last locally-originated native value (or the adoption
  /// currently converging), generation-tagged so the poller can hand the generation
  /// back to `adoptExternal`.
  public nonisolated func expectedNative() -> (value: Double?, generation: UInt64) {
    echo.withLock { ($0.value, $0.generation) }
  }

  /// Poller gate: true only when the native path is active AND any HDR settle window
  /// has completed. Constitutively true for role `.builtIn`, which is always on the
  /// native path and runs no HDR settle machinery.
  public nonisolated func isNativeActive() -> Bool {
    role == .builtIn || echo.withLock { $0.nativeActive }
  }

  /// True while an external adoption is still easing toward its target: the poller
  /// must keep polling, and not discard reads as echoes, until the snap fires.
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
  /// `refreshFromHardware`) after a display rediscovery and, only when
  /// `panelIdentity` says the panel on the other end has CHANGED, drops the three
  /// read-derived facts that were evidence about the old one.
  ///
  /// The coalescer's duplicate memo resets UNCONDITIONALLY: rediscovered hardware is
  /// in a state we did not write through the service we now hold, so re-asserting the
  /// current value must not be skipped as a duplicate. That is true of every rebind,
  /// panel swap or not, which is why it sits outside the identity check.
  ///
  /// WHAT RESETS ON A PANEL CHANGE:
  ///
  /// - `didReadMaxDDC` (B5), or a display that replugs into a read-failing state keeps
  ///   reporting "this maximum was read from the panel" on the strength of a read from
  ///   a previous binding.
  /// - `readEvidence` (B3) back to `.notAttempted`, the floor: we have asked THIS
  ///   panel nothing. Not a weakening of worst-wins, which folds within a pass and
  ///   across sibling controllers, neither of which survives a swapped monitor.
  /// - `maxDDCValue` back to `assumedMaxDDC`. Resetting the provenance flag and
  ///   leaving the number keeps the motivating scenario alive on the write path
  ///   itself: a previous panel that reported 80 leaves the NEW panel's writes scaled
  ///   against 80 indefinitely, because the new panel never reports and nothing
  ///   corrects it, while `didReadMaxDDC` says "assumed".
  ///
  /// WHY A PANEL IDENTITY AND NOT THE WRITER. Firing on every `rebind` call is wrong:
  /// `AppModel.performRefresh` rebinds every KEPT display on EVERY pass (wake,
  /// reconfiguration, menu open), so it dropped a readable panel's reported maximum
  /// several times a session, and the recovering re-read is a no-op unless
  /// `startupAction == .read` and useless on a write-only panel. Comparing the writer
  /// does not work either: `DisplayDiscovery.discover()` builds a fresh
  /// `Arm64DDCService` per pass and the `IOAVService` inside it is freshly created per
  /// pass too (a CFTypeRef compared by pointer), so neither identity is stable across
  /// a plain refresh. `Arm64Service.serviceLocation` is stable, but it names the PORT,
  /// so it is unchanged in precisely the swap this reset exists for.
  ///
  /// `ExternalDisplay.persistenceKey` (EDID UUID, falling back to
  /// productName/manufacturer/serial) is what discovery already computes to tell
  /// panels apart, and is the key this controller's `storageKey` derives from. Its
  /// limitation is inherited: identical twins can share an EDID UUID and are not told
  /// apart here, though they already share a saved value and a prefs domain. The cost
  /// of the narrower trigger is that the SAME panel rebound through a DDC-hostile new
  /// route keeps its old verdict until the next read pass supersedes it, which here is
  /// the very next refresh.
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
      // Same rule as the read evidence directly above: a verdict earned by the
      // panel that was here is not a fact about the one that replaced it.
      resetWireHealth()
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

  /// D5's "stored (= ever-touched)" gate for the restore pass's brightness leg (fork
  /// isTouched, R4): true once a session ever published a value for this display.
  /// Fresh displays publish an ASSUMED default (1.0) over an empty store, and a
  /// restore pass must never write that. `AppModel.performRestorePass` checks this
  /// instead of reaching into the store. (A successful `.read` also persists, marking
  /// the command ever-touched, which is harmless: that value came from the panel.)
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
  /// Scope of the "a process that dies while dimmed still reopens correctly" claim:
  /// unconditional on a write-only panel, where the store IS the truth. On a panel
  /// that answers DDC reads the hazard is a readback of a register we dimmed, and it
  /// is not confined to launch, since `refreshFromHardware` also runs on every
  /// reconfiguration, which a lock dim outlasts. THIS process is covered, because that
  /// function returns early while a dim is outstanding. What is left is a readback by
  /// a process that did not set the dim: the next launch after a crash or force-quit,
  /// which finds the register still down with no factor recorded anywhere. The store
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

  /// Re-asserts the current value on whatever path is live (the restore pass's
  /// brightness leg). Routed through `applyPaths`, not a bare submit, so the echo slot
  /// stays honest for the poller; the software leg re-apply dedupes to a no-op.
  ///
  /// Deliberately NOT gated on `hasStoredValue`: the R4 gate lives in
  /// `AppModel.performRestorePass`, which must skip this call for a display whose
  /// published value is still the assumed 1.0 default over an empty store.
  public func reassertHardware() {
    applyPaths()
  }

  // MARK: - Settings re-apply (D28)

  /// Which software backend the CURRENT prefs select, if any. Pure DDC and the
  /// native path have no software leg at all, and that `.none` is exactly what
  /// `handleReconfigure`'s early `return` failed to act on.
  private enum SoftwareBackendChoice { case none, gamma, shade }

  /// A projection of the same table (B1), so the rule is not copied a third time.
  ///
  /// `.softwareOnly` must answer with its backend exactly as `.software` and
  /// `.combined` do: folding it into `.none` would strand a scaled gamma table
  /// installed forever, because `reapplyAfterPrefChange` tears down only the backend
  /// this does NOT name.
  ///
  /// `.unavailable` answers `.none` for both engine states behind
  /// `.unavailable(.ddcTurnedOffWithNoSoftwareLeg)`, which `BrightnessPath` cannot
  /// tell apart:
  ///
  /// - (A) combined DISABLED plus `unavailableDDC`.
  /// - (B) combined ON plus `unavailableDDC` plus `switchingValue == 0` (pref point
  ///   −8, "pure hardware"), which the older prefs-shaped version answered
  ///   `.gamma`/`.shade`.
  ///
  /// Safe TODAY because the only consumer is `reapplyAfterPrefChange`, and in state
  /// (B) `combinedSplit`'s hardware branch always wins, so the software leg is pinned
  /// at `sw == 1`: "reset gamma to 1.0 / remove the shade" and "apply sw 1" land on
  /// the same screen. `PathSelectionTests` pins that equivalence.
  ///
  /// It stops being safe the moment a consumer other than `reapplyAfterPrefChange`
  /// acts differently on `.none` than on `.gamma`/`.shade`, treating it as "this
  /// display has no software leg configured" rather than "nothing needs to be left
  /// installed". State (B) would then need a distinguishable path, not a
  /// distinguishable branch here.
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
  /// `handleReconfigure(recapture:)` is NOT that door and must not be used for it: it
  /// re-runs the software leg only, and returns before applying anything in pure-DDC
  /// mode. This entry point instead:
  ///
  /// 1. tears down whichever software backend the new prefs do NOT select, because
  ///    `applySoftware` writes one backend and never clears the other, so without this
  ///    a gamma-to-shade switch double-dims and a switch to pure DDC leaves a scaled
  ///    table installed forever;
  /// 2. clears the software dedupe and the coalescer's duplicate memo, so a re-apply
  ///    at an unchanged value still reaches the wire;
  /// 3. re-runs FULL path selection for the current published value, writing both legs
  ///    in the order the ordering rule below fixes;
  /// 4. hands the brightness register back at full range if the new path has stopped
  ///    driving it, which is step 1 applied to the OTHER leg: for DDC, "torn down"
  ///    means parked where software dimming assumes it is rather than left at the
  ///    combined-mode floor.
  ///
  /// The published `brightness` is untouched: a mode switch is a re-conversion of the
  /// same perceptual value, never a reset to 100% (D4).
  ///
  /// Deliberately does NOT recapture the gamma baseline: step 1 hands the table back
  /// at scale 1.0 whenever gamma is being abandoned, and a settings edit is not a
  /// WindowServer rebuild.
  ///
  /// STILL SYNCHRONOUS, which D28 requires, but the software side may finish later
  /// than the call returns.
  ///
  /// THE ORDERING, one rule and not two. The register write drains off-actor and takes
  /// ~17 ms on the MAG while everything on the software side is inline and lands at
  /// once, so the leg that is going DOWN has to go first, or the display renders a
  /// frame from the old register under the new table and overshoots both endpoints:
  ///
  /// - the register RISES (the hand-back, and any pref change that raises it): the
  ///   software side goes first, inline, and the in-flight state is the old register
  ///   under the new, dimmer table;
  /// - the register DROPS (turning hardware control back on at a value the combined
  ///   split puts at the register's floor): the software side is HELD until the write
  ///   lands, so whatever is dimming the display keeps dimming it and the in-flight
  ///   state is the OLD state rather than a bright composite of the two.
  ///
  /// Held means the whole software side, teardown included. Tearing an abandoned
  /// backend down is itself a brightening, so holding only the re-apply would move the
  /// flash rather than remove it, and keeping the pair together preserves step 1's
  /// no-double-dim property: the old backend is still the only one dimming until both
  /// run.
  ///
  /// The cost is that a display whose register write is slow keeps its previous
  /// dimming for that long, which is the state the user was already looking at.
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
    if choice != .gamma, let gamma = backends.gamma {
      writeGammaScale(1.0, using: gamma, enforcerOn: drawable)
    }
    lastAppliedSw = nil
    applyPaths(.software)
    handBackDDCLegIfAbandoned()
  }

  /// Parks the software side until the register write just submitted has landed. The
  /// generation is captured now, so a write submitted later cannot extend the wait.
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

  /// Hands the brightness register back at full range when the newly selected path
  /// has stopped driving it.
  ///
  /// Without this the teardown is one-directional: turning "Use hardware (DDC)
  /// control" back ON writes the register immediately, while turning it OFF wrote
  /// nothing at all, so software dimming ran on top of a panel already at its hardware
  /// minimum. At 40% combined that is DDC 0, and at 100% software there is nothing
  /// left to brighten with, because the gamma table is already at 1.0. The app
  /// reported 100% over a panel at its minimum backlight.
  ///
  /// ORDER IS THE CONTRACT, and it is the opposite of the intuitive one: this runs
  /// AFTER `applyPaths`, never before. This write only ever RAISES the register, and
  /// the software leg it hands over to only ever LOWERS what the register emits, so:
  ///
  /// - raise first and the intermediate state is a full-range register under the old,
  ///   brighter gamma table: at 90% that is raw 100 under gamma 1.0, a flash to full
  ///   brightness for as long as the two writes are apart, which D4 forbids by name;
  /// - raise second and the intermediate state is the old register under the new,
  ///   dimmer table, never brighter than either endpoint.
  ///
  /// No ordering is transient-free. The software leg is inline and synchronous while
  /// the register write drains off-actor through the coalescer, so the two land
  /// milliseconds apart whatever we do. The ordering buys a gap that sits INSIDE the
  /// two endpoints instead of overshooting past both.
  ///
  /// The mirror image, a pref change that DROPS the register while the software leg
  /// brightens, cannot be fixed by reordering two synchronous statements:
  /// `reapplyAfterPrefChange` holds the software side until the register write has
  /// actually landed. Same rule stated once: the leg that goes down goes first.
  ///
  /// Gated on `unavailableDDC` exactly as `restoreFullRangeDDC` is: a command the
  /// display has declared it does not support, or the user has switched off, is not
  /// one to write on the way out. That leaves the tuning grid's own Off switch able to
  /// strand a display the same way this fixes, which is the shape of D29 rule 1 (undo
  /// the disabling effect BEFORE persisting the value that disables it) and belongs in
  /// that control, not here.
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

  /// Quit restore: writes the register's FULL-RANGE equivalent of the published
  /// value, because software dimming is torn down at quit and leaving the
  /// combined-mode DDC floor would strand the monitor dark. Best-effort: skipped under
  /// the native path (DDC is dead there) and for forceSoftware or disabled displays.
  /// Synchronous by design, so it is callable straight from
  /// `applicationWillTerminate`: the submit is a nonisolated lock store and the
  /// coalescer drains off-actor, so the quit path's barrier only has to keep the
  /// process alive until the write lands, never block the main thread on DDC I/O.
  ///
  /// Reads `brightness`, so a quit during a temporary dim writes the UNDIMMED value
  /// and hands the register back to the user's setting. That is a backstop, not the
  /// contract: the owner of the dim still ends it explicitly at teardown, because this
  /// call returns early on three paths, native included, which is where an HDR
  /// display's dim lives.
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

  /// The last brightness target that actually reached this display's hardware (B4),
  /// or nil if nothing has: nothing submitted, everything failed, or a reset
  /// invalidated what had landed.
  ///
  /// `nonisolated` over the coalescer's existing lock, exactly like
  /// `_duplicateResetCount()`, so a settings row reading it during a refresh pays no
  /// executor hop.
  public nonisolated func lastAppliedTarget() -> HardwareTarget? {
    coalescer.lastAppliedTarget()
  }

  /// Whether the most recent apply ATTEMPT on this display failed (B4). Without it
  /// "this monitor is ignoring us" is observable to the code and unsayable to the
  /// user: the applier's `Bool` decided whether to advance the duplicate memo and was
  /// then dropped.
  public nonisolated func lastApplyFailed() -> Bool {
    coalescer.lastApplyFailed()
  }
}

/// Drains hardware brightness targets off the main actor, coalescing latest-wins:
/// every write jumps straight to the newest target, as fast as the hardware
/// transaction allows (a DDC write's internal per-cycle sleeps are the only pacing).
/// Each target carries its own applier, DDC or native, so one coalescer serves every
/// hardware path. Eased intermediate stepping was tried and cut: it made drags "feel
/// slower" on the MAG341C, whose DDC apply-path is the bottleneck, and the real
/// smoothness fix is software dimming rather than write-shaping.
///
/// Submission is a synchronous, nonisolated store into an
/// `OSAllocatedUnfairLock`-protected slot (newest-wins, the slot *is* the
/// pending-target buffer). Storing never requires an executor hop, so a @MainActor
/// caller can submit while the run loop is stuck in event-tracking mode. The single
/// drain loop dequeues the newest target, so intermediates that arrive while a write
/// is in flight are dropped and the final value always lands. Each submitted target
/// carries a monotonic generation; `waitUntilCompleted(through:)` suspends until a
/// target with at least that generation has been applied or skipped, and a newer
/// target superseding an older, dropped one completes the older generation too.
actor BrightnessWriteCoalescer {
  struct PendingWrite: Sendable {
    let target: HardwareTarget
    /// Carried per write so one coalescer serves any hardware path, and so a
    /// controller-level `rebind(writer:panelIdentity:)` takes effect on the next
    /// submitted write: the applier is rebuilt at submit, not held here.
    let applier: any BrightnessApplying
    /// Display-reconfiguration epoch stamped at submit time; the drain skips
    /// targets whose epoch is no longer current.
    let epoch: UInt64
    let generation: UInt64
    /// Whether live HDR was engaged, or its settle window open, when this write was
    /// submitted (WD1). Such a failure is not counted against the wire: the register
    /// is locked there, so it is expected and temporary.
    ///
    /// Stamped at SUBMIT because HDR state is main-actor cached and the drain runs off
    /// the actor. That is one wire transaction early, but every HDR transition resets
    /// the health (WD3), so the gap cannot leave a failure counted.
    var hdrExcluded = false
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

  /// Epoch gate consulted by the drain before applying. A lock-protected slot, same
  /// pattern as the submission slot, because the real checker is wired after
  /// construction via `setEpochGate`. The default accepts every epoch, for call sites
  /// that have none.
  private nonisolated let epochGate: OSAllocatedUnfairLock<@Sendable (UInt64) -> Bool>

  /// Last target actually applied to hardware, for the duplicate-skip: re-sending the
  /// value already on the wire saturates the DDC/I2C bus for nothing. Compared via
  /// `HardwareTarget` `Equatable`, because targets are what hit hardware, so the same
  /// target carried by a different applier is still a duplicate. `target` is `nil`
  /// until the first successful apply. Lives in a lock rather than actor state so
  /// `resetDuplicateState()` can clear it synchronously from any context.
  ///
  /// `resets` versions the memo against a reset racing an in-flight apply: a
  /// `resetDuplicateState()` that lands mid-apply must win over that apply's success,
  /// because on a rebind the in-flight value reached the OLD hardware and recording it
  /// would duplicate-skip the next same-value write to the new panel forever. The
  /// drain captures `resets` before applying and only records the outcome if no reset
  /// intervened.
  ///
  /// `lastFailed` rides in the same slot (B4): the LATEST attempt's outcome, not the
  /// worst one, since a display that failed once and has worked ever since is working
  /// and a latched flag would send someone hunting a cable that is fine. It is a
  /// second field of the fact this lock already guards, written in the same critical
  /// section under the same `resets` guard.
  ///
  /// `wireHealth` rides here for the reason `lastFailed` does: a lock of its own would
  /// let a reset that raced an apply update one fact and not the other.
  private nonisolated let lastApplied =
    OSAllocatedUnfairLock<(
      target: HardwareTarget?, resets: UInt64, lastFailed: Bool, wireHealth: DDCWireHealth
    )>(
      initialState: (nil, 0, false, DDCWireHealth())
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

  /// Clears the duplicate memo (nonisolated, synchronous). A replugged monitor or an
  /// HDR exit returns hardware to a state we did not write, so the memo has to be
  /// clearable, or the next write to the same value is skipped forever.
  nonisolated func resetDuplicateState() {
    // Bumping `resets` invalidates any apply currently in flight — see the
    // `lastApplied` comment. `lastFailed` clears with it: a reset means the
    // hardware is in a state we did not write, so a failure recorded against
    // the OLD wire is not a fact about the new one, and reporting it would
    // accuse a freshly plugged panel of a fault the previous one had.
    // The health is deliberately NOT cleared here: this runs on every re-apply
    // and every dim step, where the hardware state is unknown but the WIRE's
    // record is untouched. Its own routes are WD3's `resetWireHealth`.
    lastApplied.withLock { $0 = (nil, $0.resets + 1, false, $0.wireHealth) }
  }

  /// WD3's reset: the next writes decide again. Nonisolated over the lock the
  /// health lives in, so the main-actor doors that own the reversibility routes
  /// can call it synchronously.
  nonisolated func resetWireHealth() {
    lastApplied.withLock { $0.wireHealth.reset() }
  }

  /// The wire's current verdict (WD1). Nonisolated over the lock for the reason
  /// `lastApplyFailed()` is: path selection reads it on the drag path and must
  /// not hop onto the drain's actor to do it.
  nonisolated func wireHealth() -> DDCWireHealth {
    lastApplied.withLock { $0.wireHealth }
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
      // Epoch gate: a target stamped before a display reconfiguration must not land
      // on rebuilt hardware. Skip the applier, but still COMPLETE the generation
      // below (the deadlock rule: every dequeued target completes, so no waiter is
      // left suspended). `lastApplied` does not advance on a skip, because the
      // skipped target never hit hardware.
      //
      // `landed` is whether this target ends up ON the wire, a different fact from
      // its generation completing: both skips complete too, so a caller that waits
      // for completion and concludes "the value is on the panel" is trusting a
      // counter that says nothing of the kind. `appliedGeneration` is the fact
      // itself, and the reset paths wait on it.
      var landed = false
      let isEpochCurrent = epochGate.withLock { $0 }
      if isEpochCurrent(write.epoch) {
        // Duplicate-skip: never rewrite the target already on the wire, since
        // duplicate re-sends saturate the bus for nothing. The generation still
        // completes.
        let memo = lastApplied.withLock { $0 }
        if write.target != memo.target {
          // Only a *successful* apply means the value is on the hardware. Advancing
          // `lastApplied` after a failed apply would make the next identical target
          // look like a duplicate and get skipped, leaving brightness stuck at the
          // old level until the user moved to a different value. And only an apply
          // with no intervening reset may record its target: a reset that raced this
          // apply means the value landed on hardware we no longer trust, which the
          // `resets` captured in `memo` above detects.
          //
          // The same guard covers the failure flag (B4), not just the target: a reset
          // that raced this apply means the failure was against the old wire, and
          // recording it afterwards would make a freshly rebound panel report a fault
          // it never had. Both fields move together, inside one critical section, or
          // neither does.
          let didApply = await write.applier.apply(write.target)
          landed = didApply
          lastApplied.withLock { state in
            guard state.resets == memo.resets else { return }
            state.lastFailed = !didApply
            // DDC only: a native apply says nothing about a wire, and counting
            // one would demote the built-in panel, which has none.
            if write.target.kind == .ddc {
              state.wireHealth.noteApply(succeeded: didApply, hdrExcluded: write.hdrExcluded)
            }
            if didApply {
              state.target = write.target
            }
          }
        } else {
          // Skipped because this exact target is already on the wire, which is
          // the state the caller wanted: landed, without a redundant write.
          // The health hears nothing: a run of skips is not a run of successes.
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
