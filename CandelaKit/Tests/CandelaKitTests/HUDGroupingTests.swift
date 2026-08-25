import CoreGraphics
import Testing
@testable import CandelaKit

@Suite("HUD grouping for stepped displays (#123)")
struct HUDGroupingTests {
  /// The defect itself. `expand(2)` hands the executor `[2, 1, 3]`; every one
  /// of those draws on 2, so one pill appears. Before this it was written three
  /// times and display 3 won, because it sorted last.
  @Test func aSteppedMirrorSetProducesOnePillNamedForTheDisplayItIsDrawnOn() {
    let pills = HUDGrouping.pills(
      forStepped: MirrorFixtures.mirroredTrio.expand(2),
      topology: MirrorFixtures.mirroredTrio
    )
    #expect(pills == [HUDGrouping.Pill(placement: 2, named: 2, othersInSet: 2)])
  }

  /// The name must not depend on the order the members arrive in, which is the
  /// only thing that decided it before.
  @Test func theNameDoesNotDependOnIterationOrder() {
    let topology = MirrorFixtures.mirroredTrio
    let forward = HUDGrouping.pills(forStepped: [2, 1, 3], topology: topology)
    let reversed = HUDGrouping.pills(forStepped: [3, 1, 2], topology: topology)
    #expect(forward == reversed)
    #expect(forward.first?.named == 2)
  }

