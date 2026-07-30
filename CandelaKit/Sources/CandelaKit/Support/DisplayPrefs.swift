import Foundation

/// How a display uses macOS HDR. `boost` engages HDR on a fresh brightness-up
/// press at 100% and drops it on the way back down; `alwaysOn` keeps it engaged.
public enum HDRMode: Int, Sendable, CaseIterable {
  case off = 0
  case boost = 1
  case alwaysOn = 2
}

/// Typed per-display settings, stored in UserDefaults under `"<name>.<persistenceKey>"`
/// so every display carries its own copy (the persistence key is the EDID UUID
/// or the identity triple — see `DisplayDiscovery.persistenceKey(from:)`).
///
/// UserDefaults is documented thread-safe, hence the unchecked conformance.
/// (A struct holding a UserDefaults does not satisfy Sendable under Swift 6,
/// so this mirrors `UserDefaultsBrightnessStore`'s shape rather than being a value type.)
public final class DisplayPrefs: @unchecked Sendable {
  private let defaults: UserDefaults
  private let persistenceKey: String

  public init(defaults: UserDefaults = .standard, persistenceKey: String) {
    self.defaults = defaults
    self.persistenceKey = persistenceKey
  }

  /// Unknown stored raw values fall back to `.off` — an unset key reads 0,
  /// which is `.off` already.
  public var hdrMode: HDRMode {
    get { HDRMode(rawValue: defaults.integer(forKey: key("hdrMode"))) ?? .off }
    set { defaults.set(newValue.rawValue, forKey: key("hdrMode")) }
  }

  /// Dim this display in software only, never over DDC.
  public var forceSoftware: Bool {
    get { defaults.bool(forKey: key("forceSw")) }
    set { defaults.set(newValue, forKey: key("forceSw")) }
  }

  /// Use the shade overlay instead of the gamma table for software dimming
  /// (needed for virtual displays and when another app fights over gamma).
  public var avoidGamma: Bool {
    get { defaults.bool(forKey: key("avoidGamma")) }
    set { defaults.set(newValue, forKey: key("avoidGamma")) }
  }

  /// Where the combined scale hands off from software to hardware dimming,
  /// as a slider point in `DimmingMath.switchingPointRange`; feed it to
  /// `DimmingMath.switchingValue(fromPoint:)`. Out-of-range writes are clamped.
  public var combinedSwitchingPoint: Int {
    get { clampSwitchingPoint(defaults.integer(forKey: key("combinedSwitchingPoint"))) }
    set { defaults.set(clampSwitchingPoint(newValue), forKey: key("combinedSwitchingPoint")) }
  }

  private func key(_ name: String) -> String {
    "\(name).\(persistenceKey)"
  }

  private func clampSwitchingPoint(_ point: Int) -> Int {
    min(max(point, DimmingMath.switchingPointRange.lowerBound), DimmingMath.switchingPointRange.upperBound)
  }
}
