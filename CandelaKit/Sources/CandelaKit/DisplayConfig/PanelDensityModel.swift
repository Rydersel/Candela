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

/// Where one logical size's density sits against the "looks right" band.
public enum BandPlacement: Sendable, Equatable {
  case below
  case inBand
  case above
}

/// Why the model named no size. Abstention is a first-class outcome, not an
/// error: a wrong recommendation is worse than none.
public enum RecommendationAbstention: Sendable, Equatable {
  /// Virtual displays declare a fake physical size, so density is meaningless.
  case virtualDisplay
  /// No declared physical size, or one outside the plausible range. "The right
  /// size for this panel" is a physical claim.
  case noPhysicalSize
  /// The size in use already looks right.
  case currentInBand
  /// The best applicable candidate IS the size in use.
  case currentIsBest
  /// Physical size is known and the current size is outside the band, but no
  /// applicable candidate reaches it. The residue synthesis would serve.
  case noCandidateInBand
}

/// A logical SIZE, never a mode: the applying surface routes through the
/// existing size-row apply, so `ioModeID` instability never reaches this type.
public struct SizeRecommendation: Sendable, Equatable {
  public let logicalWidth: Int
  public let logicalHeight: Int
  public let looksLikePPI: Double

  public init(logicalWidth: Int, logicalHeight: Int, looksLikePPI: Double) {
    self.logicalWidth = logicalWidth
    self.logicalHeight = logicalHeight
    self.looksLikePPI = looksLikePPI
  }
}

/// The size the model would pick with no availability constraint: the panel's
/// native aspect at the target density, even in both axes because synthesis
/// rejects odd dimensions. `servedToday` is the seam for the synthesis layer:
/// false means no applicable candidate reaches the band.
public struct IdealSize: Sendable, Equatable {
  public let logicalWidth: Int
  public let logicalHeight: Int
  public let servedToday: Bool

  public init(logicalWidth: Int, logicalHeight: Int, servedToday: Bool) {
    self.logicalWidth = logicalWidth
    self.logicalHeight = logicalHeight
    self.servedToday = servedToday
  }
}

/// One call in, one result out: nothing here knows which surface is asking.
///
/// Exactly one of `recommendation` and `abstention` is non-nil.
public struct DensityVerdict: Sendable, Equatable {
  public let recommendation: SizeRecommendation?
  public let abstention: RecommendationAbstention?
  /// Nil exactly when the panel's density is unknown, which is also the only
  /// state in which no ranking happened.
  public let ideal: IdealSize?
  /// Nil when no current size was supplied, or when density is unknown.
  public let currentPlacement: BandPlacement?

  public init(recommendation: SizeRecommendation?, abstention: RecommendationAbstention?,
              ideal: IdealSize?, currentPlacement: BandPlacement?) {
    self.recommendation = recommendation
    self.abstention = abstention
    self.ideal = ideal
    self.currentPlacement = currentPlacement
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

  public static func bandPlacement(of looksLike: Double) -> BandPlacement {
    if looksLike < bandLooksLikePPI.lowerBound { return .below }
    if looksLike > bandLooksLikePPI.upperBound { return .above }
    return .inBand
  }

  /// The whole judgement: panel facts and the sizes that apply today in, one
  /// verdict out.
  ///
  /// Only rows the caller hands over are ranked, so a size with no apply path
  /// is never recommended. `ideal` is computed unconditionally alongside, which
  /// is what tells a later synthesis layer what it would need to build.
  ///
  /// Decision order, and why the two "you are already fine" outcomes sit this
  /// way round: the more specific one is tested first. Any size whose density
  /// is in band and which the ranking would have chosen anyway is reported as
  /// `.currentIsBest`, and `.currentInBand` covers the rest of the band, where
  /// a different size might still rank higher but nothing needs saying. Testing
  /// the band first would make `.currentIsBest` unreachable, since every
  /// candidate is in band by construction.
  public static func evaluate(
    rows: [DisplayModeRow],
    currentLogicalWidth: Int?, currentLogicalHeight: Int?,
    geometry: PanelGeometry
  ) -> DensityVerdict {
    guard !geometry.isVirtual else {
      return DensityVerdict(recommendation: nil, abstention: .virtualDisplay,
                            ideal: nil, currentPlacement: nil)
    }
    guard let panelPPI = physicalPPI(geometry) else {
      return DensityVerdict(recommendation: nil, abstention: .noPhysicalSize,
                            ideal: nil, currentPlacement: nil)
    }

    let scale = targetLooksLikePPI / panelPPI
    let idealWidth = evenRounded(Double(geometry.nativePixelWidth) * scale)
    let idealHeight = evenRounded(Double(geometry.nativePixelHeight) * scale)

    var currentPlacement: BandPlacement?
    if let w = currentLogicalWidth, let h = currentLogicalHeight,
       let density = looksLikePPI(logicalWidth: w, logicalHeight: h, in: geometry) {
      currentPlacement = bandPlacement(of: density)
    }

    let candidates: [(row: DisplayModeRow, density: Double)] = rows.compactMap { row in
      guard let density = looksLikePPI(logicalWidth: row.mode.logicalWidth,
                                       logicalHeight: row.mode.logicalHeight,
                                       in: geometry),
            bandLooksLikePPI.contains(density)
      else { return nil }
      return (row, density)
    }

    let ideal = IdealSize(logicalWidth: idealWidth, logicalHeight: idealHeight,
                          servedToday: !candidates.isEmpty)
    let best = candidates.min(by: outranks)

    func abstaining(_ reason: RecommendationAbstention) -> DensityVerdict {
      DensityVerdict(recommendation: nil, abstention: reason,
                     ideal: ideal, currentPlacement: currentPlacement)
    }

    if let best, best.row.mode.logicalWidth == currentLogicalWidth,
       best.row.mode.logicalHeight == currentLogicalHeight {
      return abstaining(.currentIsBest)
    }
    if currentPlacement == .inBand { return abstaining(.currentInBand) }
    guard let best else { return abstaining(.noCandidateInBand) }

    return DensityVerdict(
      recommendation: SizeRecommendation(logicalWidth: best.row.mode.logicalWidth,
                                         logicalHeight: best.row.mode.logicalHeight,
                                         looksLikePPI: best.density),
      abstention: nil, ideal: ideal, currentPlacement: currentPlacement
    )
  }

  /// Fixed in the spec so two builds cannot disagree, and total so the answer
  /// does not depend on the order the rows arrived in.
  private static func outranks(
    _ lhs: (row: DisplayModeRow, density: Double),
    _ rhs: (row: DisplayModeRow, density: Double)
  ) -> Bool {
    let lhsGap = abs(lhs.density - targetLooksLikePPI)
    let rhsGap = abs(rhs.density - targetLooksLikePPI)
    if lhsGap != rhsGap { return lhsGap < rhsGap }
    if lhs.row.mode.isHiDPI != rhs.row.mode.isHiDPI { return lhs.row.mode.isHiDPI }
    if lhs.row.mode.logicalArea != rhs.row.mode.logicalArea {
      return lhs.row.mode.logicalArea > rhs.row.mode.logicalArea
    }
    return lhs.row.mode.ioModeID < rhs.row.mode.ioModeID
  }

  private static func evenRounded(_ value: Double) -> Int {
    Int((value / 2).rounded() * 2)
  }
}
