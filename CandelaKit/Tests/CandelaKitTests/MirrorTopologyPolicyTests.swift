import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Mirror toggle policy (DT13, DT14)")
struct MirrorTopologyPolicyTests {
  private func display(
    _ id: CGDirectDisplayID,
    mirrors: CGDirectDisplayID = kCGNullDirectDisplay,
    inSet: Bool = false,
    always: Bool = false,
    builtIn: Bool = false
  ) -> ConfiguredDisplay {
    MirrorFixtures.display(id, mirrors: mirrors, inSet: inSet, always: always, builtIn: builtIn)
  }

  /// Two independent mirror sets: 1 owns 2, and 3 owns 4. Nothing on this rig
  /// is locked, so every member is breakable.
  private var twoIndependentSets: MirrorTopology {
    MirrorTopology([
      display(1, inSet: true), display(2, mirrors: 1),
      display(3, inSet: true), display(4, mirrors: 3),
    ])
  }

  /// T1. Fork parity, and the reason it is a REASON and not a bare false: the
  /// key executor falls through to a plain brightness-down step on this refusal
  /// and on no other.
  @Test func oneDisplayRefusesWithTheReasonTheKeyPathFallsThroughOn() {
    let decision = MirrorTopologyPolicy.toggle(MirrorTopology([display(1, builtIn: true)]))
    #expect(decision == .refused(.onlyOneDisplay))
  }

