import Foundation

/// The things in this app that reconfigure displays, and therefore the things
/// that must not do it at the same time.
///
/// **Four cases, not three.** All four open a
/// `CGBeginDisplayConfiguration`-shaped transaction or its `SkyLight` equivalent,
/// and all four leave an unanswered preview standing for up to thirty seconds.
/// The pairing the fourth case exists for is the least obvious one: a resolution
/// change during an arrangement preview alters the very tile sizes the layout was
/// computed from, so the layout on screen stops being the layout that was asked
/// about.
///
/// `CaseIterable` so the exclusion suite enumerates every ordered pair rather than
/// listing them by hand, which makes a case added without a test tested anyway.
public enum ReconfigurationClaimant: String, Sendable, CaseIterable {
  case displayModes
  case mirroring
  case rotation
  case arrangement
}

/// The gate's whole answer. `.refused` names the holder rather than saying "no",
/// because every surface that reports one has to finish the sentence: "finish the
/// resolution change first" is actionable and "busy" is not.
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

/// At most one display reconfiguration is outstanding at a time.
///
/// **The decision lives here, in the engine, because there is no app test
/// target.** An exclusion rule that only exists as `if` statements spread across
/// four `@MainActor` coordinators cannot be tested at all, and the failure it
/// guards against, a stranded claim, deadlocks every display feature in the app at
/// once. What stays in the app target is the wiring: who claims, when, and what
/// the refusal says.
///
/// ## What it guarantees
///
/// - One holder. A second claimant is refused and told who holds it.
/// - **A claimant is never refused its own claim.** Superseding is supported in
///   three of the four (`ModePreviewSession.begin` on a second display ends the
///   first display's preview), so a gate that refused the holder would break the
///   feature it is protecting, silently.
/// - **A claimant can only release its own claim.** Without that check, the
///   release at the end of one feature's operation frees the claim another
///   feature took while it ran, which is the interleave the gate exists to
///   prevent, and it would fail open invisibly.
/// - Releasing is idempotent and safe when nothing is held, so the caller that
///   releases can do it unconditionally.
///
/// ## What it does NOT guarantee
///
/// **It cannot detect a holder that has stopped running.** A liveness probe would
/// have to call back onto the main actor, and main-actor work here is starved for
/// the whole of a menu-tracking session; a gate that wedges when the main thread
/// wedges is worse than no gate. The obligation sits on the claimant and is
/// discharged structurally rather than by discipline: **every claimant releases
/// from the same funnel that writes its preview state** (`adopt`, documented in
/// all four coordinators as the only writer of `preview`). A claim is then a
/// projection of "something is outstanding", and the paths that end a preview
/// without anyone answering it (a failed `begin`, an expiry, a display departing
/// mid-hold) all run through that funnel already.
///
/// An actor rather than a `@MainActor` type even though all four claimants are
/// main-actor coordinators: the countdown drivers are deliberately detached so a
/// wedged main thread cannot stop an expiry, which means the state a resolution
/// reconciles from is not main-actor-confined in the first place.
public actor DisplayReconfigurationGate {
  private var claimant: ReconfigurationClaimant?

  public init() {}

  /// Who holds the gate. Exists for test assertions; the app names a holder from
  /// `ReconfigurationClaimOutcome.refusedBy` instead.
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

  /// Gives the gate back. A no-op when `claimant` is not the holder, including
  /// when nothing is held at all, the ordinary case for the unconditional call
  /// from a claimant's reconciliation funnel.
  public func release(_ claimant: ReconfigurationClaimant) {
    guard self.claimant == claimant else { return }
    self.claimant = nil
  }
}
