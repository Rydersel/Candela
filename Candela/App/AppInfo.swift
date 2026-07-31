import Foundation

enum AppInfo {
  /// The product name is deliberately provisional (spec §9). Every user-facing
  /// string interpolates this — never a "Candela" literal — so the eventual
  /// rename is a one-line change. (This outlives D17/D25: it is a rename-cost
  /// decision, not a localization one.)
  static let productName = "Candela"

  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
  }

  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
  }
}
