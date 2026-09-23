import Foundation

/// A saved picker choice, independent of the mode IDs assigned after a reconnect.
public struct FavoriteResolution: Codable, Hashable, Sendable {
  public let descriptor: DisplayModeDescriptor
  public let isSynthesized: Bool

  public init(mode: DisplayMode) {
    descriptor = DisplayModeDescriptor(
      logicalWidth: mode.logicalWidth, logicalHeight: mode.logicalHeight,
      pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
      refreshHz: mode.isSynthesized ? 0 : DisplayMode.quantizedRefresh(mode.refreshHz))
    isSynthesized = mode.isSynthesized
  }

  private enum CodingKeys: String, CodingKey {
    case descriptor, isSynthesized
  }

  var isValid: Bool {
    descriptor.logicalWidth > 0 && descriptor.logicalHeight > 0
      && descriptor.pixelWidth > 0 && descriptor.pixelHeight > 0
      && descriptor.refreshHz.isFinite && descriptor.refreshHz >= 0
      && descriptor.refreshHz < Double(Int.max)
  }

  /// Missing choices stay unavailable. Favorites never inherit restore's fallbacks.
  public func resolve(in modes: [DisplayMode]) -> DisplayMode? {
    guard isValid else { return nil }
    let candidates = modes.filter { $0.isSynthesized == isSynthesized }
    let hasLiteralSize = candidates.contains {
      $0.logicalWidth == descriptor.logicalWidth && $0.logicalHeight == descriptor.logicalHeight
    }
    // A present logical size fixes the orientation even when its sharp twin is
    // missing. Rotation must not become a fallback for unavailable rendering.
    let pool = !hasLiteralSize
      ? candidates.filter { sameGeometry($0, descriptor.transposed) }
      : candidates.filter { sameGeometry($0, descriptor) }
    return pool.filter {
      isSynthesized || DisplayMode.quantizedRefresh($0.refreshHz) == descriptor.refreshHz
    }.min { $0.ioModeID < $1.ioModeID }
  }

  private func sameGeometry(_ mode: DisplayMode, _ saved: DisplayModeDescriptor) -> Bool {
    mode.logicalWidth == saved.logicalWidth && mode.logicalHeight == saved.logicalHeight
      && mode.pixelWidth == saved.pixelWidth && mode.pixelHeight == saved.pixelHeight
  }
}