  /// A two-member set is the same rule, and the count says one other moved.
  @Test func aTwoMemberSetNamesTheMasterAndCountsTheOther() {
    let topology = MirrorTopology([
      MirrorFixtures.display(2, inSet: true),
      MirrorFixtures.display(3, mirrors: 2),
    ])
    #expect(
      HUDGrouping.pills(forStepped: [2, 3], topology: topology)
        == [HUDGrouping.Pill(placement: 2, named: 2, othersInSet: 1)]
    )
  }

  /// Unmirrored displays keep one pill each, named for themselves, in the order
  /// they were stepped. This is the `.allExternal` and `.allScreens` shape, and
  /// the behaviour that must not change.
  @Test func unmirroredDisplaysEachKeepTheirOwnPill() {
    #expect(
      HUDGrouping.pills(forStepped: [2, 1], topology: MirrorFixtures.unmirroredPair)
        == [
          HUDGrouping.Pill(placement: 2, named: 2, othersInSet: 0),
          HUDGrouping.Pill(placement: 1, named: 1, othersInSet: 0),
        ]
    )
  }

  /// A single stepped slave still draws on its master, and still names ITSELF:
  /// one display moved, and saying so is the honest reading. That was already
  /// true and is what the fix must not trade away to fix the set case.
  @Test func aLoneSteppedSlaveIsDrawnOnItsMasterAndNamesItself() {
    #expect(
      HUDGrouping.pills(forStepped: [3], topology: MirrorFixtures.mirroredTrio)
        == [HUDGrouping.Pill(placement: 2, named: 3, othersInSet: 0)]
    )
  }

  /// The placement display did not move, so naming it would report a step that
  /// never happened. Reachable when a master has media keys disabled (R1
  /// swallows its press) while its slaves do not.
  @Test func aPillFallsBackToASteppedMemberWhenThePlacementDisplayDidNotMove() {
    #expect(
      HUDGrouping.pills(forStepped: [1, 3], topology: MirrorFixtures.mirroredTrio)
        == [HUDGrouping.Pill(placement: 2, named: 1, othersInSet: 1)]
    )
  }

  /// The count must survive a display arriving twice. `.allScreens` assembles
  /// its list from two step paths, and a duplicate would report a set one
  /// larger than the one the user is looking at.
  @Test func aRepeatedDisplayIsCountedOnce() {
    #expect(
      HUDGrouping.pills(forStepped: [2, 2], topology: MirrorFixtures.unmirroredPair)
        == [HUDGrouping.Pill(placement: 2, named: 2, othersInSet: 0)]
    )
  }

  // MARK: - Synthesis sets (SS1)

  /// A synthesized size is ONE panel as far as the person pressing the key is
  /// concerned. The pill still has to be drawn on the virtual display, which
  /// owns the framebuffer and is the only member with a screen, but it must
  /// name the panel and count nothing: "+ 1 more" would announce a display
  /// nobody can look at, created by the app to serve the size.
  @Test func aSynthesisSetNamesThePanelAndCountsNoOtherMembers() {
    let topology = MirrorFixtures.synthesisPair()
    #expect(
      HUDGrouping.pills(forStepped: topology.expand(5), topology: topology)
        == [HUDGrouping.Pill(placement: 5, named: 2, othersInSet: 0)]
    )
  }

  /// The realistic shape: only the panel steps, because the virtual display has
  /// no controller and takes no DDC. The answer must be the same one, so the
  /// pill does not change identity depending on which members the step path
  /// happened to resolve.
  @Test func aSynthesisPanelSteppingAloneGivesTheSamePill() {
    let topology = MirrorFixtures.synthesisPair()
    #expect(
      HUDGrouping.pills(forStepped: [2], topology: topology)
        == [HUDGrouping.Pill(placement: 5, named: 2, othersInSet: 0)]
    )
  }

  /// The carve-out is not the CG flags: a virtual master that reports no mirror
  /// flag at all is still a synthesis master, because the pairing says so.
  @Test func theSynthesisPillDoesNotDependOnTheMasterReportingMirrorFlags() {
    let topology = MirrorFixtures.synthesisPair(masterReportsFlags: false)
    #expect(
      HUDGrouping.pills(forStepped: [5, 2], topology: topology)
        == [HUDGrouping.Pill(placement: 5, named: 2, othersInSet: 0)]
    )
  }

  /// Only the synthesis master is discounted, never a real panel. A second
  /// display genuinely showing the same framebuffer is one the user CAN look
  /// at, so it is counted exactly as it would be in any other set.
  @Test func aSecondPanelInASynthesisSetIsStillCounted() {
    let topology = MirrorTopology(
      [
        MirrorFixtures.display(2, mirrors: 5),
        MirrorFixtures.display(3, mirrors: 5),
        MirrorFixtures.display(5, inSet: true),
      ],
      synthesisMasters: [5]
    )
    #expect(
      HUDGrouping.pills(forStepped: [5, 2, 3], topology: topology)
        == [HUDGrouping.Pill(placement: 5, named: 2, othersInSet: 1)]
    )
  }

  /// A mirror set the user built keeps naming its master and counting its
  /// members, on a machine that also has a synthesis set engaged. The carve-out
  /// is per set, not per machine.
  @Test func aUserMirrorSetIsUntouchedByTheSynthesisCarveOut() {
    let topology = MirrorTopology(
      [
        MirrorFixtures.display(2, inSet: true),
        MirrorFixtures.display(3, mirrors: 2),
        MirrorFixtures.display(4, mirrors: 5),
        MirrorFixtures.display(5, inSet: true),
      ],
      synthesisMasters: [5]
    )
    #expect(
      HUDGrouping.pills(forStepped: [2, 3], topology: topology)
        == [HUDGrouping.Pill(placement: 2, named: 2, othersInSet: 1)]
    )
  }

  @Test func anEmptyStepProducesNoPills() {
    #expect(HUDGrouping.pills(forStepped: [], topology: MirrorFixtures.unmirroredPair).isEmpty)
  }

  @Test func theSuffixCarriesHDRAndTheSetCountTogetherOrNeither() {
    #expect(HUDGrouping.nameSuffix(isHDREngaged: false, othersInSet: 0) == nil)
    #expect(HUDGrouping.nameSuffix(isHDREngaged: true, othersInSet: 0) == " · HDR")
    #expect(HUDGrouping.nameSuffix(isHDREngaged: false, othersInSet: 2) == " + 2 more")
    #expect(HUDGrouping.nameSuffix(isHDREngaged: true, othersInSet: 1) == " · HDR + 1 more")
  }
}
