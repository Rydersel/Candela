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
}

/// `Result<Void, _>` is not `Equatable` — `Void` isn't — so the failures of the
/// preview sessions' `begin` are compared through their error rather than as
/// whole results.
///
/// File-internal rather than `private`, and living here rather than in either
/// session's own suite, because BOTH `ModePreviewSessionTests` and
/// `MirrorPreviewSessionTests` need it. `private` at file scope is invisible to
/// the other file, and a second copy is a second thing to get wrong.
extension Result where Success == Void, Failure == DisplayConfigError {
  var failureError: DisplayConfigError? {
    if case let .failure(error) = self { return error }
    return nil
  }
}

@Suite("Mirror topology reconstruction (DT13)")
struct MirrorTopologyTests {
  private func display(
    _ id: CGDirectDisplayID,
    mirrors: CGDirectDisplayID = kCGNullDirectDisplay,
    inSet: Bool = false,
    always: Bool = false,
    builtIn: Bool = false
  ) -> ConfiguredDisplay {
    MirrorFixtures.display(id, mirrors: mirrors, inSet: inSet, always: always, builtIn: builtIn)
  }

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

  /// The exact replacement for `KeyActionExecutor.expandToMirrorSet`: a master
  /// expands to its set so every member gets the same brightness step, and
  /// anything else expands to itself.
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
    let topology = MirrorTopology([display(1, builtIn: true), display(2, mirrors: 1, always: true)])
    #expect(topology.cannotBeUnmirrored(2))
    #expect(!topology.cannotBeUnmirrored(1))
    #expect(!topology.cannotBeUnmirrored(99))
  }

  /// Every list this type hands out is `id`-ascending, never in
  /// `CGGetOnlineDisplayList` order. "Whichever came back first" is not an
  /// answer that can be reproduced in a bug report.
  @Test func everyListIsSortedByDisplayIDRegardlessOfSampleOrder() {
    let topology = MirrorTopology([
      display(7, mirrors: 4), display(4, inSet: true), display(2, mirrors: 4),
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
    let topology = MirrorTopology([display(1, builtIn: true), display(2, mirrors: 9)])
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
    let topology = MirrorTopology([display(1, builtIn: true), display(2, mirrors: 9)])
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
    let scrambled = MirrorTopology([display(7), display(2), display(4)])
    #expect(scrambled.displays.map(\.id) == [2, 4, 7])
    #expect(scrambled == MirrorTopology([display(2), display(4), display(7)]))
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
}
