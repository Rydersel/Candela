import CoreGraphics
import Foundation

/// The applied-but-unresolved layout: what a UI renders, and what an answer
/// about that UI carries back.
///
/// Passing this value back into `confirm`/`revert` means an answer can only resolve
/// the preview it was given for, so queue ordering is an optimisation rather than the
/// thing preventing a wrong commit. Same argument as `PreviewedMode`.
public struct PreviewedArrangement: Sendable, Equatable {
  /// What was staged, at `.preview` scope. Confirming re-applies exactly THIS.
  public let plan: ArrangementPlan
  /// What is on screen NOW, read back after the apply, never assumed (§6.3). macOS
  /// adjusts a requested layout silently.
  public let achieved: DisplayArrangement

  /// The layout that was asked for. With `achieved`, the two inputs
  /// `ArrangementOutcomePolicy.notices` needs; the session judges the difference not
  /// at all.
  public var requested: DisplayArrangement { plan.arrangement }

  /// Where a confirmation belongs (§6.2): the display at the origin of the ACHIEVED
  /// layout, not the requested one, because a request macOS adjusted did not
  /// necessarily move the menu bar where it was asked to.
  ///
  /// Derived, never stored (AR5): a stored main is a second source of truth able to
  /// disagree with the geometry it describes. `nil` when the achieved layout has no
  /// tile at the origin, which the caller answers with the display the user dragged.
  public var confirmationDisplayID: CGDirectDisplayID? { achieved.mainDisplayID }

  public init(plan: ArrangementPlan, achieved: DisplayArrangement) {
    self.plan = plan
    self.achieved = achieved
  }
}

