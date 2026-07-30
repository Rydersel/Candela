import CoreGraphics
import Observation
import os

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
  /// `CommandTuning.effectiveMaxDDC`.
  @ObservationIgnored private var readMax: Int?
  /// Test seam, mirroring `BrightnessController._onSubmit`.
  @ObservationIgnored var _onSubmit: ((HardwareTarget) -> Void)?

  public init(
    writer: any DDCWriting,
    command: DDCCommand,
    prefs: DisplayPrefs,
    displayID: CGDirectDisplayID,
    store: (any BrightnessStoring)? = nil,
    storageKey: String? = nil
  ) {
    self.writer = writer
    self.command = command
    self.prefs = prefs
    self.displayID = displayID
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
    for _ in 0 ..< tries {
      guard let result = await writer.read(command: readCode), result.max > 0 else { continue }
      guard issuedGeneration == issuedAtStart else { return }
      readMax = Int(result.max)
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
    let muteIssuedAtStart = issuedMuteGeneration
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

  public func rebind(writer: any DDCWriting) {
    self.writer = writer
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
