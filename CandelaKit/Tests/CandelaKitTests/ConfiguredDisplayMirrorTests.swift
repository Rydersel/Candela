import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Mirror facts on a configured display (DT10)")
struct ConfiguredDisplayMirrorTests {
  private func display(
    _ id: CGDirectDisplayID,
    mirrors: CGDirectDisplayID = kCGNullDirectDisplay,
    inSet: Bool = false,
    always: Bool = false,
    builtIn: Bool = false
  ) -> ConfiguredDisplay {
    ConfiguredDisplay(
      id: id,
      identity: DisplayConfigIdentity(vendor: 1, model: 2, serial: id, isBuiltIn: builtIn),
      name: "Display \(id)",
      isBuiltIn: builtIn,
      mirrorsDisplay: mirrors,
      isInMirrorSet: inSet,
      isAlwaysInMirrorSet: always
    )
  }

  /// The ambiguity this whole pair of fields exists for. A standalone display
  /// and a master both report a null `mirrorsDisplay`, so the second call is
  /// what separates them — measured on this machine, where an unmirrored
  /// built-in reports `IsInMirrorSet=0, MirrorsDisplay=0`.
  @Test func aMasterAndAStandaloneDisplayAreIndistinguishableByMirrorsDisplayAlone() {
    let master = display(1, inSet: true)
    let standalone = display(2)
    #expect(master.mirrorsDisplay == standalone.mirrorsDisplay)
    #expect(master.isMirrorMaster)
    #expect(!standalone.isMirrorMaster)
  }

  /// A slave that claims not to be in a mirror set is not a state any caller
  /// should have to defend against, and the defaulted parameters make it
  /// constructible by accident in every fixture that sets only `mirrorsDisplay`.
  @Test func aSlaveIsInAMirrorSetEvenWhenTheFixtureForgotToSaySo() {
    let slave = display(3, mirrors: 1)
    #expect(slave.isInMirrorSet)
    #expect(slave.isMirrorSlave)
    #expect(!slave.isMirrorMaster)
  }

  @Test func aDisplayLockedIntoASetReportsBothMembershipAndPermanence() {
    let locked = display(4, mirrors: 1, always: true)
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
