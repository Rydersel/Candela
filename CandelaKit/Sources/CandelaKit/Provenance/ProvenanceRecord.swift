import Foundation

/// Why a section is empty. Raw values are file schema: add cases, never rename.
public enum ProvenanceAbsence: String, Codable, Equatable, Sendable, CaseIterable {
  case notEnrolled, trackingOff, belowMinimumSamples, noRuns

  public var sentence: String {
    switch self {
    case .notEnrolled: "Not collected: this display is not enrolled in OLED care."
    case .trackingOff: "Not collected: hours tracking is off for this display."
    case .belowMinimumSamples: "Not collected: too few readings have accumulated to report."
    case .noRuns: "Not collected: no checkup has been run on this display."
    }
  }
}

/// A section is present or it says why it is not. A missing key would read as
/// "Candela never looked", which is a different claim from "looked, nothing to
/// report".
public enum ProvenanceSection<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
  case collected(Value)
  case notCollected(ProvenanceAbsence)

  /// `notCollected` is a reserved name across every `Value`: a payload type that
  /// used it as a property name would decode as an absence instead of itself.
  private enum Keys: String, CodingKey { case notCollected }

  /// An unrecognized reason fails the whole decode rather than folding into an
  /// "unknown" case. A fallback case would re-encode to a different raw value
  /// and break the record's hash, and "this build cannot read this file" is the
  /// honest verdict when an older Candela meets a newer record.
  public init(from decoder: Decoder) throws {
    if let keyed = try? decoder.container(keyedBy: Keys.self),
      let reason = try keyed.decodeIfPresent(ProvenanceAbsence.self, forKey: .notCollected) {
      self = .notCollected(reason)
    } else {
      self = .collected(try Value(from: decoder))
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .collected(let value):
      try value.encode(to: encoder)
    case .notCollected(let reason):
      var keyed = encoder.container(keyedBy: Keys.self)
      try keyed.encode(reason, forKey: .notCollected)
    }
  }

  public var value: Value? {
    if case .collected(let v) = self { return v }
    return nil
  }

  public var absence: ProvenanceAbsence? {
    if case .notCollected(let r) = self { return r }
    return nil
  }
}

public struct ProvenanceHours: Codable, Equatable, Sendable {
  public let lifetimeSeconds: Int
  public let secondsSinceStandby: Int
  public init(lifetimeSeconds: Int, secondsSinceStandby: Int) {
    self.lifetimeSeconds = lifetimeSeconds
    self.secondsSinceStandby = secondsSinceStandby
  }
}

public struct ProvenanceWearHistogram: Codable, Equatable, Sendable {
  public let stateOrder: [String]
  public let levelBuckets: Int
  public let seconds: [[Int]]
  public init(stateOrder: [String], levelBuckets: Int, seconds: [[Int]]) {
    self.stateOrder = stateOrder
    self.levelBuckets = levelBuckets
    self.seconds = seconds
  }
}

public struct ProvenanceExposure: Codable, Equatable, Sendable {
  public enum Confidence: String, Codable, Equatable, Sendable {
    case measured, estimated, insufficient
  }
  public let cells: [Double]
  public let sampleCount: Int
  public let firstSample: Date?
  public let lastSample: Date?
  public let confidence: Confidence
  public let wearHistogram: ProvenanceWearHistogram?
  public init(cells: [Double], sampleCount: Int, firstSample: Date?, lastSample: Date?,
              confidence: Confidence, wearHistogram: ProvenanceWearHistogram?) {
    self.cells = cells
    self.sampleCount = sampleCount
    self.firstSample = firstSample
    self.lastSample = lastSample
    self.confidence = confidence
    self.wearHistogram = wearHistogram
  }
}

public struct ProvenanceHardware: Codable, Equatable, Sendable {
  public let transport: String?
  public let manufacturerID: String?
  public let alphanumericSerial: String?
  /// nil for 0, which the MAG reports: "no serial", not serial number zero.
  public let numericSerial: Int64?
  public let physicalWidthCm: Int?
  public let physicalHeightCm: Int?
  public init(transport: String?, manufacturerID: String?, alphanumericSerial: String?,
              numericSerial: Int64?, physicalWidthCm: Int?, physicalHeightCm: Int?) {
    self.transport = transport
    self.manufacturerID = manufacturerID
    self.alphanumericSerial = alphanumericSerial
    self.numericSerial = numericSerial
    self.physicalWidthCm = physicalWidthCm
    self.physicalHeightCm = physicalHeightCm
  }
}

