import Foundation

/// Health-view-ready snapshot of one panel's exposure and window attribution.
///
/// **OC11** — every value here reduces to *measured relative exposure*, *what
/// is on screen right now*, or *measured panel-time attributable to an app*.
/// This type must never gain a lifespan figure, a predicted date, a "%
/// burn-in prevented" or a risk score.
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

  /// Whether window observation is currently recording for this display.
  ///
  /// Separate from `confidence`, which describes luminance telemetry only.
  /// Both are prefs and either can be off alone, so a surface that says what is
  /// being recorded needs both: with telemetry off and observation off, the
  /// honest statement is "nothing", and stating "window geometry is what is
  /// left" describes a producer that is not running.
  public let observationEnabled: Bool

  /// 240 cells, panel-native order, each normalized against this map's own
  /// peak — 1.0 is the hottest cell this map has seen, not an absolute
  /// luminance unit. All zero when nothing has accumulated yet.
  ///
  /// **Populated regardless of `confidence`**, deliberately: this is the
  /// accumulated history, and a display whose telemetry was switched off after
  /// a month still HAS that month. Whether it may be DRAWN is a separate
  /// question the caller answers, because drawing an exposure heat map implies
  /// a currency the `.estimated` state cannot support. A caller that blanks it
  /// must not also say nothing was measured.
  public let cells: [Double]

  /// The hottest cell's exposure as a multiple of the panel mean. Nil unless
  /// `confidence == .measured`: `.estimated` has no exposure telemetry to
  /// speak from and `.insufficient` has too little of it, regardless of what
  /// the underlying map happens to contain.
  public let hottestRelative: Double?

  /// The app dominating the hottest cell, from the same snapshot used for
  /// `hottestRelative`. Nil under the same conditions, or when no observation
  /// was supplied, or when that cell has no dominant owner.
  ///
  /// **Also nil whenever `observationEnabled` is false**, however recent the
  /// snapshot looks. The coordinator keeps the last observation for the life of
  /// the process after the pref goes off, so without this gate a surface saying
  /// "X is on that part of the display right now" would keep naming an app the
  /// user stopped us watching, possibly hours after it quit.
  public let hottestOwner: String?

  /// Readings folded into the map so far. Drives the progress-to-analysis
  /// line and the telemetry ticker; it is a count, not a claim.
  public let sampleCount: Int

  /// When the last reading landed, nil before the first. The live-measurement
  /// pulse keys off this so it can only breathe while readings genuinely
  /// arrive; a pulse keyed off the prefs alone would keep animating through a
  /// dead Screen Recording grant, which is this project's most repeated lie.
  public let lastSample: Date?

  /// Per-cell dominant owner from the latest observation, for the hover
  /// inspection readout. Nil whenever `observationEnabled` is false, the
  /// `hottestOwner` gate's reason exactly: the coordinator keeps the last
  /// observation for the life of the process, and naming an app the user
  /// stopped us watching is a claim without a producer.
  public let dominantOwnerByCell: [String?]?

  /// The heaviest apps by **panel-hours attributable to them** — *not*
  /// wall-clock hours the app was open. A full-screen app books an hour per
  /// hour; an app covering a quarter of the panel books fifteen minutes per
  /// hour. Copy rendering this must not say "Slack was open for 340 hours"
  /// (OC11: a number the UI would be read as claiming something it does not
  /// measure).
  ///
  /// Independent of `confidence`, which describes the luminance telemetry
  /// only. Per-owner hours come from window observation, which is a separate
  /// pref and needs no permission, so this can be populated while confidence
  /// is `.estimated` and empty while it is `.measured`.
  public let topOwnersByHours: [(owner: String, hours: Double)]

  /// How many owners `make` carries through. The health view shows a short
  /// leaderboard, not a process list; the tail is noise a user cannot act on.
  public static let topOwnerLimit = 5

  /// `sampleCount` is read off `map` rather than passed alongside it. It was a
  /// separate parameter, which made two sources of truth for one number and let
  /// `make(map: .empty, …, sampleCount: 999)` answer `.measured` over an empty
  /// map — a non-blank, all-zero heat map presented as measured. No caller did
  /// that, and none can now.
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
  /// re-comparing against the threshold. The two used to be separate spellings
  /// of one rule, and the accumulator's had no production caller at all.
  private static func confidence(telemetryEnabled: Bool, map: ExposureMap) -> Confidence {
    guard telemetryEnabled else { return .estimated }
    guard ExposureAccumulator(map: map).hasEnoughSamplesForAnalysis else { return .insufficient }
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
