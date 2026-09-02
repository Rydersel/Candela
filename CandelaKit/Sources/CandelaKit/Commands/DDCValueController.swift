import Observation

/// Single source of truth for one display's value on one pure-DDC command —
/// volume or contrast — the sibling of `BrightnessController`: no
/// software leg, no native leg, no HDR machinery, no poller. Owns its own
/// write coalescer (and a second one for the VCP 0x8D mute companion): mute
/// wire values 1/2 overlap small volume raws, and a shared duplicate memo
/// would cross-suppress them.
///
/// Under HDR, writes are best-effort with last-written tracking (fork
/// parity): DDC is dead while the display is in HDR mode, so the register catches
/// up on the next write after HDR exits, or via startup/wake restore.
@MainActor @Observable
public final class DDCValueController: PendingWireDraining {
  public nonisolated let command: DDCCommand
  public private(set) var value: Double
  /// Logical mute flag (volume only; constitutively false for contrast).
  /// Persists in BOTH mute strategies — this resolves the fork's
  /// stepVolume/toggleMute persistence inconsistency toward always-persist.
  public private(set) var isMuted: Bool
  /// Per-command disable (fork unavailableDDC) AND the display-level
  /// forceSoftware opt-out (fork isSw()): a display forced to
  /// software dimming gets NO DDC volume/contrast/mute traffic at all — the
  /// user set that pref because the DDC wire is broken. One choke point:
  /// step/setValue/toggleMute/restoreToHardware/refreshFromHardware all
  /// guard on this. Read live so a `defaults write` lands on the next
  /// key/slider event without a relaunch.
  public var isAvailable: Bool {
    !prefs.tuning(for: command).unavailableDDC && !prefs.forceSoftware
  }

  @ObservationIgnored private var writer: any DDCWriting
  /// Which physical panel this controller's read-derived state is evidence
  /// ABOUT — see `rebind(writer:panelIdentity:)` for why it is a panel
  /// identity and not the writer object.
  @ObservationIgnored private var boundPanelIdentity: String?
  @ObservationIgnored private let prefs: DisplayPrefs
  private let coalescer: BrightnessWriteCoalescer
  private let muteCoalescer: BrightnessWriteCoalescer
  @ObservationIgnored private var issuedGeneration: UInt64 = 0
  @ObservationIgnored private var issuedMuteGeneration: UInt64 = 0
  /// The newest submit on each queue, kept for `drainPendingWrites` to re-issue
  /// when the queue completed a generation without applying it.
  @ObservationIgnored private var lastSubmittedRaw: UInt16?
  @ObservationIgnored private var lastSubmittedMuteWire: UInt16?
  /// Submits made by the drain's own retry, excluded from `submissionMark`.
  @ObservationIgnored private var retriedSubmissions: UInt64 = 0
  @ObservationIgnored private var epochProvider: @Sendable () -> UInt64 = { 0 }
  /// The gate's other half, kept alongside the provider so a settle loop can
  /// wait on it. Default matches the coalescer's accept-everything default.
  @ObservationIgnored private var isEpochCurrent: @Sendable (UInt64) -> Bool = { _ in true }
  /// What the display's own capabilities string says about VCP 0x8D, read
  /// live at every mute decision.
  ///
  /// A provider and not a stored verdict: the capabilities probe is
  /// asynchronous and lands long after this object exists, and a controller is
  /// REUSED for whatever panel next appears on its display ID, so a stored copy
  /// would have to be re-pointed anyway.
  ///
  /// Defaults to `.unknown`, which the capabilities-denial rule resolves to
  /// allowed: a controller nobody has told anything still sends the display's mute command.
  @ObservationIgnored private var muteWireSupport: () -> VCPSupport = { .unknown }
  /// Capabilities verdict for the register this command writes (VCP 0x62 for
  /// volume). `.unknown` allows, so a write-only panel that cannot answer
  /// the capabilities read still restores from its stored value.
  @ObservationIgnored private var valueWireSupport: () -> VCPSupport = { .unknown }
  /// The mute strategy the last restore acted on (volume only), or nil until
  /// this controller has restored anything. Read by
  /// `restoreIfMuteStrategyChanged` to tell a restore that is still correct
  /// from one the display's late answer has superseded.
  @ObservationIgnored private var restoredMuteStrategy: Bool?
  private let store: (any BrightnessStoring)?
  private let storageKey: String?
  /// Validated readback max (nil until a successful `.read` pass); feeds
  /// `CommandTuning.effectiveMaxDDC`. Observable rather than
  /// `@ObservationIgnored`: "the panel said 100" and "we assumed 100
  /// because the read failed" are different facts, and `nil` is the only record
  /// of the second.
  public private(set) var readMax: Int?

