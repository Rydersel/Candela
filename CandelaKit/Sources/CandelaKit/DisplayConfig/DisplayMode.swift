import Foundation

/// One mode a display can run in.
///
/// `ioModeID` is a RUNTIME handle only — it is not stable across replug, so it
/// never persists. `DisplayModeDescriptor` is what gets stored (spec DM6).
public struct DisplayMode: Sendable, Equatable, Identifiable, Hashable {
  public let ioModeID: Int32
  /// What the user calls "looks like" — point dimensions.
  public let logicalWidth: Int
  public let logicalHeight: Int
  /// The framebuffer macOS renders into.
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let refreshHz: Double
  /// `kDisplayModeNativeFlag` — the panel's own timing.
  public let isNative: Bool

  public init(
    ioModeID: Int32, logicalWidth: Int, logicalHeight: Int,
    pixelWidth: Int, pixelHeight: Int, refreshHz: Double,
    isNative: Bool
  ) {
    self.ioModeID = ioModeID
    self.logicalWidth = logicalWidth
    self.logicalHeight = logicalHeight
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.refreshHz = refreshHz
    self.isNative = isNative
  }

  public var id: Int32 { ioModeID }

  /// CoreGraphics reports refresh rates like 59.9998 rather than 60. Normalise
  /// at the boundary so no consumer downstream has to reason about float noise:
  /// the picker dedupes cleanly, and stored descriptors compare sanely.
  ///
  /// Rounds to one decimal, which keeps genuinely distinct rates apart
  /// (59.94 NTSC vs 60) while collapsing measurement noise.
  public static func quantizedRefresh(_ raw: Double) -> Double {
    (raw * 10).rounded() / 10
  }

  public var isHiDPI: Bool { logicalWidth > 0 && pixelWidth >= logicalWidth * 2 }

  /// A scaled mode renders oversized and downsamples. The comparison is
  /// against the PANEL's native pixel count — taken from the mode flagged
  /// `isNative` — and NOT against `CGDisplayPixelsWide`, which reports the
  /// current mode's LOGICAL width and would make everything look native.
  public func isScaled(nativePixelWidth: Int, nativePixelHeight: Int) -> Bool {
    pixelWidth != nativePixelWidth || pixelHeight != nativePixelHeight
  }

  public var descriptor: DisplayModeDescriptor {
    DisplayModeDescriptor(
      logicalWidth: logicalWidth, logicalHeight: logicalHeight,
      pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshHz: refreshHz
    )
  }
}

/// The persisted form of a mode choice. Geometry + refresh only — enough to
/// re-find the mode on a display whose `ioModeID`s have been reassigned.
public struct DisplayModeDescriptor: Sendable, Equatable, Hashable, Codable {
  public let logicalWidth: Int
  public let logicalHeight: Int
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let refreshHz: Double

  public init(logicalWidth: Int, logicalHeight: Int, pixelWidth: Int, pixelHeight: Int, refreshHz: Double) {
    self.logicalWidth = logicalWidth
    self.logicalHeight = logicalHeight
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.refreshHz = refreshHz
  }

  /// Spelled out rather than synthesized on purpose: these strings are an
  /// on-disk format. Synthesized keys track the property names, so a later
  /// rename would silently orphan every stored preference rather than forcing
  /// a deliberate decision about the old data.
  private enum CodingKeys: String, CodingKey {
    case logicalWidth
    case logicalHeight
    case pixelWidth
    case pixelHeight
    case refreshHz
  }
}

/// The point-space shape a runtime mode and its persisted descriptor both have.
/// Mode matching compares the two against each other, so the derived values must
/// come out of one implementation.
protocol LogicalGeometry {
  var logicalWidth: Int { get }
  var logicalHeight: Int { get }
}

extension LogicalGeometry {
  var aspectRatio: Double {
    logicalHeight > 0 ? Double(logicalWidth) / Double(logicalHeight) : 0
  }

  var logicalArea: Int { logicalWidth * logicalHeight }
}

extension DisplayMode: LogicalGeometry {}
extension DisplayModeDescriptor: LogicalGeometry {}
