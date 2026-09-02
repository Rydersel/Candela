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
}