  /// What this command's reads have proved.
  ///
  /// Published per COMMAND, not per display, because `AppModel.DisplayState`
  /// holds brightness, volume and contrast as siblings with no owner among
  /// them: the display-level verdict is `DDCReadEvidence.worst` of the three,
  /// folded at whatever reads them.
  ///
  /// Scope: the most recent pass that actually asked the panel something,
  /// folded worst-wins over the FAILED attempts within that pass, so a late
  /// `continue` cannot erase an earlier zeros observation and a pass that
  /// returns early leaves the previous verdict standing.
  ///
  /// Deliberately NOT a fold across passes and retries. DDC reads are flaky, so
  /// the common healthy case is attempt 1 returning nil and attempt 2
  /// answering; folding those publishes "this display does not reply" about a
  /// panel that just replied. A successful attempt supersedes the failures
  /// before it in its pass.
  public private(set) var readEvidence: DDCReadEvidence = .notAttempted

  public init(
    writer: any DDCWriting,
    command: DDCCommand,
    prefs: DisplayPrefs,
    store: (any BrightnessStoring)? = nil,
    storageKey: String? = nil,
    panelIdentity: String? = nil
  ) {
    self.writer = writer
    self.command = command
    self.prefs = prefs
    // Seeded at construction, not left nil: without it the FIRST rebind would
    // always look like an identity change and reset a verdict this controller
    // had just earned. `nil` is honest for callers with no notion of panel
    // identity (tests, and any writer that never rebinds) — nil compares equal
    // to nil, so those controllers simply never reset on rebind.
    self.boundPanelIdentity = panelIdentity
    self.store = store
    self.storageKey = storageKey
    self.coalescer = BrightnessWriteCoalescer()
    self.muteCoalescer = BrightnessWriteCoalescer()
    if let store, let storageKey, let saved = store.savedBrightness(for: storageKey) {
      value = min(max(saved, 0), 1)
    } else {
      // Fork assumed defaults when nothing was ever saved: volume 12.5%
      // ("high volume might rattle the user"), contrast 75%.
      value = command == .volume ? 0.125 : 0.75
    }
    isMuted = command == .volume ? prefs.muted : false
  }

  deinit {
    coalescer.finishSubmissions()
    muteCoalescer.finishSubmissions()
  }

  public func setMuteWireSupport(_ provider: @escaping () -> VCPSupport) {
    muteWireSupport = provider
  }

  public func setValueWireSupport(_ provider: @escaping () -> VCPSupport) {
    valueWireSupport = provider
  }

  /// Whether a mute on this display goes over its own mute command, or
  /// degrades to a volume-register 0 (what every display with no dedicated
  /// mute command already gets).
  ///
  /// Both halves are read live: the pref can be flipped from a settings row or
  /// a `defaults write`, and the verdict changes when the capabilities probe
  /// lands. The degrade is the point of the false case. Suppressing the 0x8D
  /// write and skipping the volume write with it would record a mute no
  /// register carries, on a display still playing at its old level.
  ///
  /// `audioSinkOverride` therefore decides the STRATEGY, not just the slider it
  /// is captioned for: "Always disabled" demotes this display to the
  /// volume-register mute, "Always enabled" keeps the dedicated command on a
  /// display whose description denies it.
  private var usesDedicatedMuteCommand: Bool {
    VolumeSliderPolicy.usesDedicatedMuteCommand(
      prefEnabled: prefs.enableMuteUnmute,
      override: prefs.audioSinkOverride,
      muteSupport: muteWireSupport()
    )
  }

  /// The same capabilities-denial predicate that greys the slider, so the
  /// restore (the one value write with no gesture behind it, hence no UI gate) cannot disagree with it.
  /// Volume only: nothing in the app carries a verdict for the contrast register.
  private var writesValueRegister: Bool {
    guard command == .volume else { return true }
    return VolumeSliderPolicy.isEnabled(
      override: prefs.audioSinkOverride, volumeSupport: valueWireSupport())
  }

