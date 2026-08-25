import CoreGraphics
import Foundation
import IOKit

/// Identity as the display itself reported it at connection: the EDID macOS
/// already parsed into `AppleCLCD2 -> DisplayAttributes`. No I2C transaction is
/// involved, so a write-only DDC panel identifies itself as completely as a
/// panel that answers readbacks.
public enum CheckupIdentityFacts {
  /// The record's nesting is not uniform, and it was measured rather than
  /// assumed. The manufacture date and both serials sit inside
  /// `ProductAttributes`, next to `LegacyManufacturerID`; the EOTF capability
  /// flags were recorded at the record's top level. Each lookup tries the other
  /// level too: a flag missed because it sat one level away would be reported
  /// as "no HDR" on a panel that has it, which is a wrong answer rather than an
  /// absent one.
  public static func parse(
    displayAttributes attrs: [String: Any], identityKey: String, vendorID: UInt32,
    modelID: UInt32, nativePixels: (Int, Int), maxRefreshHz: Double?
  ) -> CheckupDisplayIdentity {
    let product = attrs["ProductAttributes"] as? [String: Any] ?? [:]
    let alphanumeric = product["AlphanumericSerialNumber"] as? String
    // A declared serial of 0 is the MAG's "none reported", not a serial of zero.
    let numeric = (product["SerialNumber"] as? Int64).flatMap { $0 == 0 ? nil : String($0) }
    return CheckupDisplayIdentity(
      identityKey: identityKey, vendorID: vendorID, modelID: modelID,
      serial: alphanumeric.flatMap { $0.isEmpty ? nil : $0 } ?? numeric,
      manufactureWeek: integer("WeekOfManufacture", in: product, orIn: attrs),
      manufactureYear: integer("YearOfManufacture", in: product, orIn: attrs),
      nativePixelWidth: nativePixels.0, nativePixelHeight: nativePixels.1,
      maxRefreshHz: maxRefreshHz,
      supportsPQEOTF: flag("SupportsPQEOTF", in: attrs, orIn: product),
      supportsHDRGammaEOTF: flag("SupportsHDRGammaEOTF", in: attrs, orIn: product),
      productName: product["ProductName"] as? String ?? "")
  }

  /// Live read of the `AppleCLCD2` entry matched to this display.
  /// Returns nil when no entry matches, which is the "the display exposed no
  /// parsed EDID record" case and must be rendered as such, never as a checkup
  /// failure.
  public static func read(
    displayID: CGDirectDisplayID, identityKey: String, vendorID: UInt32, modelID: UInt32,
    nativePixels: (Int, Int), maxRefreshHz: Double?
  ) -> CheckupDisplayIdentity? {
    guard let attrs = Arm64DDC.displayAttributes(displayID: displayID) else { return nil }
    return parse(displayAttributes: attrs, identityKey: identityKey, vendorID: vendorID,
                 modelID: modelID, nativePixels: nativePixels, maxRefreshHz: maxRefreshHz)
  }

  private static func integer(_ key: String, in first: [String: Any], orIn second: [String: Any]) -> Int? {
    (first[key] as? Int) ?? (second[key] as? Int)
  }

  private static func flag(_ key: String, in first: [String: Any], orIn second: [String: Any]) -> Bool {
    ((first[key] as? Bool) ?? (second[key] as? Bool)) ?? false
  }
}
