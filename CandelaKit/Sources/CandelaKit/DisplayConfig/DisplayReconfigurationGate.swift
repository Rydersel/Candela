import Foundation

/// The things in this app that reconfigure displays, and therefore the things
/// that must not do it at the same time.
///
/// **Four cases, not three (AR12).** The drag-canvas design wrote AR10 while
/// rotation was unbuilt and called the exclusion a three-way problem; rotation
/// shipped on 2026-08-04, so the ruling was amended. All four open a
/// `CGBeginDisplayConfiguration`-shaped transaction or its `SkyLight` equivalent,
/// all four leave an unanswered preview standing for up to thirty seconds, and
/// the pairing the amendment exists for is the least obvious one: a resolution
/// change during an arrangement preview alters the very tile sizes the layout was
/// computed from, so the layout on screen stops being the layout that was asked
/// about.
///
/// `CaseIterable` so the exclusion suite can enumerate every ordered pair rather
/// than list twelve of them by hand — a case added without a test is then a case
/// that is tested anyway.
public enum ReconfigurationClaimant: String, Sendable, CaseIterable {
  case displayModes
  case mirroring
  case rotation
  case arrangement
}

/// The gate's whole answer. `.refused` names the holder rather than saying "no",
/// because every surface that reports one has to finish the sentence — "finish
/// the resolution change first" is actionable and "busy" is not.
public enum ReconfigurationClaimOutcome: Sendable, Equatable {
  case granted
  case refused(by: ReconfigurationClaimant)

  public var isGranted: Bool {
    if case .granted = self { return true }
    return false
  }

  public var refusedBy: ReconfigurationClaimant? {
    if case let .refused(claimant) = self { return claimant }
    return nil
  }
}

/// At most one display reconfiguration is outstanding at a time (AR10, amended
/// by AR12).
///
/// It replaces the shape that was there before it: `MirroringCoordinator` reached
/// into `DisplayModeCoordinator.endOutstandingPreview()` on two of its arms, and
/// rotation asked nobody anything. Two ad-hoc cross-references become twelve
/// when the fourth claimant arrives, and the twelfth is the one nobody writes.
///
/// **The decision lives here, in the engine, because there is no app test target
/// (D21).** An exclusion rule that only exists as `if` statements spread across
/// four `@MainActor` coordinators cannot be tested at all, and the failure it
/// guards against — a stranded claim — deadlocks every display feature in the
/// app at once. What stays in the app target is the wiring: who claims, when, and
/// what the refusal says.
///
/// ## What it guarantees
///
/// - One holder. A second claimant is refused and told who holds it.
/// - **A claimant is never refused its own claim.** Superseding is a supported
///   operation in three of the four — `ModePreviewSession.begin` on a second
///   display ends the first display's preview, `MirrorPreviewSession.applyDisengage`
///   supersedes an outstanding engage — so a gate that refused the holder would
///   break the feature it is protecting, and it would do it silently.
/// - **A claimant can only release its own claim.** Without that check the
///   release at the end of one feature's operation frees the claim another
///   feature took while it ran, which is precisely the interleave the gate
///   exists to prevent — and it would fail open, invisibly.
/// - Releasing is idempotent and safe when nothing is held, so the caller that
///   releases can do it unconditionally from the one place that already knows
///   whether anything is outstanding.
///
/// ## What it does NOT guarantee, stated rather than implied
///
/// **It cannot detect a holder that has stopped running.** Nothing here polls a
/// claimant or asks it whether it is still alive; a liveness probe would have to
/// call back onto the main actor, and this codebase documents main-actor work
/// being starved for the whole of a menu-tracking session — a gate that wedges
/// when the main thread wedges is worse than no gate. So the obligation is on
/// the claimant, and it is discharged structurally rather than by discipline:
/// **every claimant releases from the same funnel that writes its preview
/// state** (`adopt`, which is already documented in all four coordinators as the
/// only writer of `preview`). A claim is then a projection of "something is
/// outstanding", and the paths that end a preview without anyone answering it —
/// a failed `begin`, an expiry, a display departing mid-hold — all run through
/// that funnel already.
///
/// An actor rather than a `@MainActor` type even though all four claimants are
/// main-actor coordinators: the countdown drivers are deliberately detached (a
/// wedged main thread must not be able to stop an expiry), so the state a
/// resolution reconciles from is not main-actor-confined in the first place.
public actor DisplayReconfigurationGate {
  private var claimant: ReconfigurationClaimant?

  public init() {}

  /// Who holds the gate. Exists for test assertions — the app names a holder
  /// from `ReconfigurationClaimOutcome.refusedBy` instead.
  public var holder: ReconfigurationClaimant? { claimant }

  /// Takes the gate for `claimant`, or refuses and names the holder.
  ///
  /// Called BEFORE the reconfiguration, never after: the point of a refusal is
  /// that nothing was applied, and a claim taken after the transaction has
  /// already been staged protects nobody.
  public func claim(_ claimant: ReconfigurationClaimant) -> ReconfigurationClaimOutcome {
    if let holder = self.claimant, holder != claimant {
      return .refused(by: holder)
    }
    self.claimant = claimant
    return .granted
  }

  /// Gives the gate back. A no-op when `claimant` is not the holder — including
  /// when nothing is held at all, which is the ordinary case for the
  /// unconditional call from a claimant's reconciliation funnel.
  public func release(_ claimant: ReconfigurationClaimant) {
    guard self.claimant == claimant else { return }
    self.claimant = nil
  }
}