  // MARK: - Input funnel

  /// One key step (fork stepVolume/stepContrast). Returns the new published
  /// value — the rail value on a no-op rail press (the HUD still flashes,
  /// fork parity) — or nil when the command is disabled.
  @discardableResult
  public func step(isUp: Bool, isFine: Bool) -> Double? {
    guard isAvailable else { return nil }
    let next = DimmingMath.stepValue(current: value, isUp: isUp, isFine: isFine)
    apply(next)
    return next
  }

  /// Slider entry point — same funnel as `step` (spec §5).
  public func setValue(_ newValue: Double) {
    guard isAvailable else { return }
    apply(min(max(newValue, 0), 1))
  }

  private func apply(_ next: Double) {
    // Mute companion (fork stepVolume + valueChangedOtherDisplay): crossing
    // away from 0 unmutes, landing on 0 mutes. 0x8D traffic only under the
    // dedicated strategy; the logical flag always persists.
    var unmuting = false
    if command == .volume {
      if isMuted, next > 0 {
        setMuted(false)
        unmuting = true
        // On the PREF alone, deliberately: the unmute direction is never
        // gated on the display's verdict, so a mute sent while the probe read
        // `.unknown` still has a way back after the probe says otherwise.
        if prefs.enableMuteUnmute { submitMuteWire(2) }
      } else if !isMuted, next == 0 {
        setMuted(true)
        if usesDedicatedMuteCommand { submitMuteWire(1) }
      }
    }
    let changed = next != value
    value = next
    // `unmuting` keeps the register rewrite alive when the crossing lands
    // exactly on the stored value: in the default strategy
    // the register holds 0 while `value` kept the level — `changed` alone
    // would leave the panel silent behind an unmuted UI.
    guard changed || unmuting else { return }
    persist(next)
    // The dedicated strategy never writes volume 0: silence is 0x8D's job, and
    // digital 0 breaks some panels (fork guard). The skip is licensed by the
    // 0x8D write above having gone out, so it reads the same condition. Where
    // the display denies that register the mute lands here instead, which is
    // also plainly what a drag to zero asked for.
    if !(command == .volume && usesDedicatedMuteCommand && next == 0) {
      submitValue(next)
    }
  }

  /// Mute toggle (fork toggleMute). Fresh presses only: key-repeat must not
  /// oscillate the state.
  @discardableResult
  public func toggleMute(isFresh: Bool = true) -> Bool {
    guard command == .volume, isFresh, isAvailable else { return isMuted }
    if isMuted {
      setMuted(false)
      if value == 0 {
        // Unmute at stored 0: what the panel would pick is unpredictable —
        // restore a single filled chiclet (fork verbatim).
        value = 1.0 / 16.0
        persist(value)
      }
      // Ungated: this is the route back, and the display's own
      // verdict may have arrived after the mute it has to undo.
      if prefs.enableMuteUnmute { submitMuteWire(2) }
      // The unmute pair (wire 2 + value) rides two coalescers with no
      // wire-order guarantee, but both orders CONVERGE: 0x8D=2 never
      // changes the volume register, and a 0x62 write at worst implicitly
      // unmutes. The REPEATED path (restoreToHardware) does not carry the pair
      // at all; see its muted branch.
      submitValue(value)
    } else {
      setMuted(true)
      if usesDedicatedMuteCommand {
        submitMuteWire(1) // volume register untouched — 0x8D owns silence
      } else {
        // Fork default, and the same landing place for a display that denies
        // 0x8D: mute degrades to volume 0. Pre-existing caveat, inherited
        // rather than introduced: `rawValue` honours `minDDCOverride` and
        // `invert`, so on a display with a volume floor set this mute is as
        // audible as the default strategy's has always been.
        submitRaw(rawValue(for: 0))
      }
    }
    return isMuted
  }

  /// Puts the mute belief back after an unmute that could not be confirmed as
  /// applied, touching no register.
  ///
  /// Both halves move together. The persisted flag survives a relaunch; the
  /// live one keeps the mute control honest and the recovery affordance on
  /// screen. Writing only the pref leaves this object believing an unmuted
  /// display, so the next press MUTES a display that never stopped being muted.
  ///
  /// No second write, deliberately. The first could not be confirmed, and
  /// repeating it is another unconfirmed write rather than evidence; over a
  /// register locked by HDR it is also how a memo comes to name a value the
  /// panel never took.
  @discardableResult
  public func reassertUnconfirmedMute() -> Bool {
    guard command == .volume, !isMuted else { return false }
    setMuted(true)
    return true
  }

