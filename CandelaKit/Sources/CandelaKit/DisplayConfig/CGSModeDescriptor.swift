import Foundation

/// One entry from the private CGS display-mode list.
///
/// Field offsets were verified byte-for-byte on three panels against macOS
/// 26.6.1 (25G76) — see `docs/spikes/2026-08-06-cgs-mode-revelation.md` §3. Two
/// of them (`pixelWidth`/`pixelHeight`, offsets 200 and 204) are not in the
/// community-transcribed headers; they carry the framebuffer size directly,
/// which is strictly better than multiplying logical by density and rounding.
public struct CGSModeDescriptor: Sendable, Equatable, Hashable {
  /// Also the index it was read at, and the same ID space as
  /// `CGDisplayMode.ioDisplayModeID` (S6 §4).
  public let modeNumber: Int32
  public let flags: UInt32
  public let logicalWidth: Int
  public let logicalHeight: Int
  public let pixelWidth: Int
  public let pixelHeight: Int
  /// **Truncated, not rounded** — CoreGraphics' 59.9998 arrives here as 59.
  /// Never compare this to a CoreGraphics refresh for equality (CR1).
  public let refreshHz: Int
  public let density: Double

  public init(
    modeNumber: Int32, flags: UInt32,
    logicalWidth: Int, logicalHeight: Int,
    pixelWidth: Int, pixelHeight: Int,
    refreshHz: Int, density: Double
  ) {
    self.modeNumber = modeNumber
    self.flags = flags
    self.logicalWidth = logicalWidth
    self.logicalHeight = logicalHeight
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.refreshHz = refreshHz
    self.density = density
  }

  /// macOS's own "not usable for the desktop GUI" bit.
  public static let unusableFlag: UInt32 = 0x4000_0000

  public var isUsable: Bool { flags & Self.unusableFlag == 0 }

  public var aspectRatio: Double {
    logicalHeight > 0 ? Double(logicalWidth) / Double(logicalHeight) : 0
  }
}
