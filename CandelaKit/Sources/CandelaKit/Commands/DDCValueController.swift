import CoreGraphics
import Observation

/// Single source of truth for one display's value on one pure-DDC command —
/// volume or contrast — the sibling of `BrightnessController` (D1): no
/// software leg, no native leg, no HDR machinery, no poller. Owns its own
/// write coalescer (and a second one for the VCP 0x8D mute companion): mute
/// wire values 1/2 overlap small volume raws, and a shared duplicate memo
/// would cross-suppress them.
///
/// Under HDR, writes are best-effort with last-written tracking (fork parity;
/// D3): DDC is dead while the display is in HDR mode, so the register catches
/// up on the next write after HDR exits, or via startup/wake restore.
@MainActor @Observable
public final class DDCValueController {
  public nonisolated let command: DDCCommand
  public private(set) var value: Double
  /// Logical mute flag (volume only; constitutively false for contrast).
  /// Persists in BOTH mute strategies — D3 resolves the fork's
  /// stepVolume/toggleMute persistence inconsistency toward always-persist.
  public private(set) var isMuted: Bool
  /// Per-command disable (fork unavailableDDC) AND the display-level
  /// forceSoftware opt-out (fork isSw(), review R5): a display forced to
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
  @ObservationIgnored let displayID: CGDirectDisplayID
  private let coalescer: BrightnessWriteCoalescer
  private let muteCoalescer: BrightnessWriteCoalescer
  @ObservationIgnored private var issuedGeneration: UInt64 = 0
  @ObservationIgnored private var issuedMuteGeneration: UInt64 = 0
  @ObservationIgnored private var epochProvider: @Sendable () -> UInt64 = { 0 }
  private let store: (any BrightnessStoring)?
  private let storageKey: String?
  /// Validated readback max (nil until a successful `.read` pass); feeds
  /// `CommandTuning.effectiveMaxDDC`. `public private(set)` and OBSERVABLE
  /// (B5) — `@ObservationIgnored` is gone deliberately: "the panel said 100"
  /// and "we assumed 100 because the read failed" are different facts and the
  /// pane has to be able to tell them apart. `nil` IS the second fact; nothing
  /// else in this type records it.
  public private(set) var readMax: Int?

  /// What this command's reads have proved (B3).
  ///
  /// Published per COMMAND, not per display, because `AppModel.DisplayState`
  /// holds brightness, volume and contrast as siblings with no owner among
  /// them: the display-level verdict is `DDCReadEvidence.worst` of the three,
  /// folded at whatever reads them.
  ///
  /// Scope: the verdict of the most recent pass that actually asked the panel
  /// something, folded worst-wins over the FAILED attempts within that pass —
  /// so a late `continue` still cannot erase an earlier zeros observation from
  /// the same pass, and a pass that returns early (`startupAction != .read`,
  /// `!isAvailable`, `tries == 0`) leaves the previous verdict standing.
  ///
  /// What it is deliberately NOT is a fold across passes and across retries.
  /// The retry loop exists because DDC reads are flaky, so the common healthy
  /// case is attempt 1 returning nil and attempt 2 answering; folding those
  /// monotonically published "this display does not reply" about a panel that
  /// had just replied, then adopted its value in the same breath. A read that
  /// eventually succeeded is a read that succeeded, so a successful attempt
  /// supersedes the failures that preceded it in its pass. The ordering in
  /// `DDCReadEvidence` is untouched; only the scope of the fold changed.
  public private(set) var readEvidence: DDCReadEvidence = .notAttempted
  /// Test seam, mirroring `BrightnessController._onSubmit`.
  @ObservationIgnored var _onSubmit: ((HardwareTarget) -> Void)?

  public init(
    writer: any DDCWriting,
    command: DDCCommand,
    prefs: DisplayPrefs,
    displayID: CGDirectDisplayID,
    store: (any BrightnessStoring)? = nil,
    storageKey: String? = nil,
    panelIdentity: String? = nil
  ) {
    self.writer = writer
    self.command = command
    self.prefs = prefs
    self.displayID = displayID
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
    // away from 0 unmutes, landing on 0 mutes. 0x8D traffic only when
    // enableMuteUnmute; the logical flag always persists (D3).
    var unmuting = false
    if command == .volume {
      if isMuted, next > 0 {
        setMuted(false)
        unmuting = true
        if prefs.enableMuteUnmute { submitMuteWire(2) }
      } else if !isMuted, next == 0 {
        setMuted(true)
        if prefs.enableMuteUnmute { submitMuteWire(1) }
      }
    }
    let changed = next != value
    value = next
    // `unmuting` keeps the register rewrite alive when the crossing lands
    // exactly on the stored value (concurrency F5): in the default strategy
    // the register holds 0 while `value` kept the level — `changed` alone
    // would leave the panel silent behind an unmuted UI.
    guard changed || unmuting else { return }
    persist(next)
    // enableMuteUnmute mode never writes volume 0 — silence is 0x8D's job,
    // and digital 0 breaks some panels (fork guard).
    if !(command == .volume && prefs.enableMuteUnmute && next == 0) {
      submitValue(next)
    }
  }

