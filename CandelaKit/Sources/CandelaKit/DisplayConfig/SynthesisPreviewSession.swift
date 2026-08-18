import CoreGraphics
import Foundation

/// The engage and disengage seam a preview drives, plus the one question it has
/// to ask about what the engine currently holds. Narrow enough that a test can
/// stand in for the whole hardware sequence.
///
/// `async` requirements witnessed by `ModeSynthesisEngine`'s synchronous
/// actor-isolated methods. That is the point: the engine's engage and disengage
/// BLOCK for the real hardware path (create polls the online list, destroy polls
/// for departure), and reaching them through this seam suspends the caller
/// rather than blocking it.
public protocol SynthesisDriving: Sendable {
  func engage(
    _ size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) async -> Result<SynthesisPairing, SynthesisFailure>

  func disengage(fromPhysical displayID: CGDirectDisplayID) async -> Result<Void, SynthesisFailure>

  /// What the engine holds for a physical display right now, or nil when it
  /// holds nothing. The pairing table is the authority on synthesis topology
  /// (SS1), so this is how a preview checks that what it is about to keep is
  /// still a thing the engine knows about.
  func pairing(forPhysical displayID: CGDirectDisplayID) async -> SynthesisPairing?
}

extension ModeSynthesisEngine: SynthesisDriving {}

/// The engaged-but-unresolved synthesis: what a UI renders, and what an answer
/// about that UI carries back.
///
/// The same intent-value discipline as `PreviewedMode` and
/// `PreviewedMirrorTopology`: passing this value back into `confirm`/`revert`
/// means an answer can only ever resolve the preview it was given for, so queue
/// ordering becomes an optimisation rather than the thing preventing a wrong
/// commit.
///
/// It carries the WHOLE pairing rather than the display and the size, and
/// matching compares the whole pairing. A re-engage on the same display at the
/// same size is a different virtual display in a different slot, so an answer
/// naming the old one names something that no longer exists, and `.stale` is the
/// truthful reply.
public struct PreviewedSynthesis: Sendable, Equatable {
  public let pairing: SynthesisPairing

  public var physicalDisplayID: CGDirectDisplayID { pairing.physicalDisplayID }
  public var size: SyntheticSize { pairing.size }

  public init(pairing: SynthesisPairing) {
    self.pairing = pairing
  }
}

/// Why a preview did not start.
///
/// Two-layered rather than `SynthesisFailure` alone, because "the session is
/// already driving the hardware" is not a step of the engine's sequence and
/// there is no case in that enum that would be true of it. Reporting it as one
/// of the engine's failures would name a step that was never reached.
public enum SynthesisPreviewRefusal: Error, Sendable, Equatable {
  /// A hardware sequence for another request is already running in this session,
  /// and this request touched nothing. Re-issue it: the sequence in flight is a
  /// bounded operation, not a lock that can be held indefinitely.
  case busy
  /// The engine's sequence failed. Every case names the step it stopped at.
  case engine(SynthesisFailure)
}

/// How a synthesis preview ended.
///
/// `PreviewOutcome`'s vocabulary, with the two changes the domain forces, and
/// deliberately not that type:
/// - `.failed` carries a `SynthesisFailure`. The loudest thing that can go wrong
///   here is `.unwindIncomplete`, which has no CGError to name, and squeezing it
///   into a fabricated `DisplayConfigError` code would disguise exactly the
///   failure a person most needs told about.
/// - `.committed` carries the pairing, because keeping a synthesized size is the
///   moment the coordinator has something to persist (SS11's ordering hangs off
///   it). The mode and mirror sessions commit by re-applying and have nothing to
///   hand back.
public enum SynthesisPreviewOutcome: Sendable, Equatable {
  case committed(SynthesisPairing)
  case reverted
  case failed(SynthesisFailure)
  /// The call resolved nothing: it named a preview that is no longer the
  /// outstanding one, or it arrived while the session was already driving the
  /// hardware. The outstanding preview, if any, is untouched.
  case stale
}

