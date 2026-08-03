import Foundation
import Testing
@testable import CandelaKit

@Suite("Display config identity")
struct DisplayConfigIdentityTests {
  @Test func theSamePanelProducesTheSameKey() {
    let a = DisplayConfigIdentity(vendor: 0x10AC, model: 0x436A, serial: 0x4433334C, isBuiltIn: false)
    let b = DisplayConfigIdentity(vendor: 0x10AC, model: 0x436A, serial: 0x4433334C, isBuiltIn: false)
    #expect(a == b)
    #expect(a.key == b.key)
  }

  @Test func differentPanelsProduceDifferentKeys() {
    let dell = DisplayConfigIdentity(vendor: 0x10AC, model: 0x436A, serial: 0x4433334C, isBuiltIn: false)
    let mag = DisplayConfigIdentity(vendor: 0x3669, model: 0x3DD0, serial: 0, isBuiltIn: false)
    #expect(dell != mag)
  }

  /// There is exactly one built-in panel and it cannot be swapped, so it gets
  /// a fixed token rather than a vendor triple — its CG values are not
  /// meaningfully more stable and a fixed token is legible in a defaults dump.
  ///
  /// The token matches the `persistenceKey` spelling `BuiltInDisplayPane` and
  /// `AppModel` already use, so the same panel reads as one display in a
  /// `defaults` dump. Exact-string on purpose: the format is frozen on ship.
  @Test func theBuiltInDisplayUsesAFixedToken() {
    let a = DisplayConfigIdentity(vendor: 0x610, model: 0xA04E, serial: 0xFD626D62, isBuiltIn: true)
    let b = DisplayConfigIdentity(vendor: 0x999, model: 0x111, serial: 0x222, isBuiltIn: true)
    #expect(a == b)
    #expect(a.key == "builtIn")
  }

  /// The MAG reports serial 0. Two identical MAGs would therefore collide —
  /// the same known limitation DisplayDiscovery.persistenceKey already
  /// documents. Pinned here so the behaviour is deliberate, not a surprise.
  @Test func panelsWithNoSerialCollideAcrossIdenticalUnits() {
    let one = DisplayConfigIdentity(vendor: 0x3669, model: 0x3DD0, serial: 0, isBuiltIn: false)
    let two = DisplayConfigIdentity(vendor: 0x3669, model: 0x3DD0, serial: 0, isBuiltIn: false)
    #expect(one == two)
  }

  /// The key is a defaults-key component and is pinned forever once shipped.
  @Test func theKeyFormatIsStable() {
    let identity = DisplayConfigIdentity(vendor: 0x10AC, model: 0x436A, serial: 0x4433334C, isBuiltIn: false)
    #expect(identity.key == "10ac-436a-4433334c")
  }
}
