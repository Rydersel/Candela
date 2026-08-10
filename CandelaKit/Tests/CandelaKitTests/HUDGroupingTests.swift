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