  // MARK: - Startup/wake restore

  /// Re-writes the saved value (+ mute companion under the dedicated mute
  /// strategy), but only for an ever-touched command (the fork's isTouched
  /// gate): a saved value exists only after this command was written at least
  /// once.
  ///
  /// Only the value writes obey `writesValueRegister`. `submitMuteWire(1)` has
  /// already passed the 0x8D verdict in `usesDedicatedMuteCommand`, and wire 2
  /// is an unmute, which no verdict may cancel.
  public func restoreToHardware() {
    guard isAvailable, let store, let storageKey,
          store.savedBrightness(for: storageKey) != nil else { return }
    if command == .volume { restoredMuteStrategy = usesDedicatedMuteCommand }
    if command == .volume, isMuted {
      // The strategy the mute was taken under, not the pref: a display that
      // denies 0x8D was muted at its volume register, and re-asserting the
      // mute wire instead would restore silence nowhere while skipping the
      // value write on the strength of it.
      if usesDedicatedMuteCommand {
        // The wire-order convergence rule: value and 0x8D ride SEPARATE coalescers, so a
        // submitted pair races to the writer actor — and many panels treat
        // a 0x62 write as an implicit unmute. While muted, restore submits
        // ONLY the mute wire (silence is 0x8D's job, per apply()'s own
        // doctrine); the volume register catches up on unmute. Critical on
        // the wake chain, which would otherwise re-roll the race 10 times.
        submitMuteWire(1)
      } else if writesValueRegister {
        // DIVERGENCE: the fork restores the saved volume here and audibly
        // loses the mute. With the always-persisted flag, silence IS
        // the register state to restore.
        submitRaw(rawValue(for: 0))
      }
      return
    }
    if writesValueRegister { submitValue(value) }
    if command == .volume, prefs.enableMuteUnmute {
      // Unmuted pair (value + wire 2): both cross-coalescer orders converge
      // — 0x8D=2 leaves the register alone, 0x62 at worst implicitly
      // unmutes (same convergence argument as toggleMute's unmute).
      //
      // On the pref alone, like every other unmute: this is the pass that
      // clears a 0x8D mute left over from a session where the verdict was
      // still unknown, so the verdict must not be able to cancel it.
      submitMuteWire(2)
    }
  }

  /// Asserts the PUBLISHED value onto the wire with no store gate, the sibling
  /// of `BrightnessController.reassertHardware` and for the same one caller. A
  /// settings reset republishes this command's assumed default over a wiped
  /// store, and neither other door can send it: `restoreToHardware` returns
  /// early when the store holds no saved value, which after a domain wipe is
  /// every display, and `setValue` returns before the submit because the value
  /// is already published. Without this the slider comes back claiming a number
  /// the panel never took.
  ///
  /// Refuses to drive a MUTED display's volume register. A reset that could not
  /// confirm an unmute carries the mute across the wipe on purpose,
  /// so a value write here would either contradict that or, under the default
  /// strategy where silence IS the register at 0, leave a display meant to be
  /// silent holding a level nobody chose.
  public func reassertHardware() {
    guard isAvailable else { return }
    guard !(command == .volume && isMuted) else { return }
    submitValue(value)
  }

  /// Redoes the restore when the display's answer about 0x8D arrives AFTER the
  /// restore that had to assume one, which at launch it always does.
  ///
  /// The capabilities probe is asynchronous and its verdict is in-memory, so
  /// the launch restore runs with an absent verdict, resolves it to `.unknown`
  /// (no evidence allows) and takes the dedicated strategy. On a display
  /// that denies the register, that restore sent 0x8D=1 into nothing and, on
  /// its own doctrine, skipped the volume write that would have carried the
  /// silence. The same window opens on the first pass after a replug, where the
  /// verdict for the new panel starts absent again.
  ///
  /// It fires only when the strategy the last restore acted on is not the one
  /// now in force, and only while this display is muted, which is the only
  /// restore branch the verdict changes.
  ///
  /// The memo reset is defence in depth, not what makes this work [MEASURED:
  /// removing it keeps the suite green]. It stays because this is a correction
  /// path, and a correction dropped as a duplicate of a value the register never
  /// took is the failure it exists to undo.
  @discardableResult
  public func restoreIfMuteStrategyChanged() -> Bool {
    guard command == .volume, isMuted,
          let assumed = restoredMuteStrategy,
          assumed != usesDedicatedMuteCommand else { return false }
    resetWriteMemo()
    restoreToHardware()
    return true
  }

