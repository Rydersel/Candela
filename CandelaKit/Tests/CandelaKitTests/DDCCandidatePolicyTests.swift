import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Who is allowed to enter DDC service matching. A display Candela created never enters
/// the pool, and that has to hold whoever calls and on hardware nobody has attached,
/// which is why it is a pure policy rather than a clause inside `discover()`.
@Suite("DDC candidate pool")
struct DDCCandidatePolicyTests {
  private func candidates(
    _ online: [CGDirectDisplayID],
    builtIn: Set<CGDirectDisplayID> = [1],
    owned: Set<CGDirectDisplayID> = [],
    virtual virtualVerdicts: [CGDirectDisplayID: Bool?] = [:]
  ) -> [CGDirectDisplayID] {
    DDCCandidatePolicy.candidates(
      online: online,
      isBuiltIn: { builtIn.contains($0) },
      ownedVirtualIDs: owned,
      isForeignVirtual: { virtualVerdicts[$0] ?? nil }
    )
  }

  private func classify(
    _ online: [CGDirectDisplayID],
    builtIn: Set<CGDirectDisplayID> = [1],
    owned: Set<CGDirectDisplayID> = [],
    virtual virtualVerdicts: [CGDirectDisplayID: Bool?] = [:]
  ) -> (candidates: [CGDirectDisplayID], excluded: [(CGDirectDisplayID, DisplayExclusionReason)]) {
    DDCCandidatePolicy.classify(
      online: online,
      isBuiltIn: { builtIn.contains($0) },
      ownedVirtualIDs: owned,
      isForeignVirtual: { virtualVerdicts[$0] ?? nil }
    )
  }

  /// `getServiceMatches` accepts any score >= 1, so a display we created could be handed
  /// a physical panel's IOAVService, leaving the real monitor with no DDC control.
  @Test func aDisplayCandelaCreatedNeverEntersThePool() {
    #expect(candidates([1, 2, 133], owned: [133]) == [2])
  }

  /// The same hazard from a display nobody in this process created: Sidecar,
  /// AirPlay, another app's dummy.
  @Test func aForeignVirtualDisplayNeverEntersThePool() {
    #expect(candidates([1, 2, 21], virtual: [21: true]) == [2])
  }

  /// nil is "don't know", and that means ordinary: a nil that excluded would stop DDC
  /// working on real monitors the moment CoreDisplay renamed a key.
  @Test func anUnknownKindIsTreatedAsAnOrdinaryPanel() {
    #expect(candidates([1, 2], virtual: [2: nil]) == [2])
  }

  @Test func theBuiltInIsNeverACandidate() {
    #expect(candidates([1]) == [])
  }

  /// Order is load-bearing: within one score bucket `getServiceMatches` picks the winner
  /// by enumeration order, so the pool must preserve the online list's order.
  @Test func theOnlineListsOrderSurvivesFiltering() {
    #expect(candidates([1, 9, 4, 7], owned: [4]) == [9, 7])
  }

  /// Ownership outranks the predicate in both directions: a display we
  /// created is excluded even when the private key says nothing about it.
  @Test func ownershipDoesNotDependOnThePrivatePredicateAnswering() {
    #expect(candidates([1, 133], owned: [133], virtual: [133: nil]) == [])
  }

  /// Every guard has to name the drop it made, in the order the displays were
  /// enumerated.
  @Test func everyDropRecordsWhyItHappened() {
    let dropped = classify([1, 133, 21, 2], owned: [133], virtual: [21: true]).excluded
    #expect(dropped.map(\.1) == [.builtIn, .ownedVirtual, .foreignVirtual])
    #expect(dropped.map(\.0) == [1, 133, 21])
  }

  /// A display can trip more than one guard. The reason is whichever guard
  /// `candidates` already reached first, so recording it cannot move the survivors.
  @Test func theFirstMatchingGuardNamesTheReason() {
    #expect(classify([1], builtIn: [1], owned: [1]).excluded.map(\.1) == [.builtIn])
  }

  /// `candidates` is `classify().candidates`, and this is what holds it there: the
  /// two answers cannot drift, and no display lands in neither list.
  @Test func classifyAndCandidatesCannotDisagree() {
    let fixtures: [(
      online: [CGDirectDisplayID], owned: Set<CGDirectDisplayID>, virtual: [CGDirectDisplayID: Bool?]
    )] = [
      ([1, 2, 133], [133], [:]),
      ([1, 2, 21], [], [21: true]),
      ([1, 2], [], [2: nil]),
      ([1], [], [:]),
      ([1, 9, 4, 7], [4], [:]),
      ([1, 133], [133], [133: nil]),
    ]
    for fixture in fixtures {
      let both = classify(fixture.online, owned: fixture.owned, virtual: fixture.virtual)
      #expect(both.candidates == candidates(fixture.online, owned: fixture.owned, virtual: fixture.virtual))
      #expect(both.candidates.count + both.excluded.count == fixture.online.count)
      #expect(Set(both.candidates + both.excluded.map(\.0)) == Set(fixture.online))
    }
  }
}
