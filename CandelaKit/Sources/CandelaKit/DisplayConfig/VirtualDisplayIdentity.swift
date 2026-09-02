import Foundation

/// The descriptor identities Candela stamps on displays it creates.
///
/// Everything here is a compile-time constant on purpose: macOS writes ONE
/// permanent colour profile and ONE device registration per display identity
/// into system-scope ColorSync state and never removes either. Fixed
/// identities bound Candela's permanent footprint at one file per slot,
/// forever. A rig that varied identity per run left 143 orphaned profiles and
/// drove the ColorSync daemons to 59% CPU.
///
/// The PRODUCT varies per slot, never the serial: macOS keys its
/// duplicate-display refusal on vendor+product+physical size, ignoring serial
/// and name entirely (the twins measurement: twins sharing the whole triple
/// coexist only because their sizeInMillimeters differ). Every slot shares one
/// physical size, so the product is the field doing the separating. The product
/// range 0x2001+ is disjoint from the vdrig rig's 0x1001..0x1003, so rig and app
/// displays read apart in any topology dump.
///
/// `DisplayConfigIdentity` is NOT extended and gains no virtual case: its key
/// format is frozen on-disk schema. The extension is entirely on the INPUTS,
/// which works because descriptor vendorID/productID/serialNum come back
/// verbatim as CGDisplayVendorNumber/ModelNumber/SerialNumber (measured
/// directly).
public enum VirtualDisplayIdentity {
  /// Reserved for displays Candela creates. NEVER user-settable. Bit 15 is set,
  /// and an EDID manufacturer ID packs three letters into five bits each with
  /// the top bit reserved zero, so no compliant EDID can produce it.
  public static let vendorID: UInt32 = 0xCA1D

  /// Every slot the host will stand, user and engine alike. The host's guard
  /// is the one place that means ALL of them.
  public static let slotRange = 1 ... 5

  /// Slots a person can add, name and remove in the Virtual Displays pane.
  /// Everything user-facing (pane tiles, the slot prefs the reconciler
  /// converges, the probe's `vd create`) is clamped to this.
  public static let userSlotRange = 1 ... 3

  /// Engine-internal slots for synthesized sizes. Never in the pane,
  /// never allocated by a user action; the family stays two wide because each
  /// advertised identity leaks one permanent ColorSync profile.
  public static let synthesisSlotRange = 4 ... 5

  /// Ceiling for `maxPixelsWide/High`, and the real control surface for HiDPI:
  /// macOS emits a 2x variant only for modes whose doubled framebuffer fits
  /// under it. 8192 x 4320 leaves a 4K logical size at 2x inside it.
  /// Constant because it feeds the advertised EDID, and a new EDID may mint a
  /// new colour profile.
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