public struct ProvenanceIdentity: Codable, Equatable, Sendable {
  public let persistenceKey: String
  public let displayName: String
  public let edid: CheckupDisplayIdentity?
  public let hardware: ProvenanceHardware?
  public init(persistenceKey: String, displayName: String, edid: CheckupDisplayIdentity?,
              hardware: ProvenanceHardware?) {
    self.persistenceKey = persistenceKey
    self.displayName = displayName
    self.edid = edid
    self.hardware = hardware
  }
}

public struct ProvenanceCheckups: Codable, Equatable, Sendable {
  public let runs: [CheckupReportEnvelope]
  /// Keyed by verdict name. Counts only; nothing here is ever a grade.
  public let countsByVerdict: [String: Int]
  public init(runs: [CheckupReportEnvelope], countsByVerdict: [String: Int]) {
    self.runs = runs
    self.countsByVerdict = countsByVerdict
  }
}

/// One panel's record. Every key is file schema.
public struct ProvenanceRecord: Codable, Equatable, Sendable {
  public static let headerSentences: [String] = [
    "This record was produced by Candela on the owner's Mac from the app's own measurements. The data is self-reported.",
    "The hash in this file detects alteration after export. It does not certify who produced the file.",
    "This record collects observations. It does not certify the display.",
  ]

  public let header: [String]
  public let exportedAt: Date
  public let appBuild: String
  public let macOSBuild: String
  public let identity: ProvenanceIdentity
  public let hours: ProvenanceSection<ProvenanceHours>
  public let exposure: ProvenanceSection<ProvenanceExposure>
  public let checkups: ProvenanceSection<ProvenanceCheckups>

  public init(exportedAt: Date, appBuild: String, macOSBuild: String, identity: ProvenanceIdentity,
              hours: ProvenanceSection<ProvenanceHours>,
              exposure: ProvenanceSection<ProvenanceExposure>,
              checkups: ProvenanceSection<ProvenanceCheckups>) {
    self.header = Self.headerSentences
    self.exportedAt = exportedAt
    self.appBuild = appBuild
    self.macOSBuild = macOSBuild
    self.identity = identity
    self.hours = hours
    self.exposure = exposure
    self.checkups = checkups
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case header, exportedAt, appBuild, macOSBuild, identity, hours, exposure, checkups
  }

  public static let knownBodyKeys: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

  /// Hand-written so a key added after a file was written decodes as its
  /// default instead of failing the whole file.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    header = try c.decodeIfPresent([String].self, forKey: .header) ?? Self.headerSentences
    exportedAt = try c.decode(Date.self, forKey: .exportedAt)
    appBuild = try c.decodeIfPresent(String.self, forKey: .appBuild) ?? ""
    macOSBuild = try c.decodeIfPresent(String.self, forKey: .macOSBuild) ?? ""
    identity = try c.decode(ProvenanceIdentity.self, forKey: .identity)
    hours = try c.decode(ProvenanceSection<ProvenanceHours>.self, forKey: .hours)
    exposure = try c.decode(ProvenanceSection<ProvenanceExposure>.self, forKey: .exposure)
    checkups = try c.decode(ProvenanceSection<ProvenanceCheckups>.self, forKey: .checkups)
  }

  public func encode(to encoder: Encoder) throws {
    try encode(to: encoder, keys: Self.knownBodyKeys)
  }

  /// Writes only `keys`. The digest covers exactly the keys a stored body
  /// carried; writing back a defaulted key would break its hash.
  func encode(to encoder: Encoder, keys: Set<String>) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    func wanted(_ key: CodingKeys) -> Bool { keys.contains(key.stringValue) }
    if wanted(.header) { try c.encode(header, forKey: .header) }
    if wanted(.exportedAt) { try c.encode(exportedAt, forKey: .exportedAt) }
    if wanted(.appBuild) { try c.encode(appBuild, forKey: .appBuild) }
    if wanted(.macOSBuild) { try c.encode(macOSBuild, forKey: .macOSBuild) }
    if wanted(.identity) { try c.encode(identity, forKey: .identity) }
    if wanted(.hours) { try c.encode(hours, forKey: .hours) }
    if wanted(.exposure) { try c.encode(exposure, forKey: .exposure) }
    if wanted(.checkups) { try c.encode(checkups, forKey: .checkups) }
  }
}
