import CoreGraphics
import Foundation

/// The applied-but-unresolved layout: what a UI renders, and what an answer
/// about that UI carries back.
///
/// It is the *intent* half that makes the guarantee structural — passing this
/// value back into `confirm`/`revert` means an answer can only ever resolve the
/// preview it was given for, so queue ordering becomes an optimisation rather
/// than the thing preventing a wrong commit. The same argument `PreviewedMode`
/// makes for a mode and `PreviewedMirrorTopology` makes for a set.
public struct PreviewedArrangement: Sendable, Equatable {
  /// What was staged, at `.preview` scope. Confirming re-applies exactly THIS.
  public let plan: ArrangementPlan
  /// What is on screen NOW — read back after the apply, never assumed (§6.3).
  /// macOS adjusts a requested layout silently, so this is the only trustworthy
  /// account of what the preview achieved.
  public let achieved: DisplayArrangement

  /// The layout that was asked for. Together with `achieved` these are exactly
  /// the two inputs `ArrangementOutcomePolicy.notices` needs; the session forms
  /// no opinion about the difference and leaves that judgement to its caller.
  public var requested: DisplayArrangement { plan.arrangement }

  /// Where a confirmation belongs (§6.2): the display holding the menu bar
  /// while the preview stands, which is the display at the origin of the
  /// ACHIEVED layout rather than of the requested one — a request that macOS
  /// adjusted did not necessarily move the menu bar where it was asked to.
  ///
  /// Derived, never stored, for the reason AR5 gives: a stored main is a second
  /// source of truth able to disagree with the geometry it describes. `nil`
  /// when the achieved layout has no tile at the origin, which a caller answers
  /// by falling back to the display the user dragged — knowledge this type does
  /// not have.
  public var confirmationDisplayID: CGDirectDisplayID? { achieved.mainDisplayID }

  public init(plan: ArrangementPlan, achieved: DisplayArrangement) {
    self.plan = plan
    self.achieved = achieved
  }
}

