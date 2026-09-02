import Foundation

/// One size Candela can render by mirroring a panel onto a virtual display,
/// rather than one the panel enumerates.
///
/// Both axes come out of `SyntheticSizeCatalog` even-rounded, because a virtual
/// display's framebuffer is twice the logical size and an odd axis would put a
/// half pixel in it. The type does not enforce that; the catalog is the only
/// thing that should build these.
public struct SyntheticSize: Sendable, Equatable, Hashable {
  public let logicalWidth: Int
  public let logicalHeight: Int
  /// Which rung of `SyntheticSizeCatalog.stopPercents` this size came from.
  public let percentOfNative: Int

  /// The virtual display renders at exactly 2x, so the framebuffer is the
  /// logical size doubled. Phase 0 measured a 2x mint landing at scale 2.0 on
  /// the rig, so this is achieved shape rather than assumption.
  public var pixelWidth: Int { logicalWidth * 2 }
  public var pixelHeight: Int { logicalHeight * 2 }

  public init(logicalWidth: Int, logicalHeight: Int, percentOfNative: Int) {
    self.logicalWidth = logicalWidth
    self.logicalHeight = logicalHeight
    self.percentOfNative = percentOfNative
  }
}

/// The persisted form of a synthesized-size choice: logical geometry only. No
/// framebuffer and no refresh, unlike `DisplayModeDescriptor`, because a
/// synthesized row's framebuffer is derived (2x) and its refresh is a sentinel.
public struct SyntheticSizeDescriptor: Sendable, Equatable, Codable {
  public let logicalWidth: Int
  public let logicalHeight: Int

  public init(logicalWidth: Int, logicalHeight: Int) {
    self.logicalWidth = logicalWidth
    self.logicalHeight = logicalHeight
  }

  /// Spelled out rather than compiler-synthesized: these strings are an on-disk
  /// format, and a synthesized key tracks its property name, so a later rename
  /// would silently orphan stored preferences.
  private enum CodingKeys: String, CodingKey {
    case logicalWidth
    case logicalHeight
  }
}

/// The curated ladder of sizes Candela is willing to synthesize, and the
/// precedence rule that keeps it out of revelation's way.
///
/// Pure arithmetic over geometry: nothing here talks to CoreGraphics, so the
/// whole ladder is testable without a panel.
public enum SyntheticSizeCatalog {
  /// Fixed rather than open-ended: free width-by-height entry is a filed
  /// non-goal, so this is the whole space of sizes synthesis can offer.
  public static let stopPercents: [Int] = [95, 90, 85, 80, 75, 70, 65]

  /// How far a stop's aspect ratio may drift from native before it is dropped.
  /// Even-rounding both axes moves the ratio slightly; a stop that drifts past
  /// this would letterbox.
  private static let aspectTolerance = 0.02

  /// The window inside which an existing HiDPI row is considered to already
  /// serve a stop.
  private static let precedenceTolerance = 0.02

  /// Minor-axis floor in points. Below this a size stops being usable
  /// rather than merely large.
  private static let minorAxisFloor = 720

  /// The ladder for one panel, in descending percent order. A stop whose
  /// framebuffer lands exactly on the virtual-display ceiling survives; only
  /// exceeding it drops.
  public static func stops(
    nativeLogicalWidth: Int, nativeLogicalHeight: Int,
    existingRows: [DisplayMode],
    ceilingPixelWidth: Int, ceilingPixelHeight: Int
  ) -> [SyntheticSize] {
    guard nativeLogicalWidth > 0, nativeLogicalHeight > 0 else { return [] }
    let nativeAspect = Double(nativeLogicalWidth) / Double(nativeLogicalHeight)
    let served = existingRows.filter(\.isHiDPI)

    return stopPercents.compactMap { percent in
      let width = evenRounded(Double(nativeLogicalWidth) * Double(percent) / 100)
      let height = evenRounded(Double(nativeLogicalHeight) * Double(percent) / 100)
      guard width > 0, height > 0 else { return nil }

      let aspect = Double(width) / Double(height)
      guard abs(aspect - nativeAspect) / nativeAspect <= aspectTolerance else { return nil }
      guard width * 2 <= ceilingPixelWidth, height * 2 <= ceilingPixelHeight else { return nil }
      guard min(width, height) >= minorAxisFloor else { return nil }
      guard !served.contains(where: { serves($0, width: width, height: height) })
      else { return nil }

      return SyntheticSize(logicalWidth: width, logicalHeight: height,
                           percentOfNative: percent)
    }
  }

  /// The picker row for one stop.
  ///
  /// The `refreshHz: 0` sentinel is safe only because synthesized rows are
  /// appended after curation and never enter `DisplayModeCatalog.curated`,
  /// `DisplayModeList.deduplicated` or `ModePersistence.resolve`, none of which
  /// survive a zero rate.
  public static func row(for size: SyntheticSize) -> DisplayMode {
    DisplayMode(
      ioModeID: DisplayMode.syntheticIoModeID(stopIndex: stopIndex(forPercent: size.percentOfNative)),
      logicalWidth: size.logicalWidth, logicalHeight: size.logicalHeight,
      pixelWidth: size.pixelWidth, pixelHeight: size.pixelHeight,
      refreshHz: 0, isNative: false, provenance: .synthesized
    )
  }

  /// Re-find a stored choice in the ladder the current panel and rows generate.
  /// Regenerates rather than trusting the descriptor, so a size an older ladder
  /// produced, or one the precedence rule has taken over, resolves nil instead of
  /// engaging something the catalog would no longer offer.
  public static func size(
    matching descriptor: SyntheticSizeDescriptor,
    ofNativeWidth: Int, nativeHeight: Int,
    existingRows: [DisplayMode],
    ceilingPixelWidth: Int, ceilingPixelHeight: Int
  ) -> SyntheticSize? {
    stops(nativeLogicalWidth: ofNativeWidth, nativeLogicalHeight: nativeHeight,
          existingRows: existingRows,
          ceilingPixelWidth: ceilingPixelWidth, ceilingPixelHeight: ceilingPixelHeight)
      .first {
        $0.logicalWidth == descriptor.logicalWidth
          && $0.logicalHeight == descriptor.logicalHeight
      }
  }

  /// Non-negative for any percent, on or off the ladder, so the sentinel it
  /// feeds always comes out negative. An off-ladder percent lands past the
  /// ladder's last slot rather than colliding with a real stop's ID.
  static func stopIndex(forPercent percent: Int) -> Int {
    stopPercents.firstIndex(of: percent) ?? stopPercents.count
  }

  private static func serves(_ row: DisplayMode, width: Int, height: Int) -> Bool {
    within(precedenceTolerance, row.logicalWidth, of: width)
      && within(precedenceTolerance, row.logicalHeight, of: height)
  }

  private static func within(_ tolerance: Double, _ value: Int, of target: Int) -> Bool {
    Double(abs(value - target)) <= tolerance * Double(target)
  }

  /// Twin of `PanelDensityModel.evenRounded`, duplicated rather than shared:
  /// that one is private to a model this catalog must not depend on. Keep them
  /// in step.
  private static func evenRounded(_ value: Double) -> Int {
    Int((value / 2).rounded() * 2)
  }
}