  /// `.read`: validated DDC readback. `(0, 0)` and `max == 0` are FAILED
  /// reads — the MAG341C answers every read with zeros, and the fork's
  /// unvalidated read clobbers saved values to 0.
  public func refreshFromHardware() async {
    guard prefs.startupAction == .read, isAvailable else { return }
    let tries = prefs.pollingTries
    guard tries > 0 else { return }
    let tuning = prefs.tuning(for: command)
    // Fork parity: reads use only the FIRST remap code.
    let readCode = tuning.remapCodes.first ?? command.code
    // Staleness fence (the I9 doctrine): the read loop can
    // span seconds on a wedged bus — a slider drag or key that lands
    // mid-flight must win over the stale read, INCLUDING in the persisted
    // store. Any submit bumps the generation, so a mismatch means user
    // input superseded this read.
    let issuedAtStart = issuedGeneration
    // Captured HERE, not after the value loop: a toggleMute
    // landing mid-value-loop bumps the mute generation, and a later capture
    // would blind the 0x8D-readback guard to it — the readback could then
    // setMuted(false)+persist over the user's fresh mute.
    let muteIssuedAtStart = issuedMuteGeneration
    // This pass's own evidence, folded from `.notAttempted` rather than from
    // what the last pass concluded (see `readEvidence`). Only the FAILED
    // attempts fold, worst-wins; a success supersedes them outright.
    var passEvidence = DDCReadEvidence.notAttempted
    for _ in 0 ..< tries {
      // Two guards, not one: a silent bus and a panel that answers zeros
      // are different facts. Only the second is the write-only signature, and
      // it is the one the MAG 341C produces on every one of `tries` attempts.
      guard let result = await writer.read(command: readCode) else {
        passEvidence = DDCReadEvidence.worse(passEvidence, .noReply)
        readEvidence = passEvidence
        continue
      }
      guard result.max > 0 else {
        passEvidence = DDCReadEvidence.worse(passEvidence, .allZeros)
        readEvidence = passEvidence
        continue
      }
      // Recorded BEFORE the staleness fence: the panel answered, and that is
      // true whether or not user input superseded the value we were about to
      // adopt. Returning here without recording would hide a good panel behind
      // a race.
      readEvidence = .answered
      guard issuedGeneration == issuedAtStart else { return }
      // The max is real information on every validated read (the loop guard
      // proved `max > 0`); learn it BEFORE the artifact skip below, which
      // concerns `current` only — otherwise the skip path leaves `readMax`
      // nil and later writes scale against the assumed 100.
      readMax = Int(result.max)
      // Muted default-strategy register 0 is the mute ARTIFACT, not
      // information: adopting/persisting it would destroy the
      // unmute restore target.
      if command == .volume, isMuted, result.current == 0 { break }
      let adopted = DimmingMath.ddcToValue(
        result.current,
        minDDC: Double(tuning.minDDCOverride),
        maxDDC: Double(tuning.effectiveMaxDDC(readMax: Int(result.max))),
        curve: tuning.curveMultiplier,
        invert: tuning.invert
      )
      value = adopted
      persist(adopted)
      break
    }
    // The strategy in force, not the pref: 0x8D is where this display's mute
    // lives only if the display takes 0x8D. Asking a register the display
    // denies and adopting its answer would write a mute state nothing ever
    // put there, which is the same phantom the write gate above prevents.
    guard command == .volume, usesDedicatedMuteCommand else { return }
    for _ in 0 ..< tries {
      guard let result = await writer.read(command: VCP.audioMuteScreenBlank), result.max > 0 else { continue }
      // Same fence for the mute readback: in wire mode every mute-state
      // change submits on the mute coalescer, so its generation is the
      // staleness signal here.
      guard issuedMuteGeneration == muteIssuedAtStart else { return }
      setMuted(result.current == 1)
      return
    }
  }

