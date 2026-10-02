import Foundation

/// Persists the latest user or adopted hardware brightness per display.
/// When readback is unavailable, the saved value preserves app intent; it does
/// not prove that a write landed or that the monitor has not changed since.
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
