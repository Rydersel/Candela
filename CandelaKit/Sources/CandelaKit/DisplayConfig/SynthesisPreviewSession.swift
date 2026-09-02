import CoreGraphics
import Foundation

/// The engage and disengage seam a preview drives, plus the one question it has
/// to ask about what the engine holds. Narrow enough that a test can stand in
/// for the whole hardware sequence.
///
/// `async` requirements witnessed by `ModeSynthesisEngine`'s synchronous
/// actor-isolated methods: the engine's engage and disengage BLOCK on the real
/// hardware path, so reaching them through this seam suspends the caller rather
/// than blocking it.
public protocol SynthesisDriving: Sendable {
  func engage(
    _ size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) async -> Result<SynthesisPairing, SynthesisFailure>

  func disengage(fromPhysical displayID: CGDirectDisplayID) async -> Result<Void, SynthesisFailure>

  /// What the engine holds for a physical display right now. The pairing table
  /// is the authority on synthesis topology, so this is how a preview
  /// checks that what it is about to keep still exists.
  func pairing(forPhysical displayID: CGDirectDisplayID) async -> SynthesisPairing?
}

extension ModeSynthesisEngine: SynthesisDriving {}

/// The engaged-but-unresolved synthesis a UI renders, and the value an answer
/// carries back so it can only ever resolve the preview it was given for.
///
/// It carries the WHOLE pairing, and matching compares the whole pairing. A
/// re-engage on the same display at the same size is a different virtual display
/// in a different slot, so an answer naming the old one names something that no
/// longer exists, and `.stale` is the truthful reply.
public struct PreviewedSynthesis: Sendable, Equatable {
  public let pairing: SynthesisPairing

  public var physicalDisplayID: CGDirectDisplayID { pairing.physicalDisplayID }
  public var size: SyntheticSize { pairing.size }

  public init(pairing: SynthesisPairing) {
    self.pairing = pairing
  }
}

/// Why a preview did not start. Two-layered rather than `SynthesisFailure`
/// alone: "the session is already driving the hardware" is not a step of the
/// engine's sequence, and reporting it as one would name a step never reached.
public enum SynthesisPreviewRefusal: Error, Sendable, Equatable {
  /// A hardware sequence for another request is already running and this one
  /// touched nothing. Re-issue it: the sequence in flight is bounded, not a
  /// lock that can be held indefinitely.
  case busy
  /// The engine's sequence failed. Every case names the step it stopped at.
  case engine(SynthesisFailure)
}

/// How a synthesis preview ended: `PreviewOutcome`'s vocabulary with the changes
/// the domain forces, and deliberately not that type.
/// - `.failed` carries a `SynthesisFailure`. `.unwindIncomplete` has no CGError
///   to name, and a fabricated `DisplayConfigError` code would disguise the
///   failure a person most needs told about.
/// - `.committed` carries the pairing, because keeping a synthesized size is the
///   moment the coordinator has something to persist.
/// - `.busy` exists at all, which no other preview session needs.
///
/// The two "nothing happened" answers stay separate: `.stale` is final and
/// `.busy` is worth repeating.
public enum SynthesisPreviewOutcome: Sendable, Equatable {
  /// The synthesis is kept. The pairing is the coordinator's to persist.
  case committed(SynthesisPairing)
  /// The synthesis was taken down and the panel is back on its own desktop.
  case reverted
  /// The teardown did not finish. `.unwindIncomplete` means a virtual display, a
  /// mirror set, or both are still standing.
  case failed(SynthesisFailure)
  /// The call resolved nothing and repeating it changes nothing: it named a
  /// preview that is no longer the outstanding one, or the engine no longer
  /// holds the pairing it named.
  case stale
  /// The session was already driving a hardware sequence, so the call touched
  /// nothing. The one answer here that means **try again**. Split out of
  /// `.stale` because a caller that cannot tell "never retry" from "retry" gets
  /// one of them wrong.
  case busy
}

