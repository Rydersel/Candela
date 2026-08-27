import Foundation

/// Turns already-loaded store values into a record. Reads nothing itself, so
/// every shape the file can take is reachable from a test.
public enum ProvenanceAssembler {
  public struct HoursInput: Codable, Equatable, Sendable {
    public let lifetimeSeconds: Double
    public let secondsSinceStandby: Double
    public init(lifetimeSeconds: Double, secondsSinceStandby: Double) {
      self.lifetimeSeconds = lifetimeSeconds
      self.secondsSinceStandby = secondsSinceStandby
    }
  }

  public struct ExposureInput: Codable, Equatable, Sendable {
    public let map: ExposureMap
    public let confidence: ProvenanceExposure.Confidence
    public let histogram: WearHistogram?
    public init(map: ExposureMap, confidence: ProvenanceExposure.Confidence, histogram: WearHistogram?) {
      self.map = map
      self.confidence = confidence
      self.histogram = histogram
    }
  }

  public static func assemble(
    identity: ProvenanceIdentity,
    hours: ProvenanceSection<HoursInput>,
    exposure: ProvenanceSection<ExposureInput>,
    checkups: [CheckupReportEnvelope],
    appBuild: String, macOSBuild: String, now: Date
  ) -> ProvenanceRecord {
    ProvenanceRecord(
      exportedAt: now, appBuild: appBuild, macOSBuild: macOSBuild, identity: identity,
      hours: hoursSection(hours),
      exposure: exposureSection(exposure),
      checkups: checkupsSection(checkups))
  }

  private static func hoursSection(_ input: ProvenanceSection<HoursInput>) -> ProvenanceSection<ProvenanceHours> {
    switch input {
    case .notCollected(let reason): return .notCollected(reason)
    case .collected(let h):
      return .collected(ProvenanceHours(
        lifetimeSeconds: Int(h.lifetimeSeconds.rounded(.down)),
        secondsSinceStandby: Int(h.secondsSinceStandby.rounded(.down))))
    }
  }

  private static func exposureSection(_ input: ProvenanceSection<ExposureInput>) -> ProvenanceSection<ProvenanceExposure> {
    switch input {
    case .notCollected(let reason): return .notCollected(reason)
    case .collected(let e):
      let histogramSeconds = e.histogram?.totalSeconds ?? 0
      // Nothing measured and nothing timed is an absence with a name, not a
      // section of zeros that reads as "measured: nothing happened".
      if e.map.sampleCount < ExposureAccumulator.minimumSamplesForAnalysis, histogramSeconds <= 0 {
        return .notCollected(.belowMinimumSamples)
      }
      return .collected(ProvenanceExposure(
        cells: normalized(e.map.cells),
        sampleCount: e.map.sampleCount,
        firstSample: e.map.firstSample,
        lastSample: e.map.lastSample,
        confidence: e.confidence,
        wearHistogram: e.histogram.map {
          ProvenanceWearHistogram(
            stateOrder: $0.stateNames, levelBuckets: $0.levelBuckets,
            seconds: $0.seconds.map { row in row.map { Int($0.rounded(.down)) } })
        }))
    }
  }

  private static func checkupsSection(_ runs: [CheckupReportEnvelope]) -> ProvenanceSection<ProvenanceCheckups> {
    guard !runs.isEmpty else { return .notCollected(.noRuns) }
    let ordered = runs.sorted { $0.report.startedAt < $1.report.startedAt }
    var counts: [String: Int] = [:]
    for run in ordered {
      let s = run.report.summary
      for (name, n) in [("observed", s.observed), ("refused", s.refused),
                        ("notObserved", s.notObserved), ("selfReported", s.selfReported),
                        ("inconclusive", s.inconclusive)] where n > 0 {
        counts[name, default: 0] += n
      }
    }
    return .collected(ProvenanceCheckups(runs: ordered, countsByVerdict: counts))
  }

  /// Against the map's own peak, the same scale the heat map draws.
  private static func normalized(_ cells: [Double]) -> [Double] {
    guard let peak = cells.max(), peak > 0 else { return cells }
    return cells.map { $0 / peak }
  }
}