/// Preview → confirm → keep for a synthesized size, with a countdown that
/// **defaults to disengaging** (SS10).
///
/// The same argument as `ModePreviewSession`: a size can leave a display
/// unreadable, and at that point the user cannot click "Keep", so the safe
/// outcome must be the one that happens when nobody does anything. It is a
/// SIBLING of that type, and the differences are worth naming because they are
/// what the synthesis sequence is:
///
/// - **There is no captured fallback, and this type is not weaker for it.** A
///   mode preview must read the previous mode before it applies, or the
///   countdown expires into a no-op. Here the undo is `disengage`: break the
///   mirror, destroy the virtual display, and the panel is back on its own
///   desktop. Nothing needs capturing because nothing was overwritten.
/// - **Confirming applies nothing, but it is not free of failure.** It asks the
///   engine whether the previewed pairing is still the one it holds, because an
///   engage that failed part way can have torn the previewed set down already.
/// - **Every hardware step is `await`ed**, which the mode and mirror sessions
///   have no equivalent of, and that is the whole of the concurrency argument
///   below.
///
/// **Single-flight, and every entrant that finds the session busy resolves
/// nothing.** This is the first preview session whose resolutions suspend, so
/// its state can be observed and mutated by another task in the middle of one.
/// Two states that cost real damage, both closed by the gate:
/// - An expiry suspended in `disengage` while a `confirm` lands `.committed`,
///   then resumes and overwrites it with `.reverted`: a choice destroyed after
///   being reported as kept.
/// - A `begin` suspended mid-sequence while another entrant's continuation
///   clears the record it is about to write, leaving a synthesis engaged with no
///   record, no countdown and nothing that will ever take it down.
///
/// So: state is mutated either with no suspension in between, or while the gate
/// is held; and every public entry point checks the gate before it touches the
/// driver or mutates anything. No path re-checks its own captured state after a
/// suspension,
/// because under this rule nothing can have changed it, and a guard that cannot
/// fire is a claim no test can back.
///
/// One preview at a time, enforced HERE the way `ModePreviewSession` enforces
/// it: a `begin` on a different display disengages the outstanding one first and
/// REFUSES if that disengage fails. This session cannot see any other session,
/// so single-preview across mode, mirror and synthesis is the coordinator's
/// wiring, not a claim this type can make.
///
/// A preview stays outstanding until a resolution actually succeeds. A disengage
/// that failed left a virtual display standing, so the record of what to take
/// down is still the truth and `revert()` can be re-attempted. The one exception
/// is a DEPARTED display, which has no retry path left; see `revertOnDeparture`.
public actor SynthesisPreviewSession {
  private let driver: any SynthesisDriving
  private let countdownSeconds: Int

  private var outstanding: PreviewedSynthesis?
  private var countdown = PreviewCountdown()
  private var lastOutcome: SynthesisPreviewOutcome?

  /// The single-flight gate. True from before the first `await` on the driver to
  /// after the last state mutation that depends on it.
  private var isResolving = false

  /// Thirty seconds, the same as the mode and mirror sessions. All three are the
  /// same kind of decision, a reconfiguration that may itself have made the
  /// answer hard to read, so a different timer on each would be arbitrary.
  public init(driver: any SynthesisDriving, countdownSeconds: Int = 30) {
    self.driver = driver
    self.countdownSeconds = countdownSeconds
  }

  public var secondsRemaining: Int { countdown.remaining }

  /// True while a synthesis is engaged and unresolved, including after a
  /// disengage that failed. `revert()` is worth calling exactly while this holds.
  public var hasOutstandingPreview: Bool { outstanding != nil }

  /// What is engaged and unresolved, if anything. The authority a UI rebuilds
  /// its own state from.
  public var previewedSynthesis: PreviewedSynthesis? { outstanding }

  /// Whether the countdown can still expire into a disengage. Reported rather
  /// than inferred: a failed expiry disarms, and a caller that guesses wrong
  /// either shows a countdown that will never fire or hides one that will.
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
      // A live preview on a DIFFERENT display is ended first: leaving it engaged
      // would strand a panel on a size nobody approved, with its countdown
      // replaced by this display's. If that disengage fails, refuse, rather than
      // build a second synthesis set on top of one that would not come down.
      if case let .failed(failure) = await revertOutstanding() {
        return .failure(.engine(failure))
      }
    }
    // Switching stops on the SAME display does not disengage here. The engine
    // tears an existing pairing down itself as the first step of its engage, and
    // a second teardown from this side would destroy a virtual display that is
    // already gone and fail the sequence it was meant to protect.

    switch await driver.engage(size, onPhysical: displayID, identityKey: identityKey) {
    case let .success(pairing):
      let previewed = PreviewedSynthesis(pairing: pairing)
      outstanding = previewed
      // Cleared HERE, not on entry: a begin() that fails establishes nothing, so
      // the last thing that actually happened is still the last outcome. Wiping
      // it on the way in would make a later confirm() report a reversion that
      // never happened, after a commit that did.
      lastOutcome = nil
      countdown.arm(seconds: countdownSeconds)
      return .success(previewed)
    case let .failure(failure):
      // A same-display re-engage that failed leaves the ORIGINAL preview
      // outstanding and its countdown running. Whether the engine got as far as
      // tearing the old pairing down is not knowable from the failure alone,
      // which is why `confirm` asks, and why the expiry's disengage treats
      // `.notEngaged` as already down.
      return .failure(.engine(failure))
    }
  }

  /// Keeps the synthesized size the caller was looking at, and hands back the
  /// pairing to persist.
  ///
  /// `answered` is the `PreviewedSynthesis` that was RENDERED. If the outstanding
  /// preview has moved on since, the answer does not apply to it, and persisting
  /// anyway would store a size the user never saw and reapply it at every launch.
  ///
  /// **Nothing is applied, and it can still refuse.** The engage landed at
  /// session scope with SS10's checks passed, so keeping it is a decision rather
  /// than a second apply. But an engage that failed part way can have torn the
  /// previewed pairing down on its way out, and the session cannot tell from the
  /// failure alone, so this asks the engine what it holds now and refuses as
  /// `.stale` when that is no longer the previewed pairing.
  ///
  /// What it does NOT do is re-verify the achieved state on the glass. The
  /// pairing table says what the engine believes it engaged, and a pairing the
  /// engine retained after an incomplete unwind is indistinguishable here from a
  /// healthy one. That failure was already surfaced to the caller by whichever
  /// call produced it.
  public func confirm(_ answered: PreviewedSynthesis) async -> SynthesisPreviewOutcome {
    guard !isResolving else { return .stale }
    guard let outstanding else {
      // Nothing is engaged: repeat the answer already given rather than
      // inventing a reversion that never happened. Never begun at all is
      // reported as reverted, since nothing is being kept.
      return lastOutcome ?? .reverted
    }
    guard answered == outstanding else { return .stale }

    isResolving = true
    defer { isResolving = false }

    guard await driver.pairing(forPhysical: outstanding.physicalDisplayID) == outstanding.pairing
    else {
      // The engine no longer holds what was previewed, so there is nothing left
      // to keep and nothing left to take down. The record goes with it, or the
      // UI would count down towards a disengage for a size that is not on the
      // glass. `.stale` rather than `.reverted`: this call restored nothing, and
      // reporting a reversion it did not perform is the false-report class the
      // whole preview shape exists to close.
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

  /// Safe to call repeatedly while `hasOutstandingPreview` names the same
  /// preview. A disengage that reported `.unwindIncomplete` left something
  /// standing, so trying again is the whole recovery path: the error UI hangs
  /// off this, and it passes back the same value it is showing.
  public func revert(_ answered: PreviewedSynthesis) async -> SynthesisPreviewOutcome {
    guard !isResolving else { return .stale }
    guard let outstanding else { return lastOutcome ?? .reverted }
    guard answered == outstanding else { return .stale }

    isResolving = true
    defer { isResolving = false }
    return await revertOutstanding()
  }

  /// Call once per second. Returns nil while the countdown runs, and the outcome
  /// when it expires.
  ///
  /// A tick that arrives while the session is already resolving spends nothing
  /// and does nothing: the clock must not be burnt down by ticks that land
  /// inside a sequence which is itself about to decide the preview's fate.
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
  /// Deliberately NOT `ModePreviewSession.discard`, which drops the record
  /// without applying anything, and deliberately not named the same. Dropping is
  /// right for a mode: the departed display keeps nothing, because its mode was
  /// app-scoped and is renegotiated when it returns. A synthesis pairing is a
  /// virtual display that outlives the panel's departure, holding a slot the
  /// family only has two of, so dropping the record here would strand a display
  /// nothing can reach and lose a slot until the app restarts.
  ///
  /// The engine handles the departed physical without a special case: its unwind
  /// stages the mirror break only when the live topology still shows the set, so
  /// a departed panel skips straight to destroying the virtual display.
  ///
  /// **A disengage that fails is reported once and the record is DROPPED**, which
  /// is the one place this type gives up its retry. It shares
  /// `ModePreviewSession.discard`'s reasoning: the panel is gone, so no tick, no
  /// person and no error UI is coming to retry it, and a preview kept
  /// outstanding for a departed display would refuse every future `begin` on
  /// every other display until the app restarts. Nothing is lost by dropping it,
  /// because the ENGINE retains the stranded pairing in its own table and stays
  /// the authority on it, so a later disengage or reset still finds the slot.
  @discardableResult
  public func revertOnDeparture(displayID: CGDirectDisplayID) async -> SynthesisPreviewOutcome? {
    guard let outstanding, outstanding.physicalDisplayID == displayID else { return nil }
    guard !isResolving else { return .stale }

    isResolving = true
    defer { isResolving = false }
    return await revertOutstanding(droppingOnFailure: true)
  }

  // MARK: - Private

  /// The expiry, the departure and the cross-display hand-off disengage without
  /// an intent check on purpose: they are the SESSION's own decisions about what
  /// it is holding, not a person's answer to a panel. Only answers can be stale.
  ///
  /// Called only with the gate held.
  private func revertOutstanding(droppingOnFailure: Bool = false) async -> SynthesisPreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }

    switch await driver.disengage(fromPhysical: outstanding.physicalDisplayID) {
    case .success:
      break
    case .failure(.notEngaged):
      // The engine holds no pairing for this display, so nothing is synthesized,
      // which is the state reverting exists to reach. Reporting it as a failure
      // would leave a preview outstanding that no retry could ever resolve and a
      // UI showing an error about a set that is not there. It happens on the one
      // real path: a same-display re-engage that tore the old pairing down and
      // then failed at a later step.
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
