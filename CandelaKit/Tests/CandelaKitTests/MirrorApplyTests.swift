import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Batch mirror application (DT11)")
struct MirrorApplyTests {
  /// Rule 4. An empty transaction would commit `.success` having changed
  /// nothing — the same silent no-op a discarded staged return produces,
  /// arrived at from the other end. Safe to run on this machine: it opens no
  /// transaction at all.
  @Test func anEmptyChangeListOpensNoTransactionAndDoesNotThrow() throws {
    try CoreGraphicsDisplayConfigurator().applyMirroring([], scope: .session)
  }

  /// Rule 2, against the real CoreGraphics. Staging a change for a display ID
  /// that does not exist must THROW rather than commit an empty configuration
  /// and report success.
  ///
  /// Safe on this machine, deliberately: the single staged change names a
  /// nonexistent ID with a NULL master, so even in the impossible case where
  /// both the stage and the commit succeeded, nothing attached is
  /// reconfigured. The scope is `.preview` (`kCGConfigureForAppOnly`) for the
  /// same belt-and-braces reason every harness uses it.
  @Test func stagingAChangeForANonexistentDisplayThrowsRatherThanSilentlySucceeding() {
    let configurator = CoreGraphicsDisplayConfigurator()
    #expect(throws: DisplayConfigError.self) {
      try configurator.applyMirroring(
        [MirrorChange(display: 0xDEAD_BEEF, master: kCGNullDirectDisplay)],
        scope: .preview
      )
    }
  }

  /// The fake is the test double every later suite applies mirroring through,
  /// so its contract is pinned here: changes arrive as ONE batch, in order,
  /// with the scope they were asked for.
  @Test func theFakeRecordsOneBatchInOrderWithItsScope() throws {
    let fake = FakeConfigurator()
    try fake.applyMirroring(
      [MirrorChange(display: 1, master: 2), MirrorChange(display: 3, master: 2)],
      scope: .preview
    )
    #expect(fake.appliedMirroring == [
      .init(
        changes: [MirrorChange(display: 1, master: 2), MirrorChange(display: 3, master: 2)],
        scope: .preview
      ),
    ])
  }

  /// A failed transaction records nothing: the caller has to be able to tell
  /// "the mirror did not change" from "the mirror changed and we lost track".
  @Test func aFailedTransactionRecordsNothing() {
    let fake = FakeConfigurator()
    fake.failMirroringWith = DisplayConfigError(cgErrorCode: 1001)
    #expect(throws: DisplayConfigError(cgErrorCode: 1001)) {
      try fake.applyMirroring([MirrorChange(display: 1, master: 2)], scope: .session)
    }
    #expect(fake.appliedMirroring.isEmpty)
  }

  /// Rule 1 stated as a recorded fact rather than as an absence: N changes make
  /// ONE entry, not N. If a later refactor ever loops the transaction per
  /// display, this is the test that notices — a half-broken mirror set is
  /// exactly what the batch shape exists to keep inexpressible.
  @Test func breakingASetOfThreeIsOneTransactionNotThree() throws {
    let fake = FakeConfigurator()
    let breakAll = [
      MirrorChange(display: 1, master: kCGNullDirectDisplay),
      MirrorChange(display: 2, master: kCGNullDirectDisplay),
      MirrorChange(display: 3, master: kCGNullDirectDisplay),
    ]
    try fake.applyMirroring(breakAll, scope: .session)
    #expect(fake.appliedMirroring.count == 1)
    #expect(fake.appliedMirroring.first?.changes == breakAll)
  }

  /// The fake's topology has to FOLLOW the change, or every later revert-path
  /// test is tautological: a session that captures, applies, then re-reads
  /// `displays()` would see the capture again and "prove" a revert that never
  /// had anything to undo.
  @Test func theFakesTopologyFollowsTheChangeSoRevertTestsAreNotTautological() throws {
    let fake = FakeConfigurator()
    fake.configuredDisplays = [
      ConfiguredDisplay(id: 1, identity: .init(vendor: 1, model: 1, serial: 1, isBuiltIn: true),
                        name: "Built-in Display", isBuiltIn: true),
      ConfiguredDisplay(id: 2, identity: .init(vendor: 2, model: 2, serial: 2, isBuiltIn: false),
                        name: "Display 2", isBuiltIn: false),
    ]
    try fake.applyMirroring([MirrorChange(display: 2, master: 1)], scope: .session)

    let live = MirrorTopology(fake.displays())
    #expect(live.master(of: 2) == 1)
    #expect(live.masters == [1])
    #expect(live.slaves(of: 1) == [2])

    // And back: a null master removes it from the set on both sides.
    try fake.applyMirroring([MirrorChange(display: 2, master: kCGNullDirectDisplay)], scope: .session)
    let after = MirrorTopology(fake.displays())
    #expect(after.master(of: 2) == nil)
    #expect(after.masters.isEmpty)
    #expect(after.displays.allSatisfy { !$0.isInMirrorSet })
  }

  /// Rule 4 on the fake as well as on the real thing. An empty batch that
  /// recorded an entry would let a test assert "mirroring was applied" about a
  /// transaction that staged nothing — the silent no-op wearing a receipt.
  @Test func anEmptyBatchRecordsNothingOnTheFakeEither() throws {
    let fake = FakeConfigurator()
    try fake.applyMirroring([], scope: .session)
    #expect(fake.appliedMirroring.isEmpty)
  }

  /// The fake must not be able to fail where production cannot.
  /// `CoreGraphicsDisplayConfigurator.applyMirroring` returns on its empty-batch
  /// guard BEFORE it reaches anything that can fail, so an empty batch cannot
  /// throw no matter what CoreGraphics would have done.
  ///
  /// The fake has an injection point production does not, and if it were
  /// checked first, an empty batch WOULD throw. That is not a theoretical
  /// asymmetry: `MirrorTopologyPolicy.changes(from:to:)` returns `[]` whenever
  /// the live topology already matches the capture — the common case on a
  /// revert — so a session test that set `failMirroringWith` and drove a revert
  /// would exercise, and then enshrine, a "revert failed" branch unreachable in
  /// shipped code.
  @Test func anEmptyBatchCannotFailEvenWithFailureInjected() throws {
    let fake = FakeConfigurator()
    fake.failMirroringWith = DisplayConfigError(cgErrorCode: 1001)
    try fake.applyMirroring([], scope: .session)
    #expect(fake.appliedMirroring.isEmpty)
    // Still armed for a batch that actually stages something.
    #expect(throws: DisplayConfigError(cgErrorCode: 1001)) {
      try fake.applyMirroring([MirrorChange(display: 1, master: 2)], scope: .session)
    }
  }

  /// The fake computes MASTER membership itself; a SLAVE gets
  /// `isInMirrorSet == true` only because `ConfiguredDisplay.init` ORs in
  /// `mirrorsDisplay != kCGNullDirectDisplay`. That is a real dependency on
  /// another type's derivation, and nothing else asserts it — so without this
  /// test, deleting that OR would leave the fake reporting every slave as
  /// outside the set it is plainly in, with the whole suite still green.
  ///
  /// `setMembers(containing:)` is asserted from BOTH ends because it is the
  /// predicate `MirrorTopologyPolicy.disengage` breaks a set with: asked about
  /// the slave or about the master, one set, same members.
  @Test func theFakeReportsSlaveMembershipAndSetMembersLikeCoreGraphicsDoes() throws {
    let fake = FakeConfigurator()
    fake.configuredDisplays = [
      ConfiguredDisplay(id: 1, identity: .init(vendor: 1, model: 1, serial: 1, isBuiltIn: true),
                        name: "Built-in Display", isBuiltIn: true),
      ConfiguredDisplay(id: 2, identity: .init(vendor: 2, model: 2, serial: 2, isBuiltIn: false),
                        name: "Display 2", isBuiltIn: false),
      ConfiguredDisplay(id: 3, identity: .init(vendor: 3, model: 3, serial: 3, isBuiltIn: false),
                        name: "Display 3", isBuiltIn: false),
    ]
    try fake.applyMirroring(
      [MirrorChange(display: 2, master: 1), MirrorChange(display: 3, master: 1)],
      scope: .session
    )

    let live = MirrorTopology(fake.displays())
    let slaves = live.displays.filter { $0.id == 2 || $0.id == 3 }
    // The rig read exactly this off real CoreGraphics: inMirrorSet=1 on the
    // slave while engaged, 0 after the break.
    // Closure form, not `allSatisfy(\.isInMirrorSet)`: the `#expect` macro
    // decomposes a function call into a `rethrows` invocation whose argument it
    // cannot prove non-throwing, so the keypath spelling does not compile.
    #expect(slaves.allSatisfy { $0.isInMirrorSet })
    #expect(slaves.allSatisfy { $0.isMirrorSlave })
    #expect(slaves.allSatisfy { !$0.isMirrorMaster })
    #expect(live.setMembers(containing: 2) == [1, 2, 3])
    #expect(live.setMembers(containing: 1) == [1, 2, 3])

    try fake.applyMirroring(
      [MirrorChange(display: 2, master: kCGNullDirectDisplay),
       MirrorChange(display: 3, master: kCGNullDirectDisplay)],
      scope: .session
    )
    let after = MirrorTopology(fake.displays())
    #expect(after.displays.allSatisfy { !$0.isInMirrorSet })
    #expect(after.setMembers(containing: 2).isEmpty)
    #expect(after.setMembers(containing: 1).isEmpty)
  }
}
