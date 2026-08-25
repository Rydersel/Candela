import CoreGraphics
import Foundation
import IOKit

/// The EDID macOS already parsed into `AppleCLCD2 -> DisplayAttributes`. No I2C
/// transaction, so a write-only DDC panel identifies itself as fully as one that reads.
public enum CheckupIdentityFacts {
  /// Nesting is not uniform (measured): the manufacture date and serials sit in
  /// `ProductAttributes`, the EOTF flags at top level. Each lookup tries both
  /// levels, because a flag missed one level away reports "no HDR" on a panel that has it.
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

  /// Nil when no entry matches: the display exposed no parsed EDID record. Render
  /// it as that, never as a checkup failure.
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
