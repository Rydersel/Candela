import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Identity for displays Candela creates. Distinctness here is by
/// CONSTRUCTION, not by hashing: the collision it prevents is silent, and
/// "probably distinct" is the wrong strength for that.
@Suite("Virtual display identity (VD7)")
struct VirtualDisplayIdentityTests {
  /// The key is produced by the UNCHANGED `DisplayConfigIdentity.key`
  /// function; the format is frozen on-disk schema, so these are pinned
  /// exactly.
  @Test func theKeyIsTheOrdinaryFormatOverOurReservedTriple() {
    #expect(VirtualDisplayIdentity.configIdentity(slot: 1).key == "ca1d-2001-1")
    #expect(VirtualDisplayIdentity.configIdentity(slot: 3).key == "ca1d-2003-3")
  }

  /// The PRODUCT varies per slot, never the serial. macOS refuses a second
  /// virtual display advertising the same vendor+product as a standing one
  /// regardless of serial, name or size (the twins measurement), so a
  /// serial-varying scheme could never run two slots at once. This test fails
  /// if someone "simplifies" back to a shared product.
  @Test func productsAreDistinctAcrossSlots() {
    let products = VirtualDisplayIdentity.slotRange.map(VirtualDisplayIdentity.productID(slot:))
    #expect(Set(products).count == products.count)
  }

  @Test func slotIdentitiesNeverCollide() {
    let keys = VirtualDisplayIdentity.slotRange.map { VirtualDisplayIdentity.configIdentity(slot: $0).key }
    #expect(Set(keys).count == keys.count)
  }

  /// "0-0-0" is the key a panel reporting serial 0 produces, which the MAG
  /// 341C does; "builtIn" is the literal the built-in spells itself.
  @Test func aVirtualIdentityIsNeitherTheSerialZeroKeyNorTheBuiltIn() {
    for slot in VirtualDisplayIdentity.slotRange {
      let key = VirtualDisplayIdentity.configIdentity(slot: slot).key
      #expect(key != "0-0-0")
      #expect(key != "builtIn")
    }
  }

  /// Defensive rounding: S2 observed a real failure at an odd width that the
  /// research pass could not reproduce as a parity effect. Kept because it
  /// costs nothing and the failure is still unexplained.
  @Test func normalizingRoundsBothAxesToEvenAndQuantizesRefresh() {
    let spec = VirtualDisplaySpec(
      name: "Test", logicalWidth: 1921, logicalHeight: 1081, hiDPI: true, refreshHz: 59.9998
    ).normalized
    #expect(spec.logicalWidth == 1920)
    #expect(spec.logicalHeight == 1080)
    #expect(spec.refreshHz == 60.0)
  }

  @Test func normalizingIsIdempotentAndNeverProducesAZeroAxis() {
    let once = VirtualDisplaySpec(
      name: "Tiny", logicalWidth: 1, logicalHeight: 1, hiDPI: false, refreshHz: 60
    ).normalized
    #expect(once.logicalWidth == 2)
    #expect(once.logicalHeight == 2)
    #expect(once.normalized == once)
  }

  /// The ceiling clamp is what stands between an escape-hatch pref and a
  /// UInt32 trap in the host on every launch.
  @Test func normalizingClampsBothAxesToThePixelCeiling() {
    let huge = VirtualDisplaySpec(
      name: "Huge", logicalWidth: 1_000_000, logicalHeight: 1_000_000, hiDPI: true, refreshHz: 60
    ).normalized
    #expect(huge.logicalWidth == VirtualDisplayIdentity.maxPixels.wide)
    #expect(huge.logicalHeight == VirtualDisplayIdentity.maxPixels.high)
    #expect(huge.normalized == huge)
  }

  /// The handle carries the SPEC, because nothing is ever read back from a
  /// live virtual display (VD5): `hiDPI` read back 2 after being set to 1,
  /// and `CGDisplayScreenSize` read 0.0 x 0.0 mm.
  @Test func aHandleCarriesTheNormalizedSpecAsItsTruth() {
    let spec = VirtualDisplaySpec(
      name: "Test", logicalWidth: 1921, logicalHeight: 1080, hiDPI: true, refreshHz: 60
    ).normalized
    let handle = VirtualDisplayHandle(
      uuid: UUID(), slot: 2, displayID: 133,
      identity: VirtualDisplayIdentity.configIdentity(slot: 2), spec: spec
    )
    #expect(handle.spec.logicalWidth == 1920)
    #expect(handle.identity.key == "ca1d-2002-2")
  }
}