/// Preview, confirm, keep for a synthesized size, with a countdown that
/// **defaults to disengaging**.
///
/// The same argument as `ModePreviewSession`: a size can leave a display
/// unreadable, and then nobody can click "Keep", so the safe outcome is the one
/// that happens when nobody answers. Three differences from that type:
///
/// - **No captured fallback is needed.** The undo is `disengage`: break the
///   mirror, destroy the virtual display, and the panel is back on its own
///   desktop. Nothing was overwritten, so nothing needs capturing.
/// - **Confirming applies nothing and can still fail.** It asks the engine
///   whether the previewed pairing is still the one it holds, because an engage
///   that failed part way can have torn the previewed set down already.
/// - **Every hardware step is `await`ed**, which is what forces the gate below.
///
/// **Single-flight: an entrant that finds the session busy resolves nothing.**
/// Resolutions suspend here, so another task can observe and mutate state in the
/// middle of one. Two states that cost real damage:
/// - An expiry suspended in `disengage` while a `confirm` lands `.committed`,
///   then resumes and overwrites it with `.reverted`: a choice destroyed after
///   being reported as kept.
/// - A `begin` suspended mid-sequence while another entrant clears the record it
///   is about to write, leaving a synthesis engaged with no record, no countdown
///   and nothing that will ever take it down.
///
/// So state is mutated with no suspension in between, or while the gate is held,
/// and every public entry point checks the gate before it touches the driver,
/// spends the clock, or mutates anything. A gated entrant says so: `.busy` from
/// an answer, `nil` from a tick, `.failure(.busy)` from a begin. No path
/// re-checks its own captured state after a suspension, because under this rule
/// nothing can have changed it.
///
/// One preview at a time, enforced HERE: a `begin` on a different display
/// disengages the outstanding one first and REFUSES if that fails. This session
/// cannot see any other, so single-preview across mode, mirror and synthesis is
/// the coordinator's wiring.
///
/// A preview stays outstanding until a resolution succeeds: a failed disengage
/// left a virtual display standing, so `revert()` can be re-attempted. The
/// exception is a DEPARTED display, which has no retry path left; see
/// `revertOnDeparture`.
public actor SynthesisPreviewSession {
  private let driver: any SynthesisDriving
  private let countdownSeconds: Int

  private var outstanding: PreviewedSynthesis?
  private var countdown = PreviewCountdown()
  private var lastOutcome: SynthesisPreviewOutcome?

  /// The single-flight gate. True from before the first `await` on the driver to
  /// after the last state mutation that depends on it.
  private var isResolving = false

  /// Thirty seconds, the same as the mode and mirror sessions: all three are a
  /// reconfiguration that may itself have made the answer hard to read.
  public init(driver: any SynthesisDriving, countdownSeconds: Int = 30) {
    self.driver = driver
    self.countdownSeconds = countdownSeconds
  }

  public var secondsRemaining: Int { countdown.remaining }

  /// True while a synthesis is engaged and unresolved, including after a
  /// disengage that failed. `revert()` is worth calling exactly while this holds.
  public var hasOutstandingPreview: Bool { outstanding != nil }

  /// What is engaged and unresolved. A UI rebuilds its state from this.
  public var previewedSynthesis: PreviewedSynthesis? { outstanding }

  /// Reported rather than inferred: a failed expiry disarms the countdown, and
  /// a caller that guesses wrong shows one that will never fire.
  public var isCountingDown: Bool { countdown.isArmed && outstanding != nil }

  /// Engages `size` and arms the countdown, disengaging again if nobody answers.
  ///
  /// Suspends for as long as the engine's sequence takes; see `SynthesisDriving`.
  public func begin(
    size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) async -> Result<PreviewedSynthesis, SynthesisPreviewRefusal> {
    guard !isResolving else { return .failure(.busy) }
    isResolving = true
    defer { isResolving = false }

    if let outstanding, outstanding.physicalDisplayID != displayID {
      // End a live preview on another display first, or a panel is stranded on
      // a size nobody approved with its countdown replaced by this one's. Refuse
      // if that fails rather than stack a second set on one that will not come
      // down.
      if case let .failed(failure) = await revertOutstanding() {
        return .failure(.engine(failure))
      }
    }
    // Switching sizes on the SAME display does not disengage here: the engine
    // tears an existing pairing down as the first step of its engage, and a
    // second teardown would destroy a virtual display that is already gone.

    switch await driver.engage(size, onPhysical: displayID, identityKey: identityKey) {
    case let .success(pairing):
      let previewed = PreviewedSynthesis(pairing: pairing)
      outstanding = previewed
      // Cleared here, not on entry: a begin() that fails establishes nothing, so
      // the last thing that really happened stays the last outcome.
      lastOutcome = nil
      countdown.arm(seconds: countdownSeconds)
      return .success(previewed)
    case let .failure(failure):
      // A same-display re-engage that failed leaves the ORIGINAL preview
      // outstanding with its countdown running. Whether the engine got as far as
      // tearing the old pairing down is not knowable from the failure, which is
      // why `confirm` asks and the expiry treats `.notEngaged` as already down.
      return .failure(.engine(failure))
    }
  }

  /// Keeps the synthesized size the caller was looking at, and hands back the
  /// pairing to persist.
  ///
  /// `answered` is the `PreviewedSynthesis` that was rendered. If the outstanding
  /// preview moved on since, persisting anyway would store a size the user never
  /// saw and reapply it at every launch.
  ///
  /// **Nothing is applied, and it can still refuse.** An engage that failed part
  /// way can have torn the previewed pairing down on its way out, and the failure
  /// alone does not say, so this asks the engine what it holds now and answers
  /// `.stale` when that is no longer the previewed pairing.
  ///
  /// It does NOT re-verify the achieved state on the glass: a pairing the engine
  /// retained after an incomplete unwind is indistinguishable here from a healthy
  /// one, and that failure was already surfaced by the call that produced it.
  public func confirm(_ answered: PreviewedSynthesis) async -> SynthesisPreviewOutcome {
    guard !isResolving else { return .busy }
    guard let outstanding else {
      // Nothing engaged: repeat the last outcome rather than invent a
      // reversion. Never begun reports reverted, since nothing is kept.
      return lastOutcome ?? .reverted
    }
    guard answered == outstanding else { return .stale }

    isResolving = true
    defer { isResolving = false }

    guard await driver.pairing(forPhysical: outstanding.physicalDisplayID) == outstanding.pairing
    else {
      // The engine no longer holds what was previewed, so there is nothing to
      // keep and nothing to take down. The record goes too, or the UI counts
      // down towards a disengage for a size that is not on the glass. `.stale`
      // rather than `.reverted`, because this call restored nothing and
      // reporting a reversion it did not perform is a false report.
      self.outstanding = nil
      countdown.disarm()
      lastOutcome = .stale
      return .stale
    }

    self.outstanding = nil
    countdown.disarm()
    let outcome = SynthesisPreviewOutcome.committed(outstanding.pairing)
    lastOutcome = outcome
    return outcome
  }

  /// Safe to call repeatedly for the same preview. A disengage that reported
  /// `.unwindIncomplete` left something standing, so retrying is the recovery
  /// path the error UI drives.
  public func revert(_ answered: PreviewedSynthesis) async -> SynthesisPreviewOutcome {
    guard !isResolving else { return .busy }
    guard let outstanding else { return lastOutcome ?? .reverted }
    guard answered == outstanding else { return .stale }

    isResolving = true
    defer { isResolving = false }
    return await revertOutstanding()
  }

  /// Call once per second. Returns nil while the countdown runs, and the outcome
  /// when it expires.
  ///
  /// A tick arriving while the session is already resolving spends nothing: the
  /// clock must not burn down inside a sequence that is itself about to decide
  /// the preview's fate.
  ///
  /// **The gate is checked BEFORE the clock is spent.** `PreviewCountdown` fires
  /// once, so a tick that spent the clock and was then refused would disarm a
  /// countdown whose expiry never ran, leaving a preview outstanding and unable
  /// to expire again.
  public func tick() async -> SynthesisPreviewOutcome? {
    guard !isResolving else { return nil }
    guard outstanding != nil, countdown.tick() else { return nil }

    isResolving = true
    defer { isResolving = false }
    return await revertOutstanding()
  }

  /// The physical display has departed. **Disengages**, and returns nil when
  /// `displayID` is not the previewed display.
  ///
  /// NOT `ModePreviewSession.discard`, which drops the record without applying
  /// anything. Dropping is right for a mode, whose app-scoped mode is
  /// renegotiated when the display returns. A synthesis pairing is a virtual
  /// display that outlives the panel's departure and holds one of the family's
  /// two slots, so dropping the record would strand a display nothing can reach.
  ///
  /// The engine needs no special case: its unwind stages the mirror break only
  /// when the live topology still shows the set, so a departed panel skips
  /// straight to destroying the virtual display.
  ///
  /// **A disengage that fails is reported once and the record is DROPPED**, the
  /// one place this type gives up its retry. No tick, no person and no error UI
  /// is coming for a departed panel, and a preview left outstanding would refuse
  /// every future `begin` on every other display until the app restarts. The
  /// engine keeps the stranded pairing in its own table, so a later disengage or
  /// reset still finds the slot.
  @discardableResult
  public func revertOnDeparture(displayID: CGDirectDisplayID) async -> SynthesisPreviewOutcome? {
    guard let outstanding, outstanding.physicalDisplayID == displayID else { return nil }
    guard !isResolving else { return .busy }

    isResolving = true
    defer { isResolving = false }
    return await revertOutstanding(droppingOnFailure: true)
  }

  // MARK: - Private

  /// The expiry, the departure and the cross-display hand-off skip the intent
  /// check: they are the session's own decisions, not a person's answer. Only
  /// answers go stale. Called only with the gate held.
  private func revertOutstanding(droppingOnFailure: Bool = false) async -> SynthesisPreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }

    switch await driver.disengage(fromPhysical: outstanding.physicalDisplayID) {
    case .success:
      break
    case .failure(.notEngaged):
      // No pairing means nothing is synthesized, which is the state reverting
      // exists to reach. Calling it a failure would leave a preview no retry
      // could resolve. One real path reaches it: a same-display re-engage that
      // tore the old pairing down and then failed at a later step.
      break
    case let .failure(failure):
      // Surfaced, never swallowed: `.unwindIncomplete` means a virtual display, a
      // mirror set, or both are still standing.
      lastOutcome = .failed(failure)
      if droppingOnFailure {
        self.outstanding = nil
        countdown.disarm()
      }
      return .failed(failure)
    }

    self.outstanding = nil
    countdown.disarm()
    lastOutcome = .reverted
    return .reverted
  }
}
