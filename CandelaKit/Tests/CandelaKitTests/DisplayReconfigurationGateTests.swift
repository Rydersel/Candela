import Foundation
import Testing
@testable import CandelaKit

/// The exclusion between reconfiguring features (AR12). The two cases nobody would
/// think to write are the ones that matter: a gate refusing the holder its own claim
/// breaks superseding, and a gate letting one claimant release another's fails open.
@Suite("Display reconfiguration gate (AR12)")
struct DisplayReconfigurationGateTests {
  /// Every ordered pair, generated rather than listed: a fifth claimant is
  /// covered the moment its case exists.
  private static var orderedPairs: [(ReconfigurationClaimant, ReconfigurationClaimant)] {
    ReconfigurationClaimant.allCases.flatMap { first in
      ReconfigurationClaimant.allCases.compactMap { second in
        first == second ? nil : (first, second)
      }
    }
  }

  @Test func theGateStartsFree() async {
    let gate = DisplayReconfigurationGate()
    #expect(await gate.holder == nil)
  }

  /// AR12's substance is the fourth claimant. Deleting the `arrangement` case
  /// would leave every other test here passing over a three-way gate.
  @Test func allFourReconfiguringFeaturesAreClaimants() {
    #expect(Set(ReconfigurationClaimant.allCases) == [
      .displayModes, .mirroring, .rotation, .arrangement,
    ])
  }

  /// The whole exclusion, in both directions, for every ordered pair.
  @Test(arguments: orderedPairs)
  func aHeldGateRefusesEveryOtherClaimantAndNamesTheHolder(
    holder: ReconfigurationClaimant, other: ReconfigurationClaimant
  ) async {
    let gate = DisplayReconfigurationGate()
    #expect(await gate.claim(holder) == .granted)
    #expect(await gate.claim(other) == .refused(by: holder))
    #expect(await gate.holder == holder)

    await gate.release(holder)
    #expect(await gate.claim(other) == .granted)
    #expect(await gate.claim(holder) == .refused(by: other))
  }

  /// A `begin` that threw applied nothing, so its claim has nothing to protect.
  /// Left held it wedges every other display feature for the rest of the session.
  @Test(arguments: orderedPairs)
  func aClaimIsReleasedWhenItsOwnersOperationFails(
    failing: ReconfigurationClaimant, next: ReconfigurationClaimant
  ) async {
    let gate = DisplayReconfigurationGate()
    #expect(await gate.claim(failing) == .granted)
    // The claimant's reconciliation funnel runs after a failed begin exactly as
    // it runs after a successful one, and reports that nothing is outstanding.
    await gate.release(failing)

    #expect(await gate.holder == nil)
    #expect(await gate.claim(next) == .granted)
  }

  /// The owner departs mid-hold, so nobody ever answers the question. No part of
  /// that path involves the user, so the release comes from the same reconciliation
  /// that noticed the departure.
  @Test(arguments: orderedPairs)
  func aClaimIsNotStrandedWhenItsOwnerDepartsMidHold(
    departing: ReconfigurationClaimant, next: ReconfigurationClaimant
  ) async {
    let gate = DisplayReconfigurationGate()
    #expect(await gate.claim(departing) == .granted)
    await gate.release(departing)

    #expect(await gate.holder == nil)
    #expect(await gate.claim(next) == .granted)
    #expect(await gate.claim(departing) == .refused(by: next))
  }

  /// Superseding is supported for most claimants: a mode `begin` on a second
  /// display, a mirror break over an outstanding engage, a second drag during an
  /// arrangement preview. Refusing the holder its own claim looks like a dead click.
  @Test func theHolderIsNeverRefusedItsOwnClaim() async {
    let gate = DisplayReconfigurationGate()
    #expect(await gate.claim(.arrangement) == .granted)
    #expect(await gate.claim(.arrangement) == .granted)
    #expect(await gate.holder == .arrangement)
  }

  /// The re-entrant grant does NOT nest: one release frees the gate however many
  /// times it was claimed, so an operation that finishes hands back a claim another
  /// operation of the same claimant still relies on. Live, not theoretical:
  /// `.displayModes` covers both the mode picker and the synthesis engine. Hence one
  /// releasing funnel per claimant, releasing only when nothing it owns is outstanding.
  @Test func aSecondClaimByTheSameClaimantDoesNotNest() async {
    let gate = DisplayReconfigurationGate()
    #expect(await gate.claim(.displayModes) == .granted)
    #expect(await gate.claim(.displayModes) == .granted)

    await gate.release(.displayModes)

    #expect(await gate.holder == nil)
    #expect(await gate.claim(.arrangement) == .granted)
  }

  /// The fail-open case. A release that did not check who is holding would hand
  /// the gate to whoever calls it next, which is the interleave the gate exists
  /// to prevent — and it would do it with every surface still reporting success.
  @Test(arguments: orderedPairs)
  func oneClaimantCannotReleaseAnothersClaim(
    holder: ReconfigurationClaimant, other: ReconfigurationClaimant
  ) async {
    let gate = DisplayReconfigurationGate()
    #expect(await gate.claim(holder) == .granted)

    await gate.release(other)

    #expect(await gate.holder == holder)
    #expect(await gate.claim(other) == .refused(by: holder))
  }

  /// Callers release unconditionally from a funnel that runs on every state
  /// change, so most releases are made while holding nothing.
  @Test func releasingIsIdempotentAndSafeWhenNothingIsHeld() async {
    let gate = DisplayReconfigurationGate()
    await gate.release(.rotation)
    await gate.release(.rotation)
    #expect(await gate.holder == nil)

    #expect(await gate.claim(.rotation) == .granted)
    await gate.release(.rotation)
    await gate.release(.rotation)
    #expect(await gate.holder == nil)
    #expect(await gate.claim(.mirroring) == .granted)
  }

  /// A late release from a claimant's previous operation must not free the claim
  /// somebody else took in between: two queued operations, the first one's
  /// reconciliation landing after the second claimant is in.
  @Test func aLateReleaseFromAPreviousOperationDoesNotFreeTheNewHolder() async {
    let gate = DisplayReconfigurationGate()
    #expect(await gate.claim(.displayModes) == .granted)
    await gate.release(.displayModes)
    #expect(await gate.claim(.arrangement) == .granted)

    await gate.release(.displayModes)

    #expect(await gate.holder == .arrangement)
    #expect(await gate.claim(.mirroring) == .refused(by: .arrangement))
  }

  /// Every claimant racing for the gate from its own task: one is granted and the
  /// rest are refused by that same one. The only test that exercises the actor's
  /// serialisation.
  @Test func concurrentClaimsGrantExactlyOne() async {
    let gate = DisplayReconfigurationGate()
    let outcomes = await withTaskGroup(of: ReconfigurationClaimOutcome.self) { group in
      for claimant in ReconfigurationClaimant.allCases {
        group.addTask { await gate.claim(claimant) }
      }
      return await group.reduce(into: [ReconfigurationClaimOutcome]()) { $0.append($1) }
    }

    #expect(outcomes.filter(\.isGranted).count == 1)
    let holder = await gate.holder
    #expect(holder != nil)
    #expect(outcomes.compactMap(\.refusedBy).allSatisfy { $0 == holder })
    #expect(outcomes.compactMap(\.refusedBy).count == 3)
  }
}
