import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Fixtures for a topology. Shared by both mirror suites: the policy tests
/// reason about the same shapes these pin.
enum MirrorFixtures {
  static func display(
    _ id: CGDirectDisplayID,
    mirrors: CGDirectDisplayID = kCGNullDirectDisplay,
    inSet: Bool = false,
    always: Bool = false,
    builtIn: Bool = false
  ) -> ConfiguredDisplay {
    ConfiguredDisplay(
      id: id,
      identity: DisplayConfigIdentity(vendor: 1, model: 2, serial: id, isBuiltIn: builtIn),
      name: builtIn ? "Built-in Display" : "Display \(id)",
      isBuiltIn: builtIn,
      mirrorsDisplay: mirrors,
      isInMirrorSet: inSet,
      isAlwaysInMirrorSet: always
    )
  }

  /// Built-in 1 (standalone) + external 2 (standalone). The rig the hotkey sees
  /// on a laptop with one monitor plugged in.
  static var unmirroredPair: MirrorTopology {
    MirrorTopology([display(1, builtIn: true), display(2)])
  }

  /// External 2 is the master; the built-in 1 and external 3 mirror it. This is
  /// what the fork's toggle produces — it picks the first non-built-in as
  /// master and makes the built-in a slave, deliberately.
  static var mirroredTrio: MirrorTopology {
    MirrorTopology([
      display(1, mirrors: 2, builtIn: true),
      display(2, inSet: true),
      display(3, mirrors: 2),
    ])
  }

  /// What a synthesis engage leaves behind: physical panel 2 showing virtual
  /// display 5's framebuffer, with the engine's pairing naming 5 as a synthesis
  /// master.
  ///
  /// `masterReportsFlags` is the Phase 0 (c) measurement: the rig's VD master
  /// DOES report `CGDisplayIsInMirrorSet`. SS1 requires the pairing to be the
  /// authority anyway, so `false` is the case that has to work too.
  static func synthesisPair(masterReportsFlags: Bool = true) -> MirrorTopology {
    MirrorTopology(
      [display(1, builtIn: true), display(2, mirrors: 5), display(5, inSet: masterReportsFlags)],
      synthesisMasters: [5]
    )
  }
}

/// `Result<Void, _>` is not `Equatable` — `Void` isn't — so the failures of the
/// preview sessions' `begin` are compared through their error rather than as
/// whole results. Unconstrained in its success type because
/// `ArrangementPreviewSession.begin` returns the value it staged, and a failure
/// is read the same way whatever the success would have carried.
///
/// File-internal rather than `private`, and living here rather than in any one
/// session's suite, because all THREE preview-session suites need it. `private`
/// at file scope is invisible to the other files, and a second copy is a second
/// thing to get wrong.
extension Result where Failure == DisplayConfigError {
  var failureError: DisplayConfigError? {
    if case let .failure(error) = self { return error }
    return nil
  }
}

@Suite("Mirror topology reconstruction (DT13)")
struct MirrorTopologyTests {
  @Test func aSetIsReconstructedByGroupingOnTheMasterEachSlaveNames() {
    let topology = MirrorFixtures.mirroredTrio
    #expect(topology.masters == [2])
    #expect(topology.slaves(of: 2) == [1, 3])
    #expect(topology.master(of: 1) == 2)
    #expect(topology.master(of: 2) == nil)
    #expect(topology.setMembers(containing: 3) == [1, 2, 3])
  }

  @Test func anUnmirroredRigHasNoMastersAndNoSets() {
    let topology = MirrorFixtures.unmirroredPair
    #expect(topology.masters.isEmpty)
    #expect(topology.slaves(of: 2).isEmpty)
    #expect(topology.master(of: 2) == nil)
    #expect(topology.setMembers(containing: 2).isEmpty)
  }

  /// What the key path steps: a master expands to its set so every member gets
  /// the same brightness step, and anything else expands to itself.
  @Test func expandingAMasterYieldsTheWholeSetAndAnythingElseYieldsItself() {
    let topology = MirrorFixtures.mirroredTrio
    #expect(topology.expand(2) == [2, 1, 3])
    #expect(topology.expand(1) == [1])
    #expect(topology.expand(99) == [99])
  }

  /// THE ENGINE BOUNDARY. A slave's pixels live on its master, so anything that
  /// needs a drawable display — an `NSScreen`, a window origin, the gamma
  /// activity enforcer — asks for this and gets an ID that has one.
  @Test func aSlaveResolvesToItsMasterAndEverythingElseResolvesToItself() {
    let topology = MirrorFixtures.mirroredTrio
    #expect(topology.drawableDisplayID(for: 1) == 2)
    #expect(topology.drawableDisplayID(for: 3) == 2)
    #expect(topology.drawableDisplayID(for: 2) == 2)
  }

  /// A stale or empty sample must never INVENT a target. Returning the
  /// display's own ID is exactly today's behaviour, which then fails its
  /// `NSScreen` lookup and is reported as a failure (DT17) rather than guessed.
  @Test func anUnknownDisplayResolvesToItselfRatherThanToAGuess() {
    #expect(MirrorTopology([]).drawableDisplayID(for: 42) == 42)
    #expect(MirrorFixtures.mirroredTrio.drawableDisplayID(for: 42) == 42)
  }