  // MARK: - Plumbing (mirrors BrightnessController)

  public func waitForPendingWrites() async {
    await coalescer.waitUntilCompleted(through: issuedGeneration)
    await muteCoalescer.waitUntilCompleted(through: issuedMuteGeneration)
  }

  /// Both counters in one number: the mute wire and the value register are
  /// separate queues, and a caller asking "did anything get submitted while I
  /// was away" needs an answer that covers both. The drain's own retries are
  /// subtracted back out, or a round that retried could never report a quiet
  /// wire even once it was quiet.
  public func submissionMark() -> UInt64 {
    (issuedGeneration &+ issuedMuteGeneration) &- retriedSubmissions
  }

  public func drainPendingWrites() async -> Bool {
    let value = await drain(
      coalescer,
      issued: { self.issuedGeneration },
      resubmit: {
        guard let raw = self.lastSubmittedRaw else { return false }
        self.submitRaw(raw)
        return true
      }
    )
    let mute = await drain(
      muteCoalescer,
      issued: { self.issuedMuteGeneration },
      resubmit: {
        guard let wire = self.lastSubmittedMuteWire else { return false }
        self.submitMuteWire(wire)
        return true
      }
    )
    return value && mute
  }

  /// One queue's half of `drainPendingWrites`: wait, and if the generation
  /// completed without the target reaching hardware, submit it again (fresh
  /// epoch stamp) and wait once more. The re-submit is the whole point: a
  /// target skipped because it was stamped before a display reconfiguration is
  /// recoverable, and reporting it without trying is a strand nobody sees.
  ///
  /// `issued` is a closure and not a value because the re-submit bumps it.
  /// `resubmit` reports whether it actually submitted: it has nothing to send
  /// once a rebind has dropped the remembered target, and counting a retry that
  /// never happened would walk `submissionMark` BACKWARDS, which the protocol
  /// promises it never does.
  private func drain(
    _ coalescer: BrightnessWriteCoalescer,
    issued: () -> UInt64,
    resubmit: () -> Bool
  ) async -> Bool {
    let first = issued()
    await coalescer.waitUntilCompleted(through: first)
    if await coalescer.appliedThrough() >= first { return true }
    guard resubmit() else { return false }
    retriedSubmissions &+= 1
    let second = issued()
    await coalescer.waitUntilCompleted(through: second)
    return await coalescer.appliedThrough() >= second
  }

  /// Swaps the DDC writer, and drops the read-derived facts about the old panel
  /// only when `panelIdentity` says the panel on the other end CHANGED.
  ///
  /// `AppModel.performRefresh` reuses these controllers for any display whose
  /// `CGDirectDisplayID` reappears, and macOS reassigns display IDs across a
  /// replug, so a different monitor swapped onto the same port inherits this
  /// object and, without a reset, the previous panel's readback max and read
  /// verdict about ITSELF. `BrightnessController.rebind` carries the same reset.
  ///
  /// WHY A PANEL IDENTITY AND NOT THE WRITER. Resetting on every `rebind` was
  /// wrong: `performRefresh` rebinds every KEPT display on every pass, not only
  /// on replug, so a panel that reported a max below 100 was dropped back to the
  /// assumed 100 several times a session. Comparing the writer does not work
  /// either:
  ///
  /// - `DisplayDiscovery.discover()` builds a FRESH `Arm64DDCService` per pass,
  ///   so `===` changes every pass, replug or not.
  /// - Its `IOAVService` is freshly created per pass too and a plain CFTypeRef
  ///   compares by pointer, so there is no stable service handle either.
  /// - `Arm64Service.serviceLocation` IS stable across passes, but it names the
  ///   PORT, so it is unchanged in exactly the scenario this reset exists for.
  ///
  /// `ExternalDisplay.persistenceKey` (the EDID UUID, falling back to
  /// productName/manufacturer/serial) does distinguish them, and `storageKey`
  /// derives from it, so "the panel changed" and "this controller's saved value
  /// belongs to someone else" are one fact. Identical twins can share an EDID
  /// UUID and so are not detected; they also share a saved value and a prefs
  /// domain, which is the larger problem in that scenario.
  ///
  /// Cost of the narrower trigger: the SAME panel rebound through a new route
  /// keeps the old verdict until the next read pass overwrites it.
  ///
  /// `readMax` back to `nil` is the reset that moves bytes: `nil` means "assume
  /// 100", so a panel that reported a lower max is written against 100 until the
  /// next successful read. That is where a freshly discovered display starts,
  /// and scaling against a maximum this panel never reported is worse.
  ///
  /// The 0x8D verdict is NOT reset here because it is not held here.
  /// `muteWireSupport` is a provider, and the refresh pass that calls this
  /// re-points it for every display in the same pass.
  ///
  /// The duplicate memos reset UNCONDITIONALLY: they are not evidence, they
  /// claim a value is already sitting in the register. A rebind means the
  /// register was reached through a service we no longer hold, so re-asserting a
  /// value must not be suppressed as a duplicate.
  public func rebind(writer: any DDCWriting, panelIdentity: String?) {
    self.writer = writer
    if panelIdentity != boundPanelIdentity {
      boundPanelIdentity = panelIdentity
      readMax = nil
      readEvidence = .notAttempted
    }
    coalescer.resetDuplicateState()
    muteCoalescer.resetDuplicateState()
    // Dropped with the memos and for their reason: these name writes issued
    // through a service we no longer hold, so re-issuing one would put a stale
    // value on a fresh wire. `restoredMuteStrategy` is one of them: it names
    // what a past restore did over that service, and the restore pass this
    // rebind's own refresh triggers records it again.
    lastSubmittedRaw = nil
    lastSubmittedMuteWire = nil
    restoredMuteStrategy = nil
  }

