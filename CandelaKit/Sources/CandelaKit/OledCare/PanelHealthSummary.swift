import Foundation

/// Health-view-ready snapshot of one panel's exposure and window attribution.
///
/// **Relative exposure only**: every value here reduces to measured relative
/// exposure, what is on screen right now, or measured panel-time
/// attributable to an app. This type
/// must never gain a lifespan figure, a predicted date or a risk score.
public struct PanelHealthSummary: Sendable {
  public enum Confidence: Equatable, Sendable {
    /// Telemetry on, `sampleCount` at or past
    /// `ExposureAccumulator.minimumSamplesForAnalysis`.
    case measured
    /// Telemetry off: window geometry only, so there is no exposure number to
    /// show, whatever history the map is carrying.
    case estimated
    /// Telemetry on, but not enough samples yet to say anything.
    case insufficient
  }

  public let confidence: Confidence

  /// Whether window observation is currently recording for this display.
  ///
  /// Separate from `confidence`, which describes luminance telemetry only. Both
  /// are prefs and either can be off alone, so with both off the honest
  /// statement is "nothing", not "window geometry is what is left".
  public let observationEnabled: Bool

  /// Panel-native order, each cell normalized against this map's own peak: 1.0
  /// is the hottest cell this map has seen, not an absolute luminance unit. All
  /// zero when nothing has accumulated yet.
  ///
  /// **Populated regardless of `confidence`**: this is accumulated history, and
  /// a display whose telemetry was switched off after a month still HAS that
  /// month. Whether it may be DRAWN is the caller's call, since a heat map
  /// implies a currency `.estimated` cannot support. A caller that blanks it
  /// must not also say nothing was measured.
  public let cells: [Double]

  /// The hottest cell's exposure as a multiple of the panel mean. Nil unless
  /// `confidence == .measured`, whatever the underlying map contains.
  public let hottestRelative: Double?

  /// The app dominating the hottest cell, from the same snapshot used for
  /// `hottestRelative`. Nil under the same conditions, or when no observation
  /// was supplied, or when that cell has no dominant owner.
  ///
  /// **Also nil whenever `observationEnabled` is false**, however recent the
  /// snapshot looks. The coordinator keeps the last observation for the life of
  /// the process after the pref goes off, so without this gate a surface would
  /// keep naming an app the user stopped us watching, hours after it quit.
  public let hottestOwner: String?

  /// Readings folded into the map so far. Drives the progress-to-analysis
  /// line and the telemetry ticker; it is a count, not a claim.
  public let sampleCount: Int

  /// When the last reading landed, nil before the first. The live-measurement
  /// pulse keys off this so it can only breathe while readings arrive; keyed off
  /// the prefs alone it would animate through a dead Screen Recording grant.
  public let lastSample: Date?

  /// Per-cell dominant owner from the latest observation, for the hover readout.
  /// Nil whenever `observationEnabled` is false, for `hottestOwner`'s reason
  /// exactly: naming an app the user stopped us watching is a claim with no
  /// producer.
  public let dominantOwnerByCell: [String?]?

  /// The heaviest apps by **panel-hours attributable to them**, not wall-clock
  /// hours the app was open: an app covering a quarter of the panel books
  /// fifteen minutes per hour. Copy must not say "Slack was open for 340 hours"
  /// (the relative-exposure-only rule).
  ///
  /// Independent of `confidence`. Per-owner hours come from window observation,
  /// a separate pref needing no permission, so this can be populated while
  /// confidence is `.estimated` and empty while it is `.measured`.
  public let topOwnersByHours: [(owner: String, hours: Double)]

  /// How many owners `make` carries through. The health view shows a short
  /// leaderboard, not a process list; the tail is noise a user cannot act on.
  public static let topOwnerLimit = 5

  /// `sampleCount` is read off `map` rather than passed alongside it. As a
  /// separate parameter it was a second source of truth: `make(map: .empty, …,
  /// sampleCount: 999)` answered `.measured` over an all-zero heat map.
  public static func make(
    map: ExposureMap,
    observation: WindowObservation?,
    ownerHours: OwnerHours,
    telemetryEnabled: Bool,
    observationEnabled: Bool
  ) -> PanelHealthSummary {
    let confidence = confidence(telemetryEnabled: telemetryEnabled, map: map)

    var hottestRelative: Double?
    var hottestOwner: String?
    if confidence == .measured, let hottest = map.hottestCell {
      hottestRelative = map.relativeExposure(atCell: hottest)
      if observationEnabled,
        let owners = observation?.dominantOwnerByCell, owners.indices.contains(hottest) {
        hottestOwner = owners[hottest]
      }
    }

    return PanelHealthSummary(
      confidence: confidence,
      observationEnabled: observationEnabled,
      cells: normalized(map.cells),
      hottestRelative: hottestRelative,
      hottestOwner: hottestOwner,
      sampleCount: map.sampleCount,
      lastSample: map.lastSample,
      dominantOwnerByCell: observationEnabled ? observation?.dominantOwnerByCell : nil,
      topOwnersByHours: ownerHours.topOwners(limit: topOwnerLimit))
  }

  /// Defers to `ExposureAccumulator.hasEnoughSamplesForAnalysis` rather than
  /// re-comparing the threshold, so there is one spelling of the rule.
  private static func confidence(telemetryEnabled: Bool, map: ExposureMap) -> Confidence {
    guard telemetryEnabled else { return .estimated }
    guard ExposureAccumulator(map: map).hasEnoughSamplesForAnalysis else { return .insufficient }
    return .measured
  }

  /// Each cell relative to this map's own peak, not an absolute luminance
  /// scale: the health view draws a heat map, not a light meter. All zero,
  /// rather than dividing by zero, when the map has no peak yet.
  private static func normalized(_ cells: [Double]) -> [Double] {
    guard let peak = cells.max(), peak > 0 else {
      return [Double](repeating: 0, count: cells.count)
    }
    return cells.map { $0 / peak }
  }
}

extension PanelHealthSummary: Equatable {
  // Synthesized `Equatable` cannot cover `topOwnersByHours`: a bare tuple is
  // not `Equatable`, so the array misses `Array`'s conditional conformance.
  public static func == (lhs: PanelHealthSummary, rhs: PanelHealthSummary) -> Bool {
    lhs.confidence == rhs.confidence
      && lhs.observationEnabled == rhs.observationEnabled
      && lhs.cells == rhs.cells
      && lhs.hottestRelative == rhs.hottestRelative
      && lhs.hottestOwner == rhs.hottestOwner
      && lhs.sampleCount == rhs.sampleCount
      && lhs.lastSample == rhs.lastSample
      && lhs.dominantOwnerByCell == rhs.dominantOwnerByCell
      && lhs.topOwnersByHours.count == rhs.topOwnersByHours.count
      && zip(lhs.topOwnersByHours, rhs.topOwnersByHours).allSatisfy {
        $0.owner == $1.owner && $0.hours == $1.hours
      }
  }
}