/// Preview → confirm → commit for a display arrangement, with a countdown that
/// **defaults to revert** (AR8).
///
/// A SIBLING of `ModePreviewSession`, in the shape drag-canvas §6.1 asks for,
/// and deliberately not a generalisation of it: `OutstandingPreview` is keyed on
/// one display and one `DisplayMode`, and a layout is a fact about the whole
/// display set. Its three safety properties transfer verbatim, and the reasons
/// are stronger here, not weaker:
///
/// - **A preview never begins unless the layout to fall back to was read
///   first.** Without it the countdown would expire into a no-op, which is the
///   failure this whole type exists to prevent.
/// - **Confirming commits what was PREVIEWED, not what the machine reports at
///   confirm time.** The two differ exactly when something went wrong, and
///   committing the drifted value at permanent scope would make an unapproved
///   layout survive a logout while reporting success.
/// - **A preview stays outstanding until a resolution actually SUCCEEDS.** An
///   apply that throws leaves the fallback valid and still needed, and retrying
///   is the whole recovery path.
///
/// **One qualification on that third invariant, and it is not a loophole.**
/// `DisplayArrangementConfiguring.apply` carries a post-commit check
/// (`ArrangementVerification`) for the case where CoreGraphics accepts a
/// transaction, returns `.success`, and achieves something else (#53) — so its
/// throw does NOT imply "nothing moved". What still holds is the part the
/// recovery rests on: every revert here computes its plan from a LIVE sample
/// (`revertOutstanding`), and the one path that does not — `confirm`, which
/// deliberately re-applies what was PREVIEWED — leaves the countdown armed on
/// failure, so the expiry reverts from live instead. No path can retry into a
/// permanent no-op that reports success, which is the failure this type exists
/// to prevent.
///
/// What it costs: a `begin` whose apply diverged leaves the machine in
/// CoreGraphics' layout with nothing outstanding to take it back. That layout is
/// at `.preview` scope, the failure is reported rather than hidden, and the next
/// `begin` samples live and works from there — its fallback is then the diverged
/// layout, not the one the user started on. The alternative is worse: recording
/// a plan the platform is known to have ignored as outstanding, and letting a
/// later `confirm` commit it permanently with `.committed`.
///
/// **Why `.permanent` and not `.session`** (§6.1): the arrangement is what macOS
/// itself persists per display-set, so a session-scoped commit is lost at logout
/// and reads as the feature not working. **Reverts commit at `.permanent` too**,
/// which is the less obvious half: a `confirm` that threw may still have written
/// a diverged layout permanently, so a restoration at a weaker scope could leave
/// that layout as the stored one. The cost, stated rather than hidden — a
/// cancelled preview writes the pre-preview on-screen layout to the user's
/// stored configuration, which differs from what was already there only if
/// something outside this app had made a session-scoped layout change.
///
/// `.preview` scope (`kCGConfigureForAppOnly`) is a second backstop and nothing
/// more: it unwinds if the process dies, but it does nothing about a process
/// that stays alive holding a layout nobody wanted — which is the failure a
/// preview exists to guard.
///
/// An actor because the countdown and the user's answer race by construction.
public actor ArrangementPreviewSession {
  /// The two facts that are only ever true together, modelled as one value so no
  /// path can leave the fallback describing one preview and the rendered state
  /// another.
  private struct Outstanding {
    /// The layout read BEFORE the preview applied. Survives failed resolutions.
    let captured: DisplayArrangement
    let previewed: PreviewedArrangement
  }

  private let configurator: any DisplayArrangementConfiguring
  private let countdownSeconds: Int

  private var outstanding: Outstanding?
  private var countdown = PreviewCountdown()
  private var lastOutcome: PreviewOutcome?

  /// Thirty seconds, the same as `ModePreviewSession` and `MirrorPreviewSession`
  /// — see the note there. All three are one kind of decision (a reconfiguration
  /// that may itself have made the answer hard to read) and differing timers
  /// would be arbitrary. Longer if anything is defensible here, since this is
  /// the change that can move the menu bar onto another screen.
  public init(
    configurator: any DisplayArrangementConfiguring, countdownSeconds: Int = 30
  ) {
    self.configurator = configurator
    self.countdownSeconds = countdownSeconds
  }

  public var secondsRemaining: Int { countdown.remaining }

  /// True while a preview is applied and unresolved — including after a
  /// resolution that threw. `revert()` is worth calling exactly while this
  /// holds.
  public var hasOutstandingPreview: Bool { outstanding != nil }

  /// Whether the countdown can still expire into a revert. Reported rather than
  /// inferred: a failed EXPIRY disarms it while a failed COMMIT leaves it armed,
  /// and a caller that guesses wrong either shows a countdown that will never
  /// fire or hides one that will.
  public var isCountingDown: Bool { countdown.isArmed && outstanding != nil }

  /// What is applied and unresolved. The authority a UI rebuilds from.
  public var previewedArrangement: PreviewedArrangement? { outstanding?.previewed }

  /// The display set has changed, so the captured layout describes a machine
  /// that no longer exists. Drops the outstanding preview WITHOUT applying
  /// anything, and reports whether it dropped one.
  ///
  /// **It takes no display argument, and that is the point** — the contrast with
  /// `ModePreviewSession.discard(displayID:)`, which drops ONE display's preview
  /// because a stored mode is per display. A preview about a *set* is invalidated
  /// by any display arriving or leaving, not only by one particular ID going
  /// away, so a method that had to be told which display would be a method that
  /// could be asked the wrong question.
  ///
  /// The outcome recorded is `.reverted`, for the reason
  /// `ModePreviewSession.discard` records it: nothing is being KEPT, and no path
  /// from here will commit the preview. What it does NOT claim is that the
  /// surviving displays moved back. They are where the preview put them, at
  /// `.preview` scope, until the process exits or a later preview captures them
  /// — because AR4 will not let a plan name only part of the live display set,
  /// and a layout that mixed captured origins for the survivors with macOS's
  /// choice for a newcomer is one nobody ever approved either.
  @discardableResult
  public func discardIfTopologyChanged() -> Bool {
    dropIfUnrestorable(against: configurator.currentArrangement())
  }

  /// Applies `wanted` at `.preview` scope and arms the countdown.
  ///
  /// **The plan is computed HERE, from a live sample, and cannot be handed in.**
  /// A caller holding a plan holds a description of a machine as it was when the
  /// gesture started; between then and now an apply can have diverged, a display
  /// can have moved, and applying a plan against a baseline that has moved on is
  /// how a retry becomes a no-op that reports success. Taking the wanted layout
  /// rather than the plan makes "computed from live" a property of the type
  /// instead of a rule its callers have to follow.
  ///
  /// Fails when the live layout cannot be read, when the topology has moved such
  /// that `wanted` no longer describes it, when there is nothing to change, and
  /// when the apply itself fails.
  public func begin(
    _ wanted: DisplayArrangement
  ) -> Result<PreviewedArrangement, DisplayConfigError> {
    let live = configurator.currentArrangement()
    guard !live.isEmpty else {
      // Nothing readable to restore means nothing to undo with, and the
      // countdown would expire into a no-op — the exact failure this type exists
      // to prevent. Refusing is the only safe answer; the caller surfaces it.
      // Checked BEFORE the drop below, because an unreadable sweep is not a
      // departure (§4.4) and must not cost an outstanding preview its fallback.
      return .failure(DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
    }
    // A capture whose display set is gone must not survive into the next preview
    // as its fallback.
    dropIfUnrestorable(against: live)
    // Re-previewing keeps the ORIGINAL fallback. What is on screen is the
    // unconfirmed preview, which is never a safe thing to fall back to — and
    // after a failed resolution it is the layout we are specifically trying to
    // get away from.
    let fallback = outstanding?.captured ?? live

    guard let plan = ArrangementPlan(applying: wanted, to: live) else {
      // A no-op, a display set that has changed since `wanted` was computed, a
      // mirror slave holding a tile (AR6), or an origin outside `Int32`. None is
      // a request that can be made of CoreGraphics as a whole, and a partial one
      // is what AR4 exists to make unrepresentable.
      return .failure(DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue))
    }

    let achieved: DisplayArrangement
    do {
      achieved = try configurator.apply(plan, scope: .preview)
    } catch let error as DisplayConfigError {
      // Deliberately leaves `outstanding` untouched. If a preview was already
      // standing, its fallback and its still-armed countdown are the recovery;
      // if none was, this establishes nothing (see the type's doc comment for
      // what a DIVERGED apply costs).
      return .failure(error)
    } catch {
      return .failure(DisplayConfigError(cgErrorCode: -1))
    }

    let previewed = PreviewedArrangement(plan: plan, achieved: achieved)
    outstanding = Outstanding(captured: fallback, previewed: previewed)
    // Cleared HERE, not on entry: a begin() that fails establishes nothing, so
    // the last thing that actually happened is still the last outcome. Wiping it
    // on the way in would make a later confirm() report a reversion that never
    // happened, after a commit that did.
    lastOutcome = nil
    countdown.arm(seconds: countdownSeconds)
    return .success(previewed)
  }

  /// Commits the preview the caller was looking at, at `.permanent` scope.
  ///
  /// `answered` is the `PreviewedArrangement` that was RENDERED. If the
  /// outstanding preview has moved on since — a second drop landed between the
  /// click and this call — the answer does not apply to it, and committing
  /// anyway would make a layout the user never saw permanent while reporting
  /// success. That is the worst failure this type can produce, so it is refused
  /// structurally rather than prevented by call ordering.
  ///
  /// Re-applying a layout that is already on screen is NOT a no-op reporting
  /// success: the preview holds it at `.preview` scope and this is what makes it
  /// permanent. The change is in the durability, not in the pixels.
  public func confirm(_ answered: PreviewedArrangement) -> PreviewOutcome {
    guard let outstanding else {
      // Nothing is applied: repeat the answer already given rather than
      // inventing a reversion that never happened. Never begun at all is
      // reported as reverted — nothing is being kept.
      return lastOutcome ?? .reverted
    }
    guard answered == outstanding.previewed else { return .stale }
    return resolve(applying: outstanding.previewed.plan, success: .committed)
  }

  /// Safe to call repeatedly while `hasOutstandingPreview` names the same
  /// preview: the fallback is untouched by a failed resolution and every attempt
  /// recomputes its plan from a live sample, so trying again once CoreGraphics
  /// recovers is the whole recovery path — the error UI hangs off this, and it
  /// passes back the same value it is showing.
  ///
  /// Deliberately NOT "a revert that threw left the layout where it was". The
  /// seam's post-commit check can throw over a layout that DID move (see the
  /// type's doc comment), which is exactly why the retry re-samples instead of
  /// replaying.
  public func revert(_ answered: PreviewedArrangement) -> PreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }
    guard answered == outstanding.previewed else { return .stale }
    return revertOutstanding()
  }

  /// Call once per second. Returns nil while the countdown runs, and the outcome
  /// when it expires.
  public func tick() -> PreviewOutcome? {
    guard outstanding != nil, countdown.tick() else { return nil }
    return revertOutstanding()
  }

  // MARK: - Private

  /// The expiry reverts without an intent check on purpose: it is the SESSION's
  /// own decision about what it is holding, not a person's answer to a window.
  /// Only answers can be stale.
  private func revertOutstanding() -> PreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }
    // Computed against the LIVE layout, not against the plan that was applied: a
    // display that moved since the preview must be restored to what the capture
    // said about it, and the transaction is all-or-nothing, so a plan built from
    // a baseline the machine has left would be a request about a machine that
    // does not exist.
    let live = configurator.currentArrangement()
    guard !live.isEmpty else {
      // Nothing readable to restore ONTO. Neither a departure nor a permanent
      // refusal — the layout sweep can come back (§4.4) — so the preview stays
      // outstanding and a later `revert()` is the retry.
      let error = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
      lastOutcome = .failed(error)
      return .failed(error)
    }
    if dropIfUnrestorable(against: live) { return .reverted }

    guard live != outstanding.captured else {
      // Already back where it started — nothing to apply, and that IS the
      // restoration. `ArrangementPlan` refuses a no-op, so this case has to be
      // decided here rather than read off a nil plan, where it would be
      // indistinguishable from the refusals below.
      drop(reporting: .reverted)
      return .reverted
    }
    guard let plan = ArrangementPlan(applying: outstanding.captured, to: live) else {
      // The display sets match and the layouts differ, so this is one of
      // `ArrangementPlan`'s structural refusals of the CAPTURE itself — a
      // captured tile whose display has since become a mirror slave (AR6), or an
      // origin outside `Int32`. No retry can fix a fallback that cannot be
      // expressed as a request, so it is dropped rather than held: keeping it
      // would leave a revert that fails identically forever. Reported as failed,
      // never as reverted — the previewed layout is still on screen, held at
      // `.preview` scope until the process exits.
      let error = DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue)
      drop(reporting: .failed(error))
      return .failed(error)
    }
    return resolve(applying: plan, success: .reverted)
  }

  /// One predicate for "the captured layout is no longer restorable", shared by
  /// `discardIfTopologyChanged` and every revert, so the proactive call and the
  /// expiry cannot disagree about it. Without the sharing, a countdown that
  /// expired before the caller noticed a departure would try to apply a plan for
  /// a display set that no longer exists and stay outstanding forever.
  @discardableResult
  private func dropIfUnrestorable(against live: DisplayArrangement) -> Bool {
    guard let outstanding else { return false }
    // An empty sweep is every display unreadable at once, which is a transient
    // state the reapply path DEFERS on (§4.4) — reading it as "every display
    // departed" would throw away a perfectly good fallback over a bad instant.
    guard !live.isEmpty else { return false }
    let liveIDs = Set(live.tiles.map(\.id))
    guard liveIDs != Set(outstanding.captured.tiles.map(\.id)) else { return false }
    drop(reporting: .reverted)
    return true
  }

  private func drop(reporting outcome: PreviewOutcome) {
    outstanding = nil
    countdown.disarm()
    lastOutcome = outcome
  }

  /// Success is what clears the outstanding preview. A throw leaves every piece
  /// of session state intact, so the record of how to move the layout back is
  /// still available — with the qualification in the type's doc comment: the
  /// configurator's post-commit check can throw over a layout that DID move, so
  /// "it threw" does not by itself mean "nothing happened". That is why the
  /// revert above re-samples live rather than replaying anything.
  ///
  /// A failed COMMIT deliberately leaves the countdown armed: the user asked to
  /// keep a layout that could not be made permanent, and falling back to the one
  /// they can definitely read is the safe way to end that.
  private func resolve(
    applying plan: ArrangementPlan, success: PreviewOutcome
  ) -> PreviewOutcome {
    do {
      // The achieved layout is discarded HERE and only here: the configurator
      // has already compared it against the plan and thrown if the platform
      // ignored a request it had nothing to adjust. What remains — the documented
      // adjustment of a layout with gaps or overlaps — is a notice a caller reads
      // back from `currentArrangement()`, not something a resolution outcome has
      // room to carry.
      _ = try configurator.apply(plan, scope: .permanent)
    } catch let error as DisplayConfigError {
      lastOutcome = .failed(error)
      return .failed(error)
    } catch {
      let error = DisplayConfigError(cgErrorCode: -1)
      lastOutcome = .failed(error)
      return .failed(error)
    }
    outstanding = nil
    countdown.disarm()
    lastOutcome = success
    return success
  }
}