  /// Wake-restore prerequisite: without the memo reset, repeat passes
  /// are duplicate-skipped and never hit the wire. Also the HDR exit's
  /// prerequisite, for a sharper version of the same reason: a write ACKed
  /// while the display was in HDR was swallowed, so a memo built through that
  /// window claims values the register never took.
  public func resetWriteMemo() {
    coalescer.resetDuplicateState()
    muteCoalescer.resetDuplicateState()
  }

  /// Whether the wire is open right now: the same gate the coalescer consults
  /// before applying, asked ahead of time so a settle loop can wait for it
  /// instead of sleeping a guessed length of time.
  public var isWireOpen: Bool { isEpochCurrent(epochProvider()) }

  public func setEpochProvider(
    _ provider: @escaping @Sendable () -> UInt64,
    isCurrent: @escaping @Sendable (UInt64) -> Bool
  ) {
    epochProvider = provider
    isEpochCurrent = isCurrent
    coalescer.setEpochGate(isCurrent)
    muteCoalescer.setEpochGate(isCurrent)
  }

  // MARK: - Wire

  private func rawValue(for v: Double) -> UInt16 {
    let tuning = prefs.tuning(for: command)
    return DimmingMath.valueToDDC(
      v,
      minDDC: Double(tuning.minDDCOverride),
      maxDDC: Double(tuning.effectiveMaxDDC(readMax: readMax)),
      curve: tuning.curveMultiplier,
      invert: tuning.invert,
      floorNonZeroToOne: command == .volume
    )
  }

  private func submitValue(_ v: Double) {
    submitRaw(rawValue(for: v))
  }

  private func submitRaw(_ raw: UInt16) {
    let tuning = prefs.tuning(for: command)
    let target = HardwareTarget.ddc(raw: raw)
    issuedGeneration += 1
    lastSubmittedRaw = raw
    coalescer.submit(.init(
      target: target,
      // Rebuilt per submit (not held) so rebind takes effect on the next write.
      applier: DDCCommandApplier(writer: writer, command: command.code, remapCodes: tuning.remapCodes),
      epoch: epochProvider(),
      generation: issuedGeneration
    ))
  }

  private func submitMuteWire(_ wireValue: UInt16) {
    let target = HardwareTarget.ddc(raw: wireValue)
    issuedMuteGeneration += 1
    lastSubmittedMuteWire = wireValue
    muteCoalescer.submit(.init(
      target: target,
      applier: DDCCommandApplier(writer: writer, command: VCP.audioMuteScreenBlank, remapCodes: []),
      epoch: epochProvider(),
      generation: issuedMuteGeneration
    ))
  }

  private func setMuted(_ muted: Bool) {
    isMuted = muted
    prefs.muted = muted
  }

  private func persist(_ v: Double) {
    if let store, let storageKey {
      store.saveBrightness(v, for: storageKey)
    }
  }
}