  @Test func aDisplayLockedIntoASetIsReportedAsUnbreakable() {
    let topology = MirrorTopology([
      MirrorFixtures.display(1, builtIn: true), MirrorFixtures.display(2, mirrors: 1, always: true),
    ])
    #expect(topology.cannotBeUnmirrored(2))
    #expect(!topology.cannotBeUnmirrored(1))
    #expect(!topology.cannotBeUnmirrored(99))
  }

  /// Every list this type hands out is `id`-ascending, never in
  /// `CGGetOnlineDisplayList` order. "Whichever came back first" is not an
  /// answer that can be reproduced in a bug report.
  @Test func everyListIsSortedByDisplayIDRegardlessOfSampleOrder() {
    let topology = MirrorTopology([
      MirrorFixtures.display(7, mirrors: 4), MirrorFixtures.display(4, inSet: true),
      MirrorFixtures.display(2, mirrors: 4),
    ])
    #expect(topology.slaves(of: 4) == [2, 7])
    #expect(topology.expand(4) == [4, 2, 7])
    #expect(topology.setMembers(containing: 7) == [2, 4, 7])
  }

  /// `kCGNullDirectDisplay` is what EVERY standalone display names, so asking
  /// for its slaves would otherwise gather up every unmirrored display on the
  /// machine and call it a set. Null is not a display and never has members.
  @Test func theNullDisplayIsNeverASetNoMatterHowManyDisplaysNameIt() {
    #expect(MirrorFixtures.unmirroredPair.slaves(of: kCGNullDirectDisplay).isEmpty)
    #expect(MirrorFixtures.mirroredTrio.slaves(of: kCGNullDirectDisplay).isEmpty)
  }

  /// A slave can name a master this sample does not contain — a stale read, or
  /// any consumer building a topology from a filtered list (externals only,
  /// dropping the built-in master). Membership is intersected with the sample,
  /// so it never names a display nobody can act on and `disengage` cannot stage
  /// a change for a phantom. `master(of:)` still reports what the slave names,
  /// because that is a fact about the slave rather than a target.
  @Test func aSetNeverNamesAMasterThisSampleDoesNotContain() {
    let topology = MirrorTopology([MirrorFixtures.display(1, builtIn: true), MirrorFixtures.display(2, mirrors: 9)])
    #expect(topology.setMembers(containing: 2) == [2])
    #expect(topology.master(of: 2) == 9)
    #expect(topology.masters.isEmpty)
  }

  /// The same intersection, on the one accessor whose result is ACTED ON. A
  /// phantom master can never have an `NSScreen`, so returning it would refuse
  /// gamma dimming for that panel forever — and since the software leg clears
  /// its dedupe memo on failure (DT17), forever means once per drag event, with
  /// a log line each. The raw ID at least resolves whenever the sample was
  /// merely stale about mirroring. `master(of:)` above still reports the
  /// phantom, because that is a fact about the slave rather than a target.
  @Test func aDrawableTargetIsNeverADisplayThisSampleDoesNotContain() {
    let topology = MirrorTopology([MirrorFixtures.display(1, builtIn: true), MirrorFixtures.display(2, mirrors: 9)])
    #expect(topology.drawableDisplayID(for: 2) == 2)
    #expect(topology.master(of: 2) == 9)
    // The present-master case is untouched: intersection narrows nothing real.
    #expect(MirrorFixtures.mirroredTrio.drawableDisplayID(for: 1) == 2)
  }

