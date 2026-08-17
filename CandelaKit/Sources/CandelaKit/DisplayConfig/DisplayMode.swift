import Foundation

/// Where this mode came from, and therefore which call applies it.
///
/// CoreGraphics and CGS share ONE mode-ID space — measured 2026-08-06 across
/// three panels, 0 IDs absent (S6 §4) — so those two are not a second identity,
/// only a routing tag. It deliberately does NOT reach `DisplayModeDescriptor`:
/// the persisted form stays geometry-keyed so a mode that migrates between the
/// two sources across an OS update still re-finds (CR3).
public enum ModeProvenance: Sendable, Equatable, Hashable {
  /// `CGDisplayCopyAllDisplayModes`, applied with `CGConfigureDisplayWithDisplayMode`.
  case coreGraphics
  /// Revealed from the CGS mode list, applied with `CGSConfigureDisplayMode`.
  case coreGraphicsServices
  /// Not from any enumeration: a size Candela renders by mirroring the panel
  /// onto a virtual display (SS5). It shares no ID space with the other two,
  /// so its `ioModeID` is a sentinel from `DisplayMode.syntheticIoModeID` that
  /// is never handed to CoreGraphics or CGS, and applying it is the
  /// `ModeSynthesisEngine`'s job rather than a configuration transaction's.
  case synthesized
}

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
  /// Which list published this mode, and therefore which call applies it.
  public let provenance: ModeProvenance

  public init(
    ioModeID: Int32, logicalWidth: Int, logicalHeight: Int,
    pixelWidth: Int, pixelHeight: Int, refreshHz: Double,
    isNative: Bool, provenance: ModeProvenance = .coreGraphics
  ) {
    self.ioModeID = ioModeID
    self.logicalWidth = logicalWidth
    self.logicalHeight = logicalHeight
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.refreshHz = refreshHz
    self.isNative = isNative
    self.provenance = provenance
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

  /// This option exists because our own enumeration found it, not because the
  /// public one listed it. The pickers mark these rows.
  ///
  /// Reads the recorded provenance and nothing else. Sharpness is not
  /// provenance: `kCGDisplayShowDuplicateLowResolutionModes` puts HiDPI modes
  /// INTO the CoreGraphics list, so a flag derived by diffing the two
  /// enumerations is a synonym for `!isHiDPI`, which was built once and removed
  /// for exactly that reason.
  ///
  /// Switched rather than compared so a third source cannot be added without
  /// deciding whether the pickers mark it, and with which words. Synthesis was
  /// that third source: it gets its own badge, so this stays true for the
  /// revealed rows alone.
  public var isRevealed: Bool {
    switch provenance {
    case .coreGraphics: false
    case .coreGraphicsServices: true
    case .synthesized: false
    }
  }

  /// A size Candela renders rather than one the panel offers (SS5). Distinct
  /// from `isRevealed` in both mechanism and badge copy.
  public var isSynthesized: Bool {
    switch provenance {
    case .coreGraphics, .coreGraphicsServices: false
    case .synthesized: true
    }
  }

  /// The sentinel `ioModeID` for the stop at `stopIndex` in the synthetic
  /// catalog. Negative because no real `IODisplayModeID` is, so a sentinel that
  /// leaks into a CoreGraphics or CGS call fails loudly instead of landing on
  /// somebody else's mode.
  public static func syntheticIoModeID(stopIndex: Int) -> Int32 {
    Int32(-(1000 + stopIndex))
  }

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

public extension DisplayMode {
  /// Whether two modes denote the same GEOMETRY: both size pairs, and the
  /// refresh rate within tolerance.
  ///
  /// Spelled out twice before (#68), in `ModeReapplyPolicy`'s already-running
  /// test and in the apply cross-check. Those two answer different questions and
  /// must stay where they are; the predicate underneath them is one rule.
  ///
  /// Never `ioModeID`, and never `==`. The ID is a positional handle that is
  /// reassigned across reconfiguration, so two equal IDs are not evidence of the
  /// same mode and two different IDs are not evidence of different ones.
  ///
  /// `isNative` is deliberately excluded: it is a fact about the panel rather
  /// than part of a mode's identity, and folding it in would make the apply
  /// cross-check reject a mode it had just correctly resolved.
  ///
  /// Refresh carries the usual tolerance. CoreGraphics reports 59.997, and an
  /// exact comparison would decide a display is never already where it is.
  func matchesGeometry(of other: DisplayMode) -> Bool {
    logicalWidth == other.logicalWidth
      && logicalHeight == other.logicalHeight
      && pixelWidth == other.pixelWidth
      && pixelHeight == other.pixelHeight
      && ModePersistence.refreshMatches(refreshHz, other.refreshHz)
  }
}
