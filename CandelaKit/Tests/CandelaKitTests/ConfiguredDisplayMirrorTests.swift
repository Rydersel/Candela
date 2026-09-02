import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Mirror facts on a configured display")
struct ConfiguredDisplayMirrorTests {
  /// The ambiguity both fields exist for: a standalone display and a master both report
  /// a null `mirrorsDisplay`, so `isInMirrorSet` separates them. Measured here, where an
  /// unmirrored built-in reports `IsInMirrorSet=0, MirrorsDisplay=0`.
  @Test func aMasterAndAStandaloneDisplayAreIndistinguishableByMirrorsDisplayAlone() {
    let master = MirrorFixtures.display(1, inSet: true)
    let standalone = MirrorFixtures.display(2)
    #expect(master.mirrorsDisplay == standalone.mirrorsDisplay)
    #expect(master.isMirrorMaster)
    #expect(!standalone.isMirrorMaster)
  }

  /// A slave claiming not to be in a mirror set is not a state callers should defend
  /// against, and the defaulted parameters make it constructible by accident.
  @Test func aSlaveIsInAMirrorSetEvenWhenTheFixtureForgotToSaySo() {
    let slave = MirrorFixtures.display(3, mirrors: 1)
    #expect(slave.isInMirrorSet)
    #expect(slave.isMirrorSlave)
    #expect(!slave.isMirrorMaster)
  }

  @Test func aDisplayLockedIntoASetReportsBothMembershipAndPermanence() {
    let locked = MirrorFixtures.display(4, mirrors: 1, always: true)
    #expect(locked.isInMirrorSet)
    #expect(locked.isAlwaysInMirrorSet)
  }

  /// Every existing fixture in the test suite constructs a `ConfiguredDisplay`
  /// without the new parameters. They must keep meaning "standalone".
  @Test func theDefaultedParametersDescribeAnUnmirroredDisplay() {
    let plain = ConfiguredDisplay(
      id: 9,
      identity: DisplayConfigIdentity(vendor: 1, model: 2, serial: 9, isBuiltIn: false),
      name: "Display 9",
      isBuiltIn: false
    )
    #expect(!plain.isInMirrorSet)
    #expect(!plain.isAlwaysInMirrorSet)
    #expect(!plain.isMirrorMaster)
    #expect(!plain.isMirrorSlave)
  }
}