  /// Mute toggle (fork toggleMute). Fresh presses only — this is backlog
  /// #12b's `isFresh` consumer; key-repeat must not oscillate the state.
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
      if prefs.enableMuteUnmute { submitMuteWire(2) }
      // One-shot unmute pair (wire 2 + value) rides two coalescers with no
      // wire-order guarantee, but both orders CONVERGE (review R2): 0x8D=2
      // never changes the volume register, and a 0x62 write at worst
      // implicitly unmutes — the end state is identical either way.
      // Documented instead of a composite ordered applier (YAGNI at this
      // risk level). The REPEATED path (restoreToHardware) does not carry
      // the pair at all — see its muted branch.
      submitValue(value)
    } else {
      setMuted(true)
      if prefs.enableMuteUnmute {
        submitMuteWire(1) // volume register untouched — 0x8D owns silence
      } else {
        submitRaw(rawValue(for: 0)) // fork default: mute degrades to volume 0
      }
    }
    return isMuted
  }

  // MARK: - Startup/wake restore (D5)

  /// Re-writes the saved value (+ mute companion when enableMuteUnmute), but
  /// only for an ever-touched command — the fork's isTouched gate: a saved
  /// value exists only after this command was written at least once.
  public func restoreToHardware() {
    guard isAvailable, let store, let storageKey,
          store.savedBrightness(for: storageKey) != nil else { return }
    if command == .volume, isMuted {
      if prefs.enableMuteUnmute {
        // R2 wire-order rule: value and 0x8D ride SEPARATE coalescers, so a
        // submitted pair races to the writer actor — and many panels treat
        // a 0x62 write as an implicit unmute. While muted, restore submits
        // ONLY the mute wire (silence is 0x8D's job, per apply()'s own
        // doctrine); the volume register catches up on unmute. Critical on
        // the wake chain, which would otherwise re-roll the race 10 times.
        submitMuteWire(1)
      } else {
        // DIVERGENCE: the fork restores the saved volume here and audibly
        // loses the mute. With the always-persisted flag (D3), silence IS
        // the register state to restore.
        submitRaw(rawValue(for: 0))
      }
      return
    }
    submitValue(value)
    if command == .volume, prefs.enableMuteUnmute {
      // Unmuted pair (value + wire 2): both cross-coalescer orders converge
      // — 0x8D=2 leaves the register alone, 0x62 at worst implicitly
      // unmutes (same convergence argument as toggleMute's unmute).
      submitMuteWire(2)
    }
  }

  /// D5 `.read`: validated DDC readback. `(0, 0)` and `max == 0` are FAILED
  /// reads — the MAG341C answers every read with zeros, and the fork's
  /// unvalidated read clobbers saved values to 0.
  public func refreshFromHardware() async {
    guard prefs.startupAction == .read, isAvailable else { return }
    let tries = prefs.pollingTries
    guard tries > 0 else { return }
    let tuning = prefs.tuning(for: command)
    // Fork parity: reads use only the FIRST remap code.
    let readCode = tuning.remapCodes.first ?? command.code
    // Staleness fence (the I9 doctrine; concurrency F2): the read loop can
    // span seconds on a wedged bus — a slider drag or key that lands
    // mid-flight must win over the stale read, INCLUDING in the persisted
    // store. Any submit bumps the generation, so a mismatch means user
    // input superseded this read.
    let issuedAtStart = issuedGeneration
    // Captured HERE, not after the value loop (review F2): a toggleMute
    // landing mid-value-loop bumps the mute generation, and a later capture
    // would blind the 0x8D-readback guard to it — the readback could then
    // setMuted(false)+persist over the user's fresh mute.
    let muteIssuedAtStart = issuedMuteGeneration
    // This pass's own evidence, folded from `.notAttempted` rather than from
    // whatever the last pass concluded — see `readEvidence`. Only the FAILED
    // attempts fold together (worst-wins, so a silent retry after a zeros
    // answer still reports the more specific write-only finding); a success
    // supersedes them outright, which is also why it needs no fold.
    var passEvidence = DDCReadEvidence.notAttempted
    for _ in 0 ..< tries {
      // The old single `guard … , result.max > 0 else { continue }` treated a
      // silent bus and a panel that answers zeros as the same non-event (B3).
      // They are different facts: only the second is the write-only signature,
      // and it is the one the MAG 341C produces on every one of `tries`
      // attempts. Same number of reads, same `continue`, same values — the
      // loop's DDC behaviour is untouched; it just stops forgetting.
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
      // information (review F1): adopting/persisting it would destroy the
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
    guard command == .volume, prefs.enableMuteUnmute else { return }
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

  /// Swaps the DDC writer, and — only when `panelIdentity` says the panel on
  /// the other end has CHANGED — drops the read-derived facts that were
  /// evidence about the old one.
  ///
  /// The motivating defect is real: `AppModel.performRefresh` reuses these
  /// controllers for any display whose `CGDirectDisplayID` reappears, and
  /// macOS reassigns display IDs across a replug — so a different physical
  /// monitor swapped onto the same port inherits this object, and without a
  /// reset would inherit the previous panel's readback max and read verdict
  /// about ITSELF. (`BrightnessController.rebind` carries the same reset,
  /// under the same condition.)
  ///
  /// WHY A PANEL IDENTITY AND NOT THE WRITER. The first version of this reset
  /// fired on every `rebind` call, which was wrong because `performRefresh`
  /// rebinds every KEPT display on EVERY pass — every wake, every
  /// reconfiguration — not only on replug. A readable panel that reported a
  /// max below 100 was therefore dropped back to the assumed 100 several times
  /// a session, and the recovering re-read is a no-op unless
  /// `startupAction == .read` and fails outright on a write-only panel. The
  /// obvious repair — compare the writer instead — does not work, and the
  /// reason is in the discovery path rather than here:
  ///
  /// - `DisplayDiscovery.discover()` builds a FRESH `Arm64DDCService` on every
  ///   pass, so object identity (`===`) changes every pass, replug or not.
  /// - The `IOAVService` inside it is freshly created per pass too
  ///   (`IOAVServiceCreateWithService(...).takeRetainedValue()` in
  ///   `Arm64DDC.getIoregServicesForMatching`), and a plain CFTypeRef compares
  ///   by pointer — so the underlying service handle changes every pass as
  ///   well. There is no stable service identity to compare.
  /// - `Arm64Service.serviceLocation` IS stable across passes, but it names
  ///   the PORT, and is therefore unchanged in exactly the scenario this reset
  ///   exists for: a different monitor plugged into the same port.
  ///
  /// What does distinguish the panels is the identity discovery already
  /// computes for them — `ExternalDisplay.persistenceKey`, the EDID UUID with
  /// a productName/manufacturer/serial fallback. It is also the key this
  /// controller's own `storageKey` is derived from, so "the panel changed" and
  /// "this controller's saved value belongs to someone else" are one fact, not
  /// two. Its known limitation is inherited: identical twin monitors can share
  /// an EDID UUID, so swapping one twin for another is not detected. Those two
  /// panels also share a saved value and a prefs domain, so the verdict they
  /// share is the least of that scenario's problems.
  ///
  /// COST OF THE NARROWER TRIGGER: a rebind of the SAME panel through a new
  /// route (different port, or a newly interposed dock that eats DDC) keeps
  /// the old verdict until the next read pass overwrites it. That is the right
  /// trade — the verdict is about a panel, the next pass that asks supersedes
  /// it, and the alternative is the regression above, which fires on every
  /// wake.
  ///
  /// `readMax` back to `nil` is the load-bearing reset and the only part of
  /// this that moves bytes: `nil` means "assume 100", so a panel that had
  /// reported a max BELOW 100 is, from an identity change until the next
  /// successful read, written against 100 instead. That is the same state a
  /// freshly discovered display starts in, and scaling writes against a
  /// maximum the panel on the other end never reported is the worse of the
  /// two. Stated here rather than buried, and pinned by
  /// `arebindToADifferentPanelReturnsTheReadbackMaxToAssumed` /
  /// `arebindToTheSamePanelKeepsWhatThatPanelReported`.
  ///
  /// The duplicate memos reset UNCONDITIONALLY, and the asymmetry is
  /// deliberate: they are not evidence about anything, they are a claim that
  /// a particular value is already sitting in the register. A rebind means the
  /// register was reached through a service we no longer hold, so re-asserting
  /// a value must not be suppressed as a duplicate (review I10) — the same
  /// argument whether or not the panel changed.
  public func rebind(writer: any DDCWriting, panelIdentity: String?) {
    self.writer = writer
    if panelIdentity != boundPanelIdentity {
      boundPanelIdentity = panelIdentity
      readMax = nil
      readEvidence = .notAttempted
    }
    coalescer.resetDuplicateState()
    muteCoalescer.resetDuplicateState()
  }

  /// Wake-restore prerequisite (D5): without the memo reset, repeat passes
  /// are duplicate-skipped and never hit the wire.
  public func resetWriteMemo() {
    coalescer.resetDuplicateState()
    muteCoalescer.resetDuplicateState()
  }

  public func setEpochProvider(
    _ provider: @escaping @Sendable () -> UInt64,
    isCurrent: @escaping @Sendable (UInt64) -> Bool
  ) {
    epochProvider = provider
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
    _onSubmit?(target)
    issuedGeneration += 1
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
    _onSubmit?(target)
    issuedMuteGeneration += 1
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
