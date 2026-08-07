/// Health-view-ready snapshot of one panel's exposure and window attribution.
///
/// **OC11** — every value here reduces to *measured relative exposure* or
/// *what is on screen right now*. This type must never gain a lifespan
/// figure, a predicted date, a "% burn-in prevented" or a risk score.
public struct PanelHealthSummary: Sendable {
  public enum Confidence: Equatable, Sendable {
    /// Telemetry on, `sampleCount` at or past
    /// `ExposureAccumulator.minimumSamplesForAnalysis`.
    case measured
    /// Telemetry off — window geometry only, so there is no exposure number
    /// to show, however much history the map happens to be carrying.
    case estimated
    /// Telemetry on, but not enough samples yet to say anything.
    case insufficient
  }

  public let confidence: Confidence

  /// 240 cells, panel-native order, each normalized against this map's own
  /// peak — 1.0 is the hottest cell this map has seen, not an absolute
  /// luminance unit. All zero when nothing has accumulated yet.
  public let cells: [Double]

  /// The hottest cell's exposure as a multiple of the panel mean. Nil unless
  /// `confidence == .measured`: `.estimated` has no exposure telemetry to
  /// speak from and `.insufficient` has too little of it, regardless of what
  /// the underlying map happens to contain.
  public let hottestRelative: Double?

  /// The app dominating the hottest cell, from the same snapshot used for
  /// `hottestRelative`. Nil under the same conditions, or when no observation
  /// was supplied, or when that cell has no dominant owner.
  public let hottestOwner: String?

  /// Always empty today. Populating it honestly needs a measured per-owner
  /// time series — how many seconds each app has actually occupied the
  /// screen — and neither `ExposureMap` (per-cell, not per-owner) nor a
  /// single `WindowObservation` (one instant, not a duration) carries that.
  /// `PanelHoursTracker` is the closest existing type and it tracks only the
  /// panel's total hours, not a per-app breakdown. Left in the shape the
  /// summary commits to, rather than dropped, so a consumer can render
  /// "no data yet" instead of a missing field — but nothing here should
  /// invent a number to fill it.
  public let topOwnersByHours: [(owner: String, hours: Double)]

  public static func make(
    map: ExposureMap,
    observation: WindowObservation?,
    telemetryEnabled: Bool,
    sampleCount: Int
  ) -> PanelHealthSummary {
    let confidence = confidence(telemetryEnabled: telemetryEnabled, sampleCount: sampleCount)

    var hottestRelative: Double?
    var hottestOwner: String?
    if confidence == .measured, let hottest = map.hottestCell {
      hottestRelative = map.relativeExposure(atCell: hottest)
      if let owners = observation?.dominantOwnerByCell, owners.indices.contains(hottest) {
        hottestOwner = owners[hottest]
      }
    }

    return PanelHealthSummary(
      confidence: confidence,
      cells: normalized(map.cells),
      hottestRelative: hottestRelative,
      hottestOwner: hottestOwner,
      topOwnersByHours: [])
  }

  private static func confidence(telemetryEnabled: Bool, sampleCount: Int) -> Confidence {
    guard telemetryEnabled else { return .estimated }
    guard sampleCount >= ExposureAccumulator.minimumSamplesForAnalysis else { return .insufficient }
    return .measured
  }

  /// Each cell relative to this map's own peak, not an absolute luminance
  /// scale — the health view draws a heat map, not a light meter. All zero,
  /// rather than dividing by zero, when the map has no peak yet.
  private static func normalized(_ cells: [Double]) -> [Double] {
    guard let peak = cells.max(), peak > 0 else {
      return [Double](repeating: 0, count: cells.count)
    }
    return cells.map { $0 / peak }
  }
}

extension PanelHealthSummary: Equatable {
  // Synthesized `Equatable` cannot cover `topOwnersByHours`: a bare tuple
  // does not conform to `Equatable`, so `[(owner: String, hours: Double)]`
  // does not satisfy `Array`'s conditional conformance and the compiler has
  // no synthesis to fall back on.
  public static func == (lhs: PanelHealthSummary, rhs: PanelHealthSummary) -> Bool {
    lhs.confidence == rhs.confidence
      && lhs.cells == rhs.cells
      && lhs.hottestRelative == rhs.hottestRelative
      && lhs.hottestOwner == rhs.hottestOwner
      && lhs.topOwnersByHours.count == rhs.topOwnersByHours.count
      && zip(lhs.topOwnersByHours, rhs.topOwnersByHours).allSatisfy {
        $0.owner == $1.owner && $0.hours == $1.hours
      }
  }
}
