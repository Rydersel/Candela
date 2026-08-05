import CoreGraphics
import Foundation

/// The applied-but-unresolved mirror preview: what a UI renders, and what an
/// answer about that UI carries back.
///
/// It is the *intent* half that makes the guarantee structural — passing this
/// value back into `confirm`/`revert` means an answer can only ever resolve the
/// preview it was given for, so queue ordering becomes an optimisation rather
/// than the thing preventing a wrong commit. The same argument `PreviewedMode`
/// makes for a mode, made here for a set.
public struct PreviewedMirrorTopology: Sendable, Equatable {
  /// Where the confirmation window goes: the MASTER of the previewed set.
  ///
  /// Carried in the value rather than derived at present time, for the same
  /// reason `PreviewedMode` carries its display ID. And it is the master rather
  /// than the display named in the request because the request's display is a
  /// SLAVE from the instant the preview applies — a mirrored panel is absent
  /// from `NSScreen.screens` entirely (DT16), so a confirmation targeting it
  /// would dismiss itself and the countdown would run to expiry with the user
  /// shown nothing at all.
  public let confirmationDisplayID: CGDirectDisplayID
  /// Exactly what was staged. Confirming re-applies THIS at session scope.
  public let applied: [MirrorChange]
  /// The topology read BEFORE the preview applied. Reverting computes the
  /// changes from live back to this.
  public let capturedTopology: MirrorTopology

  public init(
    confirmationDisplayID: CGDirectDisplayID,
    applied: [MirrorChange],
    capturedTopology: MirrorTopology
  ) {
    self.confirmationDisplayID = confirmationDisplayID
    self.applied = applied
    self.capturedTopology = capturedTopology
  }
}