/// Preview → confirm → commit for a display arrangement, with a countdown that
/// **defaults to revert** (AR8).
///
/// A SIBLING of `ModePreviewSession`, not a generalisation of it: that one is keyed
/// on one display and one `DisplayMode`, and a layout is a fact about the whole set.
/// Its three safety properties transfer:
///
/// - **A preview never begins unless the layout to fall back to was read first.**
///   Otherwise the countdown expires into a no-op.
/// - **Confirming commits what was PREVIEWED, not what the machine reports at confirm
///   time.** The two differ exactly when something went wrong, and committing the
///   drift permanently makes an unapproved layout survive a logout while reporting
///   success.
/// - **A preview stays outstanding until a resolution actually SUCCEEDS.** An apply
///   that throws leaves the fallback valid and still needed.
///
/// **One qualification on the third, and it is not a loophole.** The post-commit check
/// in `DisplayArrangementConfiguring.apply` fires when CoreGraphics accepts a
/// transaction, returns `.success`, and achieves something else, so its throw does NOT
/// imply "nothing moved". Every revert here computes its plan from a LIVE sample, and
/// `confirm`, which re-applies what was PREVIEWED, leaves the countdown armed on
/// failure so the expiry reverts from live. No path retries into a permanent no-op
/// that reports success.
///
/// The cost: a `begin` whose apply diverged leaves the machine in CoreGraphics'
/// layout with nothing outstanding to take it back, at `.preview` scope, and the next
/// `begin` works from there. The alternative is worse: holding a plan the platform is
/// known to have ignored, and letting a later `confirm` commit it permanently.
///
/// **Why `.permanent` and not `.session`** (§6.1): macOS itself persists the
/// arrangement per display-set, so a session-scoped commit is lost at logout and reads
/// as the feature not working. **Reverts commit at `.permanent` too**, because a
/// `confirm` that threw may still have written a diverged layout permanently. The
/// cost: a cancelled preview writes the pre-preview on-screen layout to the user's
/// stored configuration.
///
/// `.preview` scope (`kCGConfigureForAppOnly`) is a second backstop only: it unwinds
/// if the process dies, and does nothing about a live process holding a layout nobody
/// wanted.
///
/// An actor because the countdown and the user's answer race by construction.
public actor ArrangementPreviewSession {
  /// One value so no path can leave the fallback describing one preview and the
  /// rendered state another.
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

  /// Matches `ModePreviewSession` and `MirrorPreviewSession`. All three are one kind
  /// of decision, a reconfiguration that may itself have made the answer hard to read,
  /// so differing timers would be arbitrary.
  public init(
    configurator: any DisplayArrangementConfiguring, countdownSeconds: Int = 30
  ) {
    self.configurator = configurator
    self.countdownSeconds = countdownSeconds
  }

  public var secondsRemaining: Int { countdown.remaining }

  /// True while a preview is applied and unresolved, including after a resolution
  /// that threw. `revert()` is worth calling exactly while this holds.
  public var hasOutstandingPreview: Bool { outstanding != nil }

  /// Reported rather than inferred: a failed EXPIRY disarms the countdown while a
  /// failed COMMIT leaves it armed, so a caller that guesses either shows a countdown
  /// that will never fire or hides one that will.
  public var isCountingDown: Bool { countdown.isArmed && outstanding != nil }

  /// What is applied and unresolved. The authority a UI rebuilds from.
  public var previewedArrangement: PreviewedArrangement? { outstanding?.previewed }

  /// The display set has changed, so the captured layout describes a machine
  /// that no longer exists. Drops the outstanding preview WITHOUT applying
  /// anything, and reports whether it dropped one.
  ///
  /// **It takes no display argument, and that is the point.** A preview about a *set*
  /// is invalidated by any display arriving or leaving, so a method that had to be
  /// told which display could be asked the wrong question.
  ///
  /// The outcome recorded is `.reverted` because nothing is being KEPT. It does NOT
  /// claim the surviving displays moved back: they stay where the preview put them, at
  /// `.preview` scope, because AR4 will not let a plan name only part of the live set.
  @discardableResult
  public func discardIfTopologyChanged() -> Bool {
    dropIfUnrestorable(against: configurator.currentArrangement())
  }

  /// Applies `wanted` at `.preview` scope and arms the countdown.
  ///
  /// **The plan is computed HERE, from a live sample, and cannot be handed in.** A
  /// caller's plan describes the machine as it was when the gesture started, and
  /// applying one against a baseline that has moved on is how a retry becomes a no-op
  /// that reports success. Taking the wanted layout makes "computed from live" a
  /// property of the type instead of a rule callers have to follow.
  ///
  /// Fails when the live layout cannot be read, when the topology has moved such that
  /// `wanted` no longer describes it, when there is nothing to change, and when the
  /// apply fails.
  public func begin(
    _ wanted: DisplayArrangement
  ) -> Result<PreviewedArrangement, DisplayConfigError> {
    let live = configurator.currentArrangement()
    guard !live.isEmpty else {
      // Nothing readable to restore means nothing to undo with, and the countdown
      // would expire into a no-op. Checked BEFORE the drop below, because an
      // unreadable sweep is not a departure (§4.4) and must not cost an outstanding
      // preview its fallback.
      return .failure(DisplayConfigError(cgErrorCode: CGError.failure.rawValue))
    }
    // A capture whose display set is gone must not survive into the next preview
    // as its fallback.
    dropIfUnrestorable(against: live)
    // Re-previewing keeps the ORIGINAL fallback. What is on screen is the unconfirmed
    // preview, which after a failed resolution is the layout we are trying to leave.
    let fallback = outstanding?.captured ?? live

    guard let plan = ArrangementPlan(applying: wanted, to: live) else {
      // A no-op, a display set changed since `wanted` was computed, a mirror slave
      // holding a tile (AR6), or an origin outside `Int32`.
      return .failure(DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue))
    }

    let achieved: DisplayArrangement
    do {
      achieved = try configurator.apply(plan, scope: .preview)
    } catch let error as DisplayConfigError {
      // Leaves `outstanding` untouched: a standing preview's fallback and armed
      // countdown are the recovery, and if none was standing this establishes
      // nothing.
      return .failure(error)
    } catch {
      return .failure(DisplayConfigError(cgErrorCode: -1))
    }

    let previewed = PreviewedArrangement(plan: plan, achieved: achieved)
    outstanding = Outstanding(captured: fallback, previewed: previewed)
    // Cleared HERE, not on entry: a failed begin() establishes nothing, so the last
    // thing that happened is still the last outcome. Wiping it on the way in would
    // make a later confirm() report a reversion that never happened.
    lastOutcome = nil
    countdown.arm(seconds: countdownSeconds)
    return .success(previewed)
  }

  /// Commits the preview the caller was looking at, at `.permanent` scope.
  ///
  /// `answered` is the `PreviewedArrangement` that was RENDERED. If the outstanding
  /// preview moved on since (a second drop landing between the click and this call)
  /// the answer does not apply to it, and committing anyway makes a layout the user
  /// never saw permanent while reporting success.
  ///
  /// Re-applying a layout already on screen is NOT a no-op: the preview holds it at
  /// `.preview` scope and this is what makes it permanent.
  public func confirm(_ answered: PreviewedArrangement) -> PreviewOutcome {
    guard let outstanding else {
      // Nothing is applied: repeat the answer already given rather than inventing a
      // reversion that never happened. Never begun reports reverted, since nothing is
      // being kept.
      return lastOutcome ?? .reverted
    }
    guard answered == outstanding.previewed else { return .stale }
    return resolve(applying: outstanding.previewed.plan, success: .committed)
  }

  /// Safe to call repeatedly while `hasOutstandingPreview` names the same preview: a
  /// failed resolution leaves the fallback alone and every attempt recomputes its plan
  /// from a live sample.
  ///
  /// Deliberately NOT "a revert that threw left the layout where it was". The seam's
  /// post-commit check can throw over a layout that DID move, which is why the retry
  /// re-samples instead of replaying.
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

  /// No intent check: the expiry is the SESSION's own decision about what it holds,
  /// not a person's answer. Only answers can be stale.
  private func revertOutstanding() -> PreviewOutcome {
    guard let outstanding else { return lastOutcome ?? .reverted }
    // Computed against the LIVE layout, not the plan that was applied. The
    // transaction is all-or-nothing, so a plan built from a baseline the machine has
    // left is a request about a machine that does not exist.
    let live = configurator.currentArrangement()
    guard !live.isEmpty else {
      // Nothing readable to restore ONTO, and neither a departure nor a permanent
      // refusal: the layout sweep can come back (§4.4), so the preview stays
      // outstanding and a later `revert()` is the retry.
      let error = DisplayConfigError(cgErrorCode: CGError.failure.rawValue)
      lastOutcome = .failed(error)
      return .failed(error)
    }
    if dropIfUnrestorable(against: live) { return .reverted }

    guard live != outstanding.captured else {
      // Already back where it started, and that IS the restoration. `ArrangementPlan`
      // refuses a no-op, so deciding it here keeps it distinguishable from the
      // refusals below.
      drop(reporting: .reverted)
      return .reverted
    }
    guard let plan = ArrangementPlan(applying: outstanding.captured, to: live) else {
      // The sets match and the layouts differ, so this is a structural refusal of the
      // CAPTURE itself: a captured tile whose display became a mirror slave (AR6), or
      // an origin outside `Int32`. No retry can fix a fallback that cannot be
      // expressed as a request, so it is dropped rather than held. Reported as failed,
      // never reverted: the previewed layout is still on screen at `.preview` scope.
      let error = DisplayConfigError(cgErrorCode: CGError.illegalArgument.rawValue)
      drop(reporting: .failed(error))
      return .failed(error)
    }
    return resolve(applying: plan, success: .reverted)
  }

  /// Shared by `discardIfTopologyChanged` and every revert so the proactive call and
  /// the expiry cannot disagree. Unshared, a countdown expiring before the caller
  /// noticed a departure applies a plan for a set that no longer exists and stays
  /// outstanding forever.
  @discardableResult
  private func dropIfUnrestorable(against live: DisplayArrangement) -> Bool {
    guard let outstanding else { return false }
    // An empty sweep is every display unreadable at once, a transient the reapply
    // path DEFERS on (§4.4). Reading it as "every display departed" throws away a
    // good fallback over a bad instant.
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

  /// Success is what clears the outstanding preview. A throw leaves session state
  /// intact, so the record of how to move the layout back survives. The configurator's
  /// post-commit check can throw over a layout that DID move, so "it threw" does not
  /// mean "nothing happened", which is why the revert above re-samples live.
  ///
  /// A failed COMMIT leaves the countdown armed: the user asked to keep a layout that
  /// could not be made permanent, and falling back to one they can read ends it
  /// safely.
  private func resolve(
    applying plan: ArrangementPlan, success: PreviewOutcome
  ) -> PreviewOutcome {
    do {
      // The achieved layout is discarded HERE and only here: the configurator already
      // compared it against the plan and threw if the platform ignored a request it
      // had nothing to adjust. What remains, the documented gap/overlap adjustment, is
      // a notice a caller reads back from `currentArrangement()`.
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