  /// T4. The fork picks the first NON-built-in as master and makes the built-in
  /// a slave deliberately; the determinism (lowest id, not list order) is ours.
  @Test func togglingAnUnmirroredRigBuildsASetAroundTheLowestExternal() {
    let topology = MirrorTopology([display(1, builtIn: true), display(5), display(3)])
    #expect(MirrorTopologyPolicy.toggle(topology) == .engage(
      master: 3,
      changes: [
        MirrorChange(display: 1, master: 3),
        MirrorChange(display: 5, master: 3),
      ]
    ))
  }

  /// T2. There is no dissolve-the-set call: breaking a set is one null-master
  /// change per member, staged together.
  @Test func togglingAMirroredRigStagesOneNullMasterChangePerMember() {
    #expect(MirrorTopologyPolicy.toggle(MirrorFixtures.mirroredTrio) == .disengage(changes: [
      MirrorChange(display: 1, master: kCGNullDirectDisplay),
      MirrorChange(display: 2, master: kCGNullDirectDisplay),
      MirrorChange(display: 3, master: kCGNullDirectDisplay),
    ], residualMembers: []))
  }

  /// T3 — the defect this row exists for. `engageMirror` saw a locked display
  /// as "in a mirror set", staged a change that cannot succeed, discarded the
  /// return value and reported success; the next press took the same branch,
  /// forever. The toggle was permanently stuck off.
  @Test func aSetNobodyCanBreakIsRefusedWithItsMembersNamed() {
    let topology = MirrorTopology([
      display(1, mirrors: 2, always: true, builtIn: true),
      display(2, inSet: true, always: true),
    ])
    #expect(MirrorTopologyPolicy.toggle(topology) == .refused(.setCannotBeBroken([1, 2])))
  }

  /// A locked display inside an otherwise breakable set is skipped rather than
  /// staged: the change cannot succeed, and staging it would fail the whole
  /// transaction and break nothing at all.
  ///
  /// The break is therefore PARTIAL — 3 goes on mirroring 2, so 2 goes on being
  /// a master — and the decision has to say so. A caller reading this as a
  /// total break reports "mirroring off" over a set the user is still looking
  /// at.
  @Test func aLockedMemberIsNeverStagedAndTheSetItLeavesBehindIsNamed() {
    let topology = MirrorTopology([
      display(1, mirrors: 2, builtIn: true),
      display(2, inSet: true),
      display(3, mirrors: 2, always: true),
    ])
    #expect(MirrorTopologyPolicy.toggle(topology) == .disengage(
      changes: [
        MirrorChange(display: 1, master: kCGNullDirectDisplay),
        MirrorChange(display: 2, master: kCGNullDirectDisplay),
      ],
      residualMembers: [2, 3]
    ))
  }

  /// PRESS TWICE on the rig above — the T3 defect's second life. Once the
  /// partial break commits, the survivors are a master and a locked slave;
  /// every change that could be staged is a no-op, and "one change per
  /// breakable member" cheerfully stages the master alone: a transaction that
  /// commits `.success`, reports mirroring off, and changes nothing. Forever,
  /// since every later press takes the same branch.
  ///
  /// A set is broken by removing its SLAVES, so a set whose every slave is
  /// locked is refused with its members named — by BOTH paths.
  @Test func aSecondPressOnTheResidualSetRefusesRatherThanStagingANoOp() {
    let afterFirstPress = MirrorTopology([
      display(1, builtIn: true),
      display(2, inSet: true),
      display(3, mirrors: 2, always: true),
    ])
    #expect(MirrorTopologyPolicy.toggle(afterFirstPress)
      == .refused(.setCannotBeBroken([2, 3])))
    #expect(MirrorTopologyPolicy.disengage(afterFirstPress, containing: 3)
      == .refused(.setCannotBeBroken([2, 3])))
  }

  /// T5. A laptop plus an always-mirrored receiver: two displays, nothing that
  /// can own a set. `noEligibleMaster` is reachable from `toggle` ALONE — it is
  /// the automatic scan's answer, and the only refusal that speaks about the
  /// whole machine.
  @Test func noEligibleMasterIsRefusedRatherThanForcedOntoTheBuiltIn() {
    let topology = MirrorTopology([display(1, builtIn: true), display(2, always: true)])
    #expect(MirrorTopologyPolicy.toggle(topology) == .refused(.noEligibleMaster))
  }

  /// A locked display is never OFFERED as a master either: it cannot own a set
  /// it cannot leave. Its own refusal, not the machine-wide one — the fact is
  /// about the display the user pointed at.
  @Test func aLockedDisplayIsNeverOfferedAsAMaster() {
    let topology = MirrorTopology([display(1, builtIn: true), display(2, always: true)])
    #expect(MirrorTopologyPolicy.engage(topology, master: 2)
      == .refused(.masterIsAlwaysMirrored))
  }

  /// The branch that made `noEligibleMaster` a lie: the named master is
  /// perfectly eligible — the user picked the built-in and the built-in can own
  /// a set — and there is simply nothing left that may join it. "No display can
  /// be the mirror master" would be false about the very display they chose.
  @Test func anEligibleMasterWithNothingToMirrorIsRefusedForThatReasonNotForBeingIneligible() {
    let topology = MirrorTopology([display(1, builtIn: true), display(2, always: true)])
    #expect(MirrorTopologyPolicy.engage(topology, master: 1) == .refused(.nothingToMirror))
  }

  /// Naming a display that is not in the sample is its own answer. The
  /// alternative — "nothing can be the master" — describes the machine when the
  /// truth is about a display that left it.
  @Test func namingAMasterThatIsNotInTheSampleIsRefusedAsAbsent() {
    #expect(MirrorTopologyPolicy.engage(MirrorFixtures.unmirroredPair, master: 99)
      == .refused(.noSuchDisplay))
  }

  /// The UI's engage names its master. Unlike the hotkey's, it may name the
  /// built-in — that is the user asking for it by name.
  @Test func theUICanNameAnyEligibleMasterIncludingTheBuiltIn() {
    let topology = MirrorTopology([display(1, builtIn: true), display(2), display(3)])
    #expect(MirrorTopologyPolicy.engage(topology, master: 1) == .engage(
      master: 1,
      changes: [
        MirrorChange(display: 2, master: 1),
        MirrorChange(display: 3, master: 1),
      ]
    ))
  }

  @Test func disengagingNamesTheSetTheGivenDisplayBelongsTo() {
    #expect(MirrorTopologyPolicy.disengage(MirrorFixtures.mirroredTrio, containing: 3)
      == .disengage(changes: [
        MirrorChange(display: 1, master: kCGNullDirectDisplay),
        MirrorChange(display: 2, master: kCGNullDirectDisplay),
        MirrorChange(display: 3, master: kCGNullDirectDisplay),
      ], residualMembers: []))
  }

  /// The API's two break paths differ on PURPOSE and the difference is
  /// observable here: the hotkey is a panic button that clears the machine
  /// (fork parity — it iterated the whole online list), while the UI's button
  /// breaks the one set the user pointed at and leaves the other alone.
  @Test func theHotkeyClearsEverySetWhileTheUIBreaksOnlyTheOneNamed() {
    let topology = twoIndependentSets
    #expect(MirrorTopologyPolicy.toggle(topology) == .disengage(changes: [
      MirrorChange(display: 1, master: kCGNullDirectDisplay),
      MirrorChange(display: 2, master: kCGNullDirectDisplay),
      MirrorChange(display: 3, master: kCGNullDirectDisplay),
      MirrorChange(display: 4, master: kCGNullDirectDisplay),
    ], residualMembers: []))
    #expect(MirrorTopologyPolicy.disengage(topology, containing: 4) == .disengage(changes: [
      MirrorChange(display: 3, master: kCGNullDirectDisplay),
      MirrorChange(display: 4, master: kCGNullDirectDisplay),
    ], residualMembers: []))
  }

  /// The fourth refusal case, and why it is not `.setCannotBeBroken([])`: an
  /// empty payload would have the UI say "this set cannot be broken" about a
  /// display that is in no set at all. This sub-project exists to stop the app
  /// making false statements; a closed three-case enum is not worth one.
  @Test func aDisplayInNoSetIsRefusedAsSuchRatherThanAsAnUnbreakableSet() {
    #expect(MirrorTopologyPolicy.disengage(MirrorFixtures.unmirroredPair, containing: 2)
      == .refused(.notInASet))
    #expect(MirrorTopologyPolicy.disengage(MirrorFixtures.mirroredTrio, containing: 99)
      == .refused(.notInASet))
  }

  /// The UI's break path refuses a locked set for the same reason the hotkey
  /// does, and names the same members — the difference between the two paths is
  /// SCOPE, never leniency.
  @Test func theUIRefusesALockedSetWithItsMembersNamedJustAsTheHotkeyDoes() {
    let topology = MirrorTopology([
      display(1, mirrors: 2, always: true, builtIn: true),
      display(2, inSet: true, always: true),
    ])
    #expect(MirrorTopologyPolicy.disengage(topology, containing: 1)
      == .refused(.setCannotBeBroken([1, 2])))
  }

  /// A phantom master — a slave naming a display this sample does not contain,
  /// which a stale read or a filtered list (externals only, dropping a built-in
  /// master) both produce — is never staged. Task 3's transaction is
  /// all-or-nothing, so one impossible change would stop a set that CAN break
  /// from breaking at all.
  @Test func aSlaveWhoseMasterIsAbsentBreaksAloneRatherThanStagingThePhantom() {
    let topology = MirrorTopology([display(1, builtIn: true), display(2, mirrors: 9)])
    #expect(MirrorTopologyPolicy.disengage(topology, containing: 2) == .disengage(
      changes: [MirrorChange(display: 2, master: kCGNullDirectDisplay)],
      residualMembers: []
    ))
  }

  /// An empty sample is not a machine state — it is a topology read between a
  /// teardown and its callback — and it lands on the refusal the key path falls
  /// through on, which is the harmless answer for it.
  @Test func anEmptySampleRefusesLikeASingleDisplayRatherThanCrashing() {
    #expect(MirrorTopologyPolicy.toggle(MirrorTopology([])) == .refused(.onlyOneDisplay))
    #expect(MirrorTopologyPolicy.engage(MirrorTopology([]), master: 1)
      == .refused(.onlyOneDisplay))
  }

  /// The preview's revert path. The fallback is a TOPOLOGY, never a mode:
  /// `currentMode(for:)` on a slave reports the MASTER's geometry (measured,
  /// 3440x1440 -> 2580x1080) and may simply return nil.
  @Test func revertingComputesOnlyTheChangesThatDifferFromTheCapturedTopology() {
    let captured = MirrorFixtures.unmirroredPair
    let live = MirrorTopology([
      MirrorFixtures.display(1, mirrors: 2, builtIn: true),
      MirrorFixtures.display(2, inSet: true),
    ])
    #expect(MirrorTopologyPolicy.changes(from: live, to: captured)
      == [MirrorChange(display: 1, master: kCGNullDirectDisplay)])
  }

  /// A revert that has nothing to undo stages nothing — and Task 3's
  /// `applyMirroring` opens no transaction for an empty list, so this is a true
  /// no-op rather than a transaction that commits `.success` having done
  /// nothing.
  @Test func revertingToTheTopologyAlreadyLiveStagesNothing() {
    #expect(MirrorTopologyPolicy.changes(
      from: MirrorFixtures.mirroredTrio, to: MirrorFixtures.mirroredTrio
    ).isEmpty)
  }

  /// A display that arrived after the capture is not in it. Restoring it to
  /// "unmirrored" is the honest reading of a fallback that never described it —
  /// the alternative is leaving it mirrored to a set the user is undoing.
  @Test func aDisplayAbsentFromTheCapturedTopologyIsRestoredToUnmirrored() {
    let captured = MirrorTopology([MirrorFixtures.display(1, builtIn: true)])
    let live = MirrorTopology([
      MirrorFixtures.display(1, mirrors: 2, builtIn: true),
      MirrorFixtures.display(2, inSet: true),
    ])
    #expect(MirrorTopologyPolicy.changes(from: live, to: captured)
      == [MirrorChange(display: 1, master: kCGNullDirectDisplay)])
  }

  /// Revert is BEST EFFORT, and this is the shape of its shortfall: a locked
  /// display is skipped even though the capture says it was unmirrored, so the
  /// revert completes with 3 still mirroring 2. Deleting the filter would stage
  /// a change that cannot succeed and cancel the whole transaction — reverting
  /// nothing at all — so the shortfall is the better of the two, but it is a
  /// shortfall and a caller saying "restored" says more than it knows.
  @Test func revertingSkipsALockedDisplayAndThereforeLeavesItMirrored() {
    let captured = MirrorTopology([
      MirrorFixtures.display(1, builtIn: true), MirrorFixtures.display(2),
      MirrorFixtures.display(3),
    ])
    let live = MirrorTopology([
      MirrorFixtures.display(1, mirrors: 2, builtIn: true),
      MirrorFixtures.display(2, inSet: true),
      MirrorFixtures.display(3, mirrors: 2, always: true),
    ])
    #expect(MirrorTopologyPolicy.changes(from: live, to: captured)
      == [MirrorChange(display: 1, master: kCGNullDirectDisplay)])
  }

  /// A revert re-forms a set as readily as it breaks one: the capture is the
  /// truth, and the changes are whatever gets there. `id`-ascending, like every
  /// other list in this file.
  @Test func revertingIntoACapturedSetRestagesTheMembershipItRecorded() {
    let captured = MirrorFixtures.mirroredTrio
    let live = MirrorTopology([
      MirrorFixtures.display(1, builtIn: true),
      MirrorFixtures.display(2),
      MirrorFixtures.display(3),
    ])
    #expect(MirrorTopologyPolicy.changes(from: live, to: captured) == [
      MirrorChange(display: 1, master: 2),
      MirrorChange(display: 3, master: 2),
    ])
  }
}