/// Preview → confirm → commit for a mirror topology, with a countdown that
/// **defaults to revert** (DT19).
///
/// A SIBLING of `ModePreviewSession`, deliberately not a generalisation of it:
/// `OutstandingPreview` is keyed on one display and one `DisplayMode` and
/// `begin()` on a second display reverts the first, and a set operation over N
/// displays cannot be squeezed into that without changing the app's most
/// safety-critical shipped type. Generalising the outstanding value to "a
/// topology delta *or* a mode" would put the already-shipped, already-tested
/// mode path under a type change it does not need.
///
/// Its three invariants are that type's, verbatim:
/// - A preview never begins unless the TOPOLOGY to fall back to was read first.
///   `currentMode(for:)` is wrong for this — on a slave it reports the MASTER's
///   geometry (**measured**: `3440×1440` before, `2580×1080` while mirrored)
///   and may return nil outright — so the fallback is a `MirrorTopology`.
/// - Confirming commits what was PREVIEWED, not what the topology reports at
///   confirm time. The two differ exactly when something went wrong, and
///   committing the drifted value at session scope would make an unapproved
///   topology outlive the process while reporting success.
/// - A preview stays outstanding until a resolution actually SUCCEEDS. An apply
///   that throws changed nothing, so the fallback is still valid and still
///   needed, and retrying is the whole recovery path.
///
/// **One qualification on that third invariant, and it is not a loophole.**
/// `applyMirroring` gained a post-commit check (`MirrorVerification`) for the
/// one case where CoreGraphics accepts a change list, returns `.success`, and
/// does something else — so its throw no longer implies "nothing moved". What
/// still holds is the part the recovery rests on: every revert here recomputes
/// its change list from a LIVE `displays()` sample (`revertOutstanding`), and
/// the one path that does not — `confirm`, which deliberately re-applies what
/// was PREVIEWED — leaves the countdown armed on failure, so the expiry reverts
/// from live instead. No path can retry into a permanent no-op that reports
/// success, which is the failure mode this whole type exists to prevent.
///
/// What it does cost: a `begin` whose apply diverged leaves the machine in
/// CoreGraphics' topology with nothing outstanding to revert it. That is at
/// `.preview` scope, it is reported rather than hidden, and the next
/// engage/toggle samples it live and works from there. The alternative is
/// worse — recording the REQUESTED changes as outstanding and letting a later
/// `confirm` commit them at session scope with `.committed`.
///
/// Only an `.engage` is previewed. A break is never previewed and never gains a
/// countdown: breaking a set returns every display to its own desktop and cannot
/// leave a screen unreadable, while a countdown there would *re-mirror* a rig
/// the user just un-mirrored, while they were still looking for the
/// confirmation window on a screen that had only just come back. It commits
/// through `applyDisengage(_:)` all the same — not because it needs previewing,
/// but because it has to SUPERSEDE any preview that is outstanding, and the
/// preview and its countdown live in here.
///
/// `.preview` scope is a second backstop and nothing more.
/// `kCGConfigureForAppOnly` does self-revert a mirror when the process exits
/// (**measured** twice — clean exit and `SIGKILL`, with a third-process control
/// proving it is not merely a per-process view), but it restores the topology
/// as of process *exit* rather than the one the user approved, and it does
/// nothing at all about a process that stays alive holding a mirror nobody
/// wanted — which is the failure a preview exists to guard. So this type
/// captures and re-applies its own fallback regardless.
///
/// An actor because the countdown and the user's answer race by construction.
public actor MirrorPreviewSession {
  /// The three facts that are only ever true together, modelled as one value so
  /// no path can leave the confirmation target pointing at one preview and the
  /// fallback topology at another.
  private struct Outstanding {
    let confirmationDisplayID: CGDirectDisplayID
    let applied: [MirrorChange]
    /// Captured before the preview was applied. Survives failed resolutions.
    let captured: MirrorTopology
  }

  private let configurator: any DisplayConfiguring
  private let countdownSeconds: Int

  private var outstanding: Outstanding?
  private var remaining = 0
  /// The countdown fires at most once. A failed expiry revert is re-attempted
  /// through `revert()`, not by returning `.failed` from every later tick.
  private var countdownArmed = false
  private var lastOutcome: ModePreviewOutcome?

  /// Thirty seconds, the same as `ModePreviewSession` — see the note there.
  /// Both are one kind of decision and differing timers would be arbitrary.
  public init(configurator: any DisplayConfiguring, countdownSeconds: Int = 30) {
    self.configurator = configurator
    self.countdownSeconds = countdownSeconds
  }

  public var secondsRemaining: Int { remaining }

  /// True while a preview is applied and unresolved — including after a
  /// resolution that threw. `revert()` is worth calling exactly while this
  /// holds.
  public var hasOutstandingPreview: Bool { outstanding != nil }

  /// Whether the countdown can still expire into a revert. Reported rather than
  /// inferred: a failed EXPIRY disarms it while a failed COMMIT leaves it
  /// armed, and a caller that guesses wrong either shows a countdown that will
  /// never fire or hides one that will.
  public var isCountingDown: Bool { countdownArmed && outstanding != nil }

  /// What is applied and unresolved. The authority the UI rebuilds from.
  public var previewedTopology: PreviewedMirrorTopology? {
    outstanding.map {
      PreviewedMirrorTopology(
        confirmationDisplayID: $0.confirmationDisplayID,
        applied: $0.applied,
        capturedTopology: $0.captured
      )
    }
  }

  /// A member of the previewed set has departed. **REVERTS the preview**, and
  /// returns nil when `displayID` is not a member of it (or nothing is
  /// outstanding at all).
  ///
  /// **Deliberately NOT `ModePreviewSession.discard`, which drops without
  /// applying, and deliberately not named the same.** Dropping is right for one
  /// display and one mode: the departed display is the only thing that preview
  /// touched, and it keeps nothing, because its mode was app-scoped and is
  /// renegotiated when it returns. A mirror preview is a SET, and dropping it
  /// strands the members that did NOT depart —
  ///
  /// preview `{1→2, 3→2}`, and display 3 is unplugged inside the countdown window.
  /// Dropping leaves display 1 still mirroring 2 at `.preview` scope, with the
  /// countdown cancelled and the confirmation window dismissed: a topology the
  /// user never approved, with no UI and no timer, recoverable only by quitting
  /// the app. That defeats the entire point of previewing, which is that an
  /// unapproved topology self-heals.
  ///
  /// Uniform across master and slave, and neither needs a special case.
  /// `MirrorTopologyPolicy.changes(from:to:)` iterates the LIVE list, so a
  /// departed display is never staged; and a departure that emptied the set
  /// yields an empty change list, which is already a no-op success.
  ///
  /// A revert that FAILS leaves the preview outstanding and the countdown where
  /// it was, exactly as every other resolution here does: nothing moved, so the
  /// fallback is still the truth, and a still-armed expiry is a free retry.
  @discardableResult
  public func revertOnDeparture(displayID: CGDirectDisplayID) -> ModePreviewOutcome? {
    guard let outstanding else { return nil }
    let members = Set([outstanding.confirmationDisplayID] + outstanding.applied.map(\.display))
    guard members.contains(displayID) else { return nil }
    return revertOutstanding()
  }

  /// Applies `decision` at `.preview` scope and arms the countdown, falling
  /// back to `captured` if nobody answers.
  ///
  /// `captured` is the caller's — read from the same `displays()` sample the
  /// decision was computed from, so the fallback describes the same instant the
  /// decision does.
  public func begin(
    _ decision: MirrorToggleDecision, from captured: MirrorTopology
  ) -> Result<Void, DisplayConfigError> {
    guard case let .engage(master, changes) = decision, !changes.isEmpty else {
      // A break commits through `applyDisengage(_:)` (see the type's doc
      // comment) and a refusal is not a change at all. Neither is partially
      // handled here on purpose:
      // `.disengage` carries `residualMembers`, and a break that leaves a
      // locked slave mirroring is a PARTIAL break its caller has to report. A
      // path through here that bound the changes and dropped the residue would
      // re-create the T3 defect — success reported over a set the user is still
      // looking at — one layer out.
      return .failure(DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue))
    }
    guard !captured.displays.isEmpty else {
      // Nothing readable to restore means nothing to undo with, and the
      // countdown would expire into a no-op — the exact failure this type
      // exists to prevent. Refusing is the only safe answer; the caller
      // surfaces it.
      return .failure(DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
    }
    if outstanding != nil {
      // A live preview is ended first, and a failed revert REFUSES: reporting
      // success here would leave a rig nobody named in an unapproved topology,
      // with no countdown left to take it back.
      if case let .failed(error) = revertOutstanding() { return .failure(error) }
    }
    do {
      try configurator.applyMirroring(changes, scope: .preview)
    } catch let error as DisplayConfigError {
      return .failure(error)
    } catch {
      return .failure(DisplayConfigError(cgErrorCode: -1))
    }
    outstanding = Outstanding(
      confirmationDisplayID: master, applied: changes, captured: captured
    )
    // Cleared HERE, not on entry: a begin() that fails establishes nothing, so
    // the last thing that actually happened is still the last outcome. Wiping
    // it on the way in would make a later confirm() report a reversion that
    // never happened, after a commit that did.
    lastOutcome = nil
    remaining = countdownSeconds
    countdownArmed = true
    return .success(())
  }

  /// Commits a mirror BREAK at session scope, **superseding** any outstanding
  /// preview — resolving it without reverting.
  ///
  /// The break is still not previewed and still never gains a countdown; see
  /// the type's doc comment for why. What it gains by coming through here is
  /// ORDER, and a place the rule can be tested: the outstanding preview and its
  /// countdown live in this actor, so this is the only point at which "resolve
  /// the preview, then apply" cannot be interleaved by an expiry landing
  /// between the two.
  ///
  /// **Superseded, not reverted, and that difference is the whole method.** A
  /// preview's fallback is the topology captured BEFORE it applied, and that
  /// capture can perfectly well contain the very set the user has just asked to
  /// break — start a preview while a set exists, then stop that set. Reverting
  /// would re-apply the capture and bring the set back: half a minute later
  /// if the expiry does it, immediately if this method did. An explicit choice
  /// supersedes a pending question rather than losing to it.
  ///
  /// **Superseding FIRST, before the apply, is deliberate.** Afterwards the
  /// countdown is disarmed and `tick()` cannot re-apply the capture, so no
  /// expiry can land in the middle. The cost is real and is the smaller one: an
  /// apply that THROWS leaves the previewed topology standing with nothing left
  /// to take it back automatically. It is still at `.preview` scope, the caller
  /// reports the failure, and pressing the same button again is the retry — the
  /// other ordering buys that back at the price of a window in which the expiry
  /// re-mirrors the set this call has just dissolved.
  ///
  /// Refuses anything that is not a break, as the mirror image of `begin`
  /// refusing a `.disengage`: every change a break stages names
  /// `kCGNullDirectDisplay`, and an engage arriving here would apply at session
  /// scope with no preview, no countdown and no fallback at all.
  ///
  /// The RESIDUE of a partial break is deliberately not returned. It is decided
  /// before anything is staged, carried by `MirrorToggleDecision.disengage`, and
  /// stated by the caller — the same division of labour that makes `begin`
  /// refuse a disengage rather than swallow its residue.
  public func applyDisengage(_ changes: [MirrorChange]) -> Result<Void, DisplayConfigError> {
    guard changes.allSatisfy({ $0.master == kCGNullDirectDisplay }) else {
      return .failure(DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue))
    }
    supersede()
    do {
      try configurator.applyMirroring(changes, scope: .session)
    } catch let error as DisplayConfigError {
      return .failure(error)
    } catch {
      return .failure(DisplayConfigError(cgErrorCode: -1))
    }
    return .success(())
  }

  /// Commits the preview the caller was looking at, at session scope.
  ///
  /// `answered` is the `PreviewedMirrorTopology` that was RENDERED. If the
  /// outstanding preview has moved on since, the answer does not apply to it,
  /// and committing anyway would make a topology the user never saw outlive the
  /// process while reporting success.
  public func confirm(_ answered: PreviewedMirrorTopology) -> ModePreviewOutcome {
    guard let outstanding else {
      // Nothing is applied: repeat the answer already given rather than
      // inventing a reversion that never happened. Never begun at all is
      // reported as reverted — nothing is being kept.
      return lastOutcome ?? .reverted
    }
    guard matches(answered, outstanding) else { return .stale }
    return resolve(applying: outstanding.applied, success: .committed)
  }

  /// Safe to call repeatedly while `hasOutstandingPreview` names the same
  /// preview. A revert that threw left the topology where it was, so trying
  /// again once CoreGraphics recovers is the whole recovery path — the error UI
  /// hangs off this, and it passes back the same value it is showing.
  public func revert(_ answered: PreviewedMirrorTopology) -> ModePreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }
    guard matches(answered, outstanding) else { return .stale }
    return revertOutstanding()
  }

  /// Call once per second. Returns nil while the countdown runs, and the
  /// outcome when it expires.
  public func tick() -> ModePreviewOutcome? {
    guard countdownArmed, outstanding != nil else { return nil }
    remaining -= 1
    guard remaining <= 0 else { return nil }
    remaining = 0
    countdownArmed = false
    return revertOutstanding()
  }

  // MARK: - Private

  /// The expiry and the cross-preview hand-off revert without an intent check
  /// on purpose: they are the SESSION's own decisions about what it is holding,
  /// not a person's answer to a window. Only answers can be stale.
  private func revertOutstanding() -> ModePreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }
    // Computed against the LIVE topology, not against the applied changes: a
    // display that moved since the preview must be restored to what the capture
    // said about it, and one that did not move must not be staged at all —
    // `applyMirroring` is all-or-nothing, so a redundant change that fails to
    // stage would cancel the revert entirely.
    let live = MirrorTopology(configurator.displays())
    let changes = MirrorTopologyPolicy.changes(from: live, to: outstanding.captured)
    return resolve(applying: changes, success: .reverted)
  }

  /// Resolves the outstanding preview by DROPPING it — nothing is applied, and
  /// the countdown is disarmed with it. The one caller is `applyDisengage`,
  /// whose doc comment carries the argument for why this is not a revert.
  ///
  /// `lastOutcome` becomes `.stale` rather than `.reverted`. A window that was
  /// still on screen when this ran can still deliver an answer, and `.stale` is
  /// the truthful reply to it: that answer resolved nothing. `.reverted` would
  /// claim a restoration that never happened — the same class of false report
  /// this whole path exists to close — and `.committed` would claim the preview
  /// was kept.
  @discardableResult
  private func supersede() -> PreviewedMirrorTopology? {
    guard let superseded = previewedTopology else { return nil }
    outstanding = nil
    remaining = 0
    countdownArmed = false
    lastOutcome = .stale
    return superseded
  }

  private func matches(
    _ answered: PreviewedMirrorTopology, _ outstanding: Outstanding
  ) -> Bool {
    answered.confirmationDisplayID == outstanding.confirmationDisplayID
      && answered.applied == outstanding.applied
  }

  /// Success is what clears the outstanding preview. A throw leaves every piece
  /// of session state intact — nothing moved, so the record of how to move it
  /// back is still the truth.
  ///
  /// A failed COMMIT deliberately leaves the countdown armed: the user asked to
  /// keep a topology that could not be made permanent, and falling back to the
  /// one they can definitely read is the safe way to end that.
  ///
  /// An EMPTY change list is a success, not a failure. `applyMirroring` opens
  /// no transaction for it, and "the topology is already what you asked for" is
  /// a resolution — which is the COMMON case on revert, since
  /// `MirrorTopologyPolicy.changes(from:to:)` returns `[]` whenever the live
  /// topology already matches the capture.
  private func resolve(
    applying changes: [MirrorChange], success: ModePreviewOutcome
  ) -> ModePreviewOutcome {
    do {
      try configurator.applyMirroring(changes, scope: .session)
    } catch let error as DisplayConfigError {
      lastOutcome = .failed(error)
      return .failed(error)
    } catch {
      let error = DisplayConfigError(cgErrorCode: -1)
      lastOutcome = .failed(error)
      return .failed(error)
    }
    outstanding = nil
    remaining = 0
    countdownArmed = false
    lastOutcome = success
    return success
  }
}
