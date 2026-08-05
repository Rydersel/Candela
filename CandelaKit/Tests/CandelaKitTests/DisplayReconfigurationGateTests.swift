import Foundation
import Testing
@testable import CandelaKit

/// The four-way exclusion (AR12).
///
/// Every test here has a mutation that makes it fail, and the two that matter
/// most are the ones nobody would think to write: a gate that refuses the holder
/// its own claim breaks superseding, and a gate that lets one claimant release
/// another's claim fails OPEN — both silently.
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

  /// The whole exclusion, in both directions, for all twelve ordered pairs.
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

  /// A `begin` that threw applied nothing, so the claim taken a moment earlier
  /// has nothing to protect. Left held it would wedge every OTHER display
  /// feature for the rest of the session — the deadlock this type is most
  /// dangerous without.
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

  /// The owner departs mid-hold: the display set changed, the session dropped
  /// its preview, and nobody ever answered the question. Nothing about that path
  /// involves the user, so nothing about it can involve a button — the release
  /// has to come from the same reconciliation that noticed the departure.
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

  /// Superseding is a supported operation in three of the four claimants — a
  /// mode `begin` on a second display, a mirror break over an outstanding
  /// engage, a second drag during an arrangement preview. Refusing the holder
  /// its own claim would break all three, and would look like the feature
  /// ignoring a click.
  @Test func theHolderIsNeverRefusedItsOwnClaim() async {
    let gate = DisplayReconfigurationGate()
    #expect(await gate.claim(.arrangement) == .granted)
    #expect(await gate.claim(.arrangement) == .granted)
    #expect(await gate.holder == .arrangement)
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

  /// A late release from a claimant's PREVIOUS operation must not free the claim
  /// somebody else took in between. The identity check is what makes that true,
  /// and this is the ordering it actually happens in: two queued operations, the
  /// first one's reconciliation landing after the second claimant is in.
  @Test func aLateReleaseFromAPreviousOperationDoesNotFreeTheNewHolder() async {
    let gate = DisplayReconfigurationGate()
    #expect(await gate.claim(.displayModes) == .granted)
    await gate.release(.displayModes)
    #expect(await gate.claim(.arrangement) == .granted)

    await gate.release(.displayModes)

    #expect(await gate.holder == .arrangement)
    #expect(await gate.claim(.mirroring) == .refused(by: .arrangement))
  }

  /// Four claimants racing for the gate from four tasks: exactly one is granted
  /// and the other three are refused by that same one. The serialisation is the
  /// actor's, and this is the only test that exercises it.
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
