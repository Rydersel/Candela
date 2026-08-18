import CoreGraphics
import Foundation

/// The engage and disengage seam a preview drives, narrow enough that a test can
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
  /// The answer named a preview that is no longer the outstanding one, so it
  /// resolved nothing and the outstanding preview is untouched.
  case stale
}

/// Preview → confirm → keep for a synthesized size, with a countdown that
/// **defaults to disengaging** (SS10).
///
/// The same argument as `ModePreviewSession`: a size can leave a display
/// unreadable, and at that point the user cannot click "Keep", so the safe
/// outcome must be the one that happens when nobody does anything. It is a
/// SIBLING of that type, and the two differences are worth naming because they
/// are what the synthesis sequence is:
///
/// - **There is no captured fallback, and this type is not weaker for it.** A
///   mode preview must read the previous mode before it applies, or the
///   countdown expires into a no-op. Here the undo is `disengage`: break the
///   mirror, destroy the virtual display, and the panel is back on its own
///   desktop. Nothing needs capturing because nothing was overwritten.
/// - **Confirming applies nothing.** The engage already landed at session scope
///   with its achieved-state checks passed (SS10), so keeping it is a decision,
///   not a second apply, and cannot fail. What the caller gets back is the
///   pairing to persist.
///
/// One preview at a time, enforced HERE the way `ModePreviewSession` enforces
/// it: a `begin` on a different display disengages the outstanding one first and
/// REFUSES if that disengage fails. This session cannot see any other session,
/// so single-preview across mode, mirror and synthesis is the coordinator's
/// wiring, not a claim this type can make.
///
/// A preview stays outstanding until a resolution actually succeeds. A disengage
/// that failed left a virtual display standing, so the record of what to take
/// down is still the truth and `revert()` can be re-attempted.
///
/// An actor because the countdown and the user's answer race by construction.
public actor SynthesisPreviewSession {
  private let driver: any SynthesisDriving
  private let countdownSeconds: Int

  private var outstanding: PreviewedSynthesis?
  private var countdown = PreviewCountdown()
  private var lastOutcome: SynthesisPreviewOutcome?

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
  /// Blocks for as long as the engine's sequence takes; see `SynthesisDriving`.
  public func begin(
    size: SyntheticSize, onPhysical displayID: CGDirectDisplayID, identityKey: String
  ) async -> Result<PreviewedSynthesis, SynthesisFailure> {
    if let outstanding, outstanding.physicalDisplayID != displayID {
      // A live preview on a DIFFERENT display is ended first: leaving it engaged
      // would strand a panel on a size nobody approved, with its countdown
      // replaced by this display's. If that disengage fails, refuse, rather than
      // build a second synthesis set on top of one that would not come down.
      if case let .failed(failure) = await revertOutstanding() { return .failure(failure) }
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
      // tearing the old pairing down is not knowable from here, and both cases
      // land right: the expiry retries the disengage, and an engine that has
      // already taken it down answers `.notEngaged`, which reads as reverted.
      return .failure(failure)
    }
  }

  /// Keeps the synthesized size the caller was looking at, and hands back the
  /// pairing to persist.
  ///
  /// `answered` is the `PreviewedSynthesis` that was RENDERED. If the outstanding
  /// preview has moved on since, the answer does not apply to it, and persisting
  /// anyway would store a size the user never saw and reapply it at every launch.
  ///
  /// Nothing is applied and nothing can fail: the engage landed at session scope
  /// already. This does NOT re-verify that the set still stands; the
  /// achieved-state checks belong to the engage sequence (SS10).
  public func confirm(_ answered: PreviewedSynthesis) -> SynthesisPreviewOutcome {
    guard let outstanding else {
      // Nothing is engaged: repeat the answer already given rather than
      // inventing a reversion that never happened. Never begun at all is
      // reported as reverted, since nothing is being kept.
      return lastOutcome ?? .reverted
    }
    guard answered == outstanding else { return .stale }
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
    guard let outstanding else { return lastOutcome ?? .reverted }
    guard answered == outstanding else { return .stale }
    return await revertOutstanding()
  }

  /// Call once per second. Returns nil while the countdown runs, and the outcome
  /// when it expires.
  public func tick() async -> SynthesisPreviewOutcome? {
    guard outstanding != nil, countdown.tick() else { return nil }
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
  @discardableResult
  public func revertOnDeparture(displayID: CGDirectDisplayID) async -> SynthesisPreviewOutcome? {
    guard let outstanding, outstanding.physicalDisplayID == displayID else { return nil }
    return await revertOutstanding()
  }

  // MARK: - Private

  /// The expiry, the departure and the cross-display hand-off disengage without
  /// an intent check on purpose: they are the SESSION's own decisions about what
  /// it is holding, not a person's answer to a panel. Only answers can be stale.
  private func revertOutstanding() async -> SynthesisPreviewOutcome {
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
      // mirror set, or both are still standing. Every piece of session state is
      // left intact, so `revert()` is a live retry.
      lastOutcome = .failed(failure)
      return .failed(failure)
    }

    self.outstanding = nil
    countdown.disarm()
    lastOutcome = .reverted
    return .reverted
  }
}
