import CoreGraphics

public struct ExternalDisplay: Identifiable, Sendable {
  public let id: CGDirectDisplayID
  public let name: String
  /// Stable across ports/reboots (EDID UUID preferred); used as the suffix of
  /// per-display UserDefaults keys.
  public let persistenceKey: String

  public init(id: CGDirectDisplayID, name: String, persistenceKey: String) {
    self.id = id
    self.name = name
    self.persistenceKey = persistenceKey
  }
}
