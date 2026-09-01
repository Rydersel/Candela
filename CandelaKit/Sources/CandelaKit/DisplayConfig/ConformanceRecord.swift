import Foundation

/// R-B: the verification ledger encodes the same `Report` the human-readable
/// lines come from, so the two forms cannot drift.
///
/// Two fields the printed lines never carried: the commit under test (a verdict
/// that outlives its build is how a fixed bug gets rediscovered weeks later),
/// and the positive-control outcome per check (a control that did not fire is a
/// third result, and without it the ledger reads the check as green).
extension PlatformConformance {
  public struct RunRecord: Codable, Sendable, Equatable {
    public struct CheckRecord: Codable, Sendable, Equatable {
      public let name: String
      /// "pass" | "fail" | "skip" | "inconclusive"
      public let outcome: String
      public let detail: String
      /// "fired" | "failed", or absent when the check carries no control.
      public let control: String?

      public init(name: String, outcome: String, detail: String, control: String?) {
        self.name = name
        self.outcome = outcome
        self.detail = detail
        self.control = control
      }
    }

    /// Bumped only when a reader would break; a reader checks it before
    /// trusting any other field here.
    public let schema: Int
    /// Which run produced this: "conform" or "regress".
    public let label: String
    public let platform: String
    public let timestamp: Date
    public let commit: String
    public let checks: [CheckRecord]
    public let passed: Int
    public let failed: Int
    public let skipped: Int
    public let inconclusive: Int

    public static let currentSchema = 1
  }
}

extension PlatformConformance.Outcome {
  /// The exhaustive split the record encodes: a new case must be given a name
  /// here rather than silently folding into an existing one.
  var recordFields: (outcome: String, detail: String) {
    switch self {
    case let .pass(detail): ("pass", detail)
    case let .fail(detail): ("fail", detail)
    case let .skip(reason): ("skip", reason)
    case let .inconclusive(detail): ("inconclusive", detail)
    }
  }
}

extension PlatformConformance.ControlOutcome {
  var recordValue: String {
    switch self {
    case .fired: "fired"
    case .failed: "failed"
    }
  }
}

extension PlatformConformance.Report {
  public func runRecord(label: String, commit: String, timestamp: Date)
    -> PlatformConformance.RunRecord
  {
    PlatformConformance.RunRecord(
      schema: PlatformConformance.RunRecord.currentSchema,
      label: label,
      platform: platform,
      timestamp: timestamp,
      commit: commit,
      checks: checks.map { check in
        let fields = check.outcome.recordFields
        return .init(
          name: check.name,
          outcome: fields.outcome,
          detail: fields.detail,
          control: check.control?.recordValue
        )
      },
      passed: passed,
      failed: failed,
      skipped: skipped,
      inconclusive: inconclusive
    )
  }

  /// Sorted keys and an ISO 8601 stamp: the ledger is committed, so two runs of
  /// the same shape must diff as one changed line, not a reshuffled object.
  public func jsonData(label: String, commit: String, timestamp: Date) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(runRecord(label: label, commit: commit, timestamp: timestamp))
  }
}
