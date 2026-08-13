import Foundation

/// The descriptor identities Candela stamps on displays it creates.
///
/// Everything here is a compile-time constant on purpose: macOS writes ONE
/// permanent colour profile and ONE device registration per display identity
/// into system-scope ColorSync state and never removes either (S1 §5B and the
/// device-registration follow-up on #14). Fixed identities bound Candela's
/// permanent footprint at one file per slot, forever, on any machine (VD8).
/// A previous rig that varied identity per run left 143 orphaned profiles and
/// drove the ColorSync daemons to 59% CPU.
///
/// The PRODUCT varies per slot, never the serial: macOS refuses a second
/// virtual display advertising the same vendor+product as a standing one,
/// regardless of serial, name or physical size (the twins measurement,
/// tools/vdrig/README.md). The product range 0x2001+ is disjoint from
/// vdrig's 0x1001..0x1003 so rig displays and app displays read apart in any
/// topology dump.
///
/// `DisplayConfigIdentity` is NOT extended and gains no virtual case: its key
/// format is frozen on-disk schema. The extension is entirely on the INPUTS,
/// which is possible because Candela chooses them; descriptor
/// vendorID/productID/serialNum come back verbatim as
/// CGDisplayVendorNumber/ModelNumber/SerialNumber (measured in S1).
public enum VirtualDisplayIdentity {
  /// Reserved for displays Candela creates. NEVER user-settable. Bit 15 is
  /// set, and an EDID manufacturer ID packs three letters into five bits each
  /// with the top bit reserved zero, so no compliant EDID can produce it; an
  /// argument worth having and deliberately not load-bearing.
  public static let vendorID: UInt32 = 0xCA1D

  public static let slotRange = 1 ... 3

  /// Ceiling for `maxPixelsWide/High`. The real control surface for HiDPI:
  /// macOS emits a 2x variant only for modes whose doubled framebuffer fits
  /// under it (S1 §4). 8192 x 4320 leaves a 4K logical size at 2x inside the
  /// ceiling. Constant because it feeds the advertised EDID and a new EDID
  /// may mint a new colour profile.
  public static let maxPixels = (wide: 8192, high: 4320)

  public static func productID(slot: Int) -> UInt32 { 0x2000 + UInt32(slot) }

  public static func serial(slot: Int) -> UInt32 { UInt32(slot) }

  public static func defaultName(slot: Int) -> String { "Candela Virtual Display \(slot)" }

  /// Fixed advertised physical size, one value for every slot: it feeds the
  /// EDID, so varying it could mint a new profile. 600 x 340 mm reads as a
  /// plausible 27-inch class display.
  public static let sizeInMillimeters = (width: 600, height: 340)

  public static func configIdentity(slot: Int) -> DisplayConfigIdentity {
    DisplayConfigIdentity(
      vendor: vendorID, model: productID(slot: slot), serial: serial(slot: slot), isBuiltIn: false
    )
  }
}
