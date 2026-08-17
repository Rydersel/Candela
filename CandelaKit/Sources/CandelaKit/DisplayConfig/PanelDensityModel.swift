import Foundation

/// The physical facts about a panel that density reasoning needs, in
/// panel-native orientation.
///
/// Native pixels come from the mode carrying the native flag, never from
/// `CGDisplayPixelsWide`, which reports whatever the display is currently
/// running.
public struct PanelGeometry: Sendable, Equatable {
  public let nativePixelWidth: Int
  public let nativePixelHeight: Int
  /// Integer centimetres as the panel declares them; nil when not declared.
  public let physicalWidthCm: Int?
  public let physicalHeightCm: Int?
  /// Virtual displays declare a fake size, so they are excluded by flag.
  public let isVirtual: Bool

  public init(nativePixelWidth: Int, nativePixelHeight: Int,
              physicalWidthCm: Int?, physicalHeightCm: Int?, isVirtual: Bool) {
    self.nativePixelWidth = nativePixelWidth
    self.nativePixelHeight = nativePixelHeight
    self.physicalWidthCm = physicalWidthCm
    self.physicalHeightCm = physicalHeightCm
    self.isVirtual = isVirtual
  }
}

/// Density is the model: how big things actually look on a given panel at a
/// given logical size, in logical pixels per physical inch.
///
/// Foundation only, like `DisplayModeCatalog`, so every judgement is testable
/// against captured fixtures rather than against attached hardware.
///
/// Both derivations pair the two MAJOR axes: the largest pixel dimension over
/// the largest physical dimension. That is orientation-invariant, which is the
/// load-bearing decision here. The development Dell mounts rotated 270°, so
/// its pixel dimensions and its declared physical size need not agree about
/// which field holds the long axis; pairing majors means no rotation special
/// case and no dependence on that agreement. Aspect ratio is preserved by the
/// hardware, so the minor axis carries no information the major axis lacks.
public enum PanelDensityModel {
  /// Band center for the "looks right" target, and the distance origin the
  /// ranking measures against.
  ///
  /// Calibration output, not a design guess: pinned by the fixture set
  /// captured from the three panels on the rig (MAG, Dell portrait, built-in).
  /// It is the macOS desktop convention rather than an invention; the 27-inch
  /// 5K default sits near 109, and the MAG's native mode measures 109.2.
  public static let targetLooksLikePPI = 110.0

  /// A logical size whose density falls inside this band already looks right,
  /// so the engine has nothing to recommend.
  ///
  /// Calibration output pinned by the same three-panel fixture set. The
  /// acceptance constraint the edges satisfy: the MAG's native mode (109.2)
  /// and the Dell's looks-like-2560x1440 rung (108.4) are both in band, the
  /// built-in's default (128.0) is in band so the Retina laptop is silenced
  /// with no special case, and the Dell's 1x native (162.6) is above it.
  /// Retuning after new panel evidence is expected; the fixtures make that a
  /// visible diff rather than a silent drift.
  public static let bandLooksLikePPI = 95.0...135.0

  /// Below this density everything on screen is comically huge, so the size is
  /// not a usable desktop. Replaces the flat minor-axis pixel floor wherever
  /// physical size is known.
  ///
  /// Calibration output pinned by the fixture set. The acceptance constraint:
  /// the MAG's three hidden mid-ladder rungs (1600x670 at 50.8, 1344x562 at
  /// 42.7, 1280x536 at 40.6) clear it and return to the curated list, while
  /// the junk sizes the pixel floor exists to remove (the Dell's 300x400 at
  /// 16.9) stay out.
  public static let floorLooksLikePPI = 38.0

  /// Usability floor when physical size is unknown, as a fraction of the
  /// native minor axis. The floor has to work on every panel, so it cannot
  /// require the physical claim a recommendation requires.
  ///
  /// Calibration output pinned by the fixture set, chosen so that no size
  /// currently curated on any of the three panels disappears when the model
  /// runs without a declared physical size.
  public static let fallbackFloorMinorAxisFraction = 0.33

  /// Sanity bounds on derived physical PPI. Outside them the declared size is
  /// garbage EDID, and the answer is abstention rather than a guess.
  ///
  /// Calibration output pinned by the fixture set: the three measured panels
  /// (109.2, 162.6, 256.0) sit well inside, while a 4K panel declaring 1 cm
  /// reads 9753.6 and is rejected. Wide on purpose, since integer-centimetre
  /// truncation costs 1 to 2 percent on a 27 to 34 inch panel and this range
  /// is only asked to catch nonsense.
  public static let plausiblePhysicalPPIRange = 40.0...400.0

  /// The panel's own pixel density: native pixels per physical inch. Nil when
  /// the panel declares no size or an implausible one.
  public static func physicalPPI(_ geometry: PanelGeometry) -> Double? {
    guard let wCm = geometry.physicalWidthCm, let hCm = geometry.physicalHeightCm,
          wCm > 0, hCm > 0 else { return nil }
    let majorPixels = Double(max(geometry.nativePixelWidth, geometry.nativePixelHeight))
    let majorInches = Double(max(wCm, hCm)) / 2.54
    guard majorInches > 0 else { return nil }
    let ppi = majorPixels / majorInches
    return plausiblePhysicalPPIRange.contains(ppi) ? ppi : nil
  }

  /// How big a given logical size looks on this panel: logical pixels per
  /// physical inch. Nil under the same conditions as `physicalPPI`, so a panel
  /// whose declared size cannot be trusted yields no density at all.
  public static func looksLikePPI(
    logicalWidth: Int, logicalHeight: Int, in geometry: PanelGeometry
  ) -> Double? {
    guard physicalPPI(geometry) != nil,
          let wCm = geometry.physicalWidthCm, let hCm = geometry.physicalHeightCm
    else { return nil }
    let majorInches = Double(max(wCm, hCm)) / 2.54
    return Double(max(logicalWidth, logicalHeight)) / majorInches
  }
}
