import CandelaKit
import CoreGraphics
import Testing

/// The one rule about the panic press, pinned on the pure seam that carries
/// it: after every synthesis set has come down, the press may BREAK a mirror set
/// and may never BUILD one.
///
/// `MirrorTopologyPolicy.toggle` is break-else-build, so on the common rig (one
/// panel, one synthesized size, no user mirroring) the unwind removes the only
/// set and the same call answers `.engage`: the press would take the size down
/// and mirror the built-in onto the panel behind a countdown, which is the
/// opposite of a panic button.
@Suite("The panic press after a synthesis unwind") @MainActor
struct MirrorPanicDecisionTests {
  private func display(
    _ id: CGDirectDisplayID, builtIn: Bool = false, mirrors: CGDirectDisplayID? = nil
  ) -> ConfiguredDisplay {
    ConfiguredDisplay(
      id: id,
      identity: DisplayConfigIdentity(
        vendor: 0x10AC, model: UInt32(id), serial: UInt32(id), isBuiltIn: builtIn
      ),
      name: "Display \(id)", isBuiltIn: builtIn,
      mirrorsDisplay: mirrors ?? kCGNullDirectDisplay
    )
  }

  @Test func aPanicPressNeverBuildsASetAfterAnUnwind() {
    // One panel plus the built-in, nothing mirrored: the policy says `.engage`,
    // and that is exactly what must not reach the machine.
    let free = MirrorTopology([display(1, builtIn: true), display(2)])
    guard case .engage = MirrorTopologyPolicy.toggle(free) else {
      Issue.record("the fixture must be one the policy answers with a build")
      return
    }
    #expect(MirroringCoordinator.panicDecisionAfterUnwind(free) == nil)
  }

  @Test func aUserSetLeftAfterAnUnwindIsStillBroken() {
    let mirrored = MirrorTopology([display(1, builtIn: true), display(2, mirrors: 1)])
    guard case .disengage = MirroringCoordinator.panicDecisionAfterUnwind(mirrored) else {
      Issue.record("a set that survived the unwind must still break")
      return
    }
  }

  /// The deliberate exception, flagged in the seam's own doc: a refusal stages
  /// nothing and reconfigures nothing, it only names the set macOS would not
  /// release, so it comes back rather than leaving someone looking at mirroring
  /// that survived a panic press with nothing on screen about it.
  @Test func aSetMacOSWillNotReleaseIsStillReported() {
    let locked = MirrorTopology([
      display(1, builtIn: true),
      ConfiguredDisplay(
        id: 2,
        identity: DisplayConfigIdentity(vendor: 0x10AC, model: 2, serial: 2, isBuiltIn: false),
        name: "Display 2", isBuiltIn: false, mirrorsDisplay: 1, isAlwaysInMirrorSet: true
      ),
    ])
    guard case .refused(.setCannotBeBroken) =
      MirroringCoordinator.panicDecisionAfterUnwind(locked)
    else {
      Issue.record("a locked set is named rather than swallowed")
      return
    }
  }

  /// A single display has nothing to break and nothing to build with, so the
  /// press's work is done. Distinct from the case above: this refusal IS
  /// swallowed.
  @Test func aSingleDisplayEndsThePress() {
    let alone = MirrorTopology([display(1, builtIn: true)])
    #expect(MirroringCoordinator.panicDecisionAfterUnwind(alone) == nil)
  }

  /// The second reading, and the reason it exists. The caller verifies the
  /// unwind from the PAIRING TABLE, which is empty for the whole of an engage,
  /// so an unwind refused because one was in flight still reads as "everything
  /// came down". This sample gets the last word: the panic-press rule is
  /// that no raw mirror change is staged over a standing synthesis set.
  ///
  /// The fixture is the one that makes the rule bite: without the synthesis
  /// master the very same topology answers with a break.
  @Test func aStandingSynthesisMasterStopsThePressDeciding() {
    let displays = [display(1, builtIn: true), display(2, mirrors: 1)]
    let withoutSynthesis = MirrorTopology(displays)
    guard case .disengage = MirroringCoordinator.panicDecisionAfterUnwind(withoutSynthesis) else {
      Issue.record("the fixture must be one the press would otherwise act on")
      return
    }

    let standing = MirrorTopology(displays, synthesisMasters: [90])
    #expect(MirroringCoordinator.panicDecisionAfterUnwind(standing) == nil)
  }
}
