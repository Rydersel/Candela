import Foundation

enum AppInfo {
  /// Every user-facing string interpolates this, never a "Candela" literal, so a
  /// rename stays a one-line change.
  static let productName = "Candela"

  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
  }

  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
  }
}
