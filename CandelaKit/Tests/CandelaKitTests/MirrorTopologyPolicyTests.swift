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
    ]))
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
  @Test func aLockedMemberIsNeverStagedButTheRestOfTheSetStillBreaks() {
    let topology = MirrorTopology([
      display(1, mirrors: 2, builtIn: true),
      display(2, inSet: true),
      display(3, mirrors: 2, always: true),
    ])
    #expect(MirrorTopologyPolicy.toggle(topology) == .disengage(changes: [
      MirrorChange(display: 1, master: kCGNullDirectDisplay),
      MirrorChange(display: 2, master: kCGNullDirectDisplay),
    ]))
  }

  /// T5. A laptop plus an always-mirrored receiver: two displays, nothing that
  /// can own a set.
  @Test func noEligibleMasterIsRefusedRatherThanForcedOntoTheBuiltIn() {
    let topology = MirrorTopology([display(1, builtIn: true), display(2, always: true)])
    #expect(MirrorTopologyPolicy.toggle(topology) == .refused(.noEligibleMaster))
  }

  /// A locked display is never OFFERED as a master either: it cannot own a set
  /// it cannot leave.
  @Test func aLockedDisplayIsNeverOfferedAsAMaster() {
    let topology = MirrorTopology([display(1, builtIn: true), display(2, always: true)])
    #expect(MirrorTopologyPolicy.engage(topology, master: 2) == .refused(.noEligibleMaster))
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
      ]))
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
    ]))
    #expect(MirrorTopologyPolicy.disengage(topology, containing: 4) == .disengage(changes: [
      MirrorChange(display: 3, master: kCGNullDirectDisplay),
      MirrorChange(display: 4, master: kCGNullDirectDisplay),
    ]))
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