  /// The type promises `id`-ascending everywhere, and `displays` is part of
  /// "everywhere". Two samples of one unchanged machine that differ only in
  /// `CGGetOnlineDisplayList` order are the same topology, and `Equatable` —
  /// which compares the stored array — has to agree.
  @Test func theSampleItselfIsSortedSoEnumerationOrderCannotLeakIntoEquality() {
    let scrambled = MirrorTopology([MirrorFixtures.display(7), MirrorFixtures.display(2), MirrorFixtures.display(4)])
    #expect(scrambled.displays.map(\.id) == [2, 4, 7])
    #expect(scrambled == MirrorTopology([
      MirrorFixtures.display(2), MirrorFixtures.display(4), MirrorFixtures.display(7),
    ]))
  }

  /// The "one HUD per set" property, stated purely. A stepped mirror set has to
  /// show ONE pill on the master: without this, every member resolves to the
  /// same screen origin and a four-panel set stacks four HUD windows at one
  /// point with the last write winning.
  ///
  /// It is a property of `expand` and `drawableDisplayID` together, not of new
  /// code — which is exactly why it is worth pinning. It fails the moment
  /// someone "simplifies" `expand` to return raw members, or teaches
  /// `drawableDisplayID` to hand a slave back unresolved.
  @Test func everyMemberOfASetResolvesToTheSameDrawableDisplay() {
    let topology = MirrorFixtures.mirroredTrio
    let targets = Set(topology.expand(2).map(topology.drawableDisplayID(for:)))
    #expect(targets == [2])
  }

  // MARK: - Synthesis sets (SS1, SS7)

  /// SS7: a synthesis set is not user mirroring. It stays a mirror set in every
  /// CoreGraphics sense; the carve-out is about what the app OFFERS, so the raw
  /// accessors are deliberately unchanged.
  @Test func aSetWhosePairingNamesItsMasterIsASynthesisSetAndNotUserMirroring() {
    let topology = MirrorFixtures.synthesisPair()
    #expect(topology.isSynthesisSet(containing: 5))
    #expect(topology.isSynthesisSet(containing: 2))
    #expect(!topology.isSynthesisSet(containing: 1))
    #expect(topology.userVisibleMirrorSets.isEmpty)

    #expect(topology.masters == [5])
    #expect(topology.setMembers(containing: 2) == [2, 5])
  }

  /// The other half of SS7: the predicate answers about ONE set, so a set the
  /// user built is untouched even on a machine that also has a synthesis set.
  @Test func aGenuineMirrorSetIsUntouchedByTheSynthesisCarveOut() {
    let user = MirrorFixtures.mirroredTrio
    #expect(!user.isSynthesisSet(containing: 2))
    #expect(!user.isSynthesisSet(containing: 3))
    #expect(user.userVisibleMirrorSets == [[2, 1, 3]])

    let mixed = MirrorTopology(
      [
        MirrorFixtures.display(1, mirrors: 2, builtIn: true),
        MirrorFixtures.display(2, inSet: true),
        MirrorFixtures.display(3, mirrors: 2),
        MirrorFixtures.display(4, mirrors: 5),
        MirrorFixtures.display(5, inSet: true),
      ],
      synthesisMasters: [5]
    )
    #expect(mixed.userVisibleMirrorSets == [[2, 1, 3]])
    #expect(mixed.isSynthesisSet(containing: 4))
    #expect(!mixed.isSynthesisSet(containing: 1))
  }

  /// SS1, stated as an assertion: the injected pairing is consulted BEFORE the
  /// CG flags, so the pair expands together whether or not the VD master
  /// reports `CGDisplayIsInMirrorSet`. Phase 0 measured that it does; nothing
  /// here depends on that measurement holding.
  @Test func eitherMemberOfASynthesisSetExpandsToThePairWithoutTheCGMirrorFlags() {
    for reported in [true, false] {
      let topology = MirrorFixtures.synthesisPair(masterReportsFlags: reported)
      #expect(topology.expand(5) == [5, 2])
      #expect(topology.expand(2) == [5, 2])
      #expect(topology.isSynthesisSet(containing: 2))
      #expect(Set(topology.expand(2).map(topology.drawableDisplayID(for:))) == [5])
      #expect(topology.expand(1) == [1])
    }
  }

  /// The control for the assertion above. The same flagless sample WITHOUT the
  /// pairing links nothing, which is what makes that test about the injected
  /// masters rather than about the fixture.
  @Test func withoutThePairingAFlaglessMasterExpandsToItself() {
    let unpaired = MirrorTopology([
      MirrorFixtures.display(2, mirrors: 5), MirrorFixtures.display(5),
    ])
    #expect(unpaired.expand(5) == [5])
    #expect(unpaired.expand(2) == [2])
    #expect(!unpaired.isSynthesisSet(containing: 2))
    #expect(unpaired.userVisibleMirrorSets.isEmpty)
  }

  /// The pairing names displays by runtime ID and IDs are reassigned across a
  /// replug, so a pairing can name a display this sample does not contain.
  /// `expand` never invents a target from it (the same intersection
  /// `setMembers(containing:)` follows), while the predicate still refuses to
  /// call the VD user mirroring.
  @Test func aPairingNamingADisplayThisSampleDoesNotContainInventsNoTarget() {
    let topology = MirrorTopology([MirrorFixtures.display(2)], synthesisMasters: [5])
    #expect(topology.expand(2) == [2])
    #expect(topology.expand(5) == [5])
    #expect(!topology.isSynthesisSet(containing: 2))
    #expect(topology.isSynthesisSet(containing: 5))
    #expect(topology.userVisibleMirrorSets.isEmpty)
  }

  /// Garbage in, and the one shape of it that would be catastrophic: every
  /// standalone display names `kCGNullDirectDisplay` as its master, so a pairing
  /// set that contained it would make the whole rig read as synthesis slaves and
  /// take every mirroring surface off screen. The pairing table never produces
  /// it; the guard is `slaves(of:)`'s, held here too.
  @Test func aNullMasterInThePairingMakesNothingASynthesisSet() {
    let topology = MirrorTopology(
      [MirrorFixtures.display(1), MirrorFixtures.display(2)],
      synthesisMasters: [kCGNullDirectDisplay]
    )
    #expect(!topology.isSynthesisSet(containing: 1))
    #expect(!topology.isSynthesisSet(containing: 2))
    #expect(!topology.isSynthesisSet(containing: kCGNullDirectDisplay))
  }
}
