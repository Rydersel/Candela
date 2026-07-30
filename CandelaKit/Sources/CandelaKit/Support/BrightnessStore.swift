import Foundation

/// Persists last-known brightness per display. Needed because write-only DDC
/// panels (e.g. the MAG341C) give no readback: last-written IS the truth.
public protocol BrightnessStoring: Sendable {
  func savedBrightness(for key: String) -> Double?
  func saveBrightness(_ value: Double, for key: String)
}

/// UserDefaults is documented thread-safe, hence the unchecked conformance.
public final class UserDefaultsBrightnessStore: BrightnessStoring, @unchecked Sendable {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func savedBrightness(for key: String) -> Double? {
    defaults.object(forKey: key) as? Double
  }

  public func saveBrightness(_ value: Double, for key: String) {
    defaults.set(value, forKey: key)
  }
}
