import CoreGraphics

public struct ExternalDisplay: Identifiable, Sendable {
  public let id: CGDirectDisplayID
  public let name: String

  public init(id: CGDirectDisplayID, name: String) {
    self.id = id
    self.name = name
  }
}
