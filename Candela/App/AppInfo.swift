import Foundation

enum AppInfo {
  /// Every user-facing string interpolates this, never a "Candela" literal, so a
  /// rename stays a one-line change.
  static let productName = "Candela"

  /// The build number is the same string (project.yml sets one from the
  /// other), so there is no second number to show anywhere.
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
  }
}
