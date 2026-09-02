import Foundation

public struct CheckupDisplayIdentity: Codable, Equatable, Sendable {
  public let identityKey: String
  public let vendorID: UInt32
  public let modelID: UInt32
  /// The literal "no serial reported" when the display reports none.
  public let serial: String
  public let manufactureWeek: Int?
  public let manufactureYear: Int?
  public let nativePixelWidth: Int
  public let nativePixelHeight: Int
  public let maxRefreshHz: Double?
  public let supportsPQEOTF: Bool
  public let supportsHDRGammaEOTF: Bool
  public let productName: String

  public static let noSerial = "no serial reported"

  public init(identityKey: String, vendorID: UInt32, modelID: UInt32, serial: String?,
              manufactureWeek: Int?, manufactureYear: Int?, nativePixelWidth: Int,
              nativePixelHeight: Int, maxRefreshHz: Double?, supportsPQEOTF: Bool,
              supportsHDRGammaEOTF: Bool, productName: String) {
    self.identityKey = identityKey
    self.vendorID = vendorID
    self.modelID = modelID
    self.serial = serial.flatMap { $0.isEmpty ? nil : $0 } ?? Self.noSerial
    self.manufactureWeek = manufactureWeek
    self.manufactureYear = manufactureYear
    self.nativePixelWidth = nativePixelWidth
    self.nativePixelHeight = nativePixelHeight
    self.maxRefreshHz = maxRefreshHz
    self.supportsPQEOTF = supportsPQEOTF
    self.supportsHDRGammaEOTF = supportsHDRGammaEOTF
    self.productName = productName
  }
}

public struct CheckupPlantRecord: Codable, Equatable, Sendable {
  /// Always true; recorded so the file itself states the control was disclosed.
  public let disclosed: Bool
  public let detectedAtPixels: Int?
  public let missed: Bool
  public init(disclosed: Bool, detectedAtPixels: Int?, missed: Bool) {
    self.disclosed = disclosed
    self.detectedAtPixels = detectedAtPixels
    self.missed = missed
  }
}

public enum CheckupCompletion: Codable, Equatable, Sendable {
  case complete
  case incomplete(reason: String)
}

public struct CheckupSummary: Equatable, Sendable {
  public var observed = 0, refused = 0, notObserved = 0, selfReported = 0, inconclusive = 0
  public var controlDetectedAt: Int?
  public var controlMissed = false
  public var demonstratedSomething: Bool { observed > 0 || refused > 0 }

  public var line: String {
    var parts = ["\(observed) observed", "\(refused) refused",
                 "\(notObserved) not observed on this panel class",
                 "\(selfReported) self-reported"]
    if inconclusive > 0 { parts.append("\(inconclusive) inconclusive") }
    if let px = controlDetectedAt { parts.append("control detected at \(px) px") }
    if controlMissed { parts.append("control not detected") }
    var line = parts.joined(separator: ", ")
    if !demonstratedSomething { line += "; nothing was measured on this run" }
    return line
  }
}

public struct CheckupReport: Codable, Equatable, Sendable {
  public static let headerSentence =
    "This report records observations made with Candela on the stated date; it does not certify the display."

  public var header: String = CheckupReport.headerSentence
  public var scenario: CheckupScenario
  public var identity: CheckupDisplayIdentity
  public var panelClass: CheckupPanelClass
  public var macOSBuild: String
  public var appBuild: String
  public var startedAt: Date
  public var endedAt: Date?
  public var completion: CheckupCompletion
  public var claims: [CheckupClaim]
  public var plant: CheckupPlantRecord?
  /// Showings per field id; the cap is CheckupPlan.maxShowingsPerField.
  public var showings: [String: Int]
  public var exposureBookingID: String?
  /// Fields whose lower edge carried the instruction strip because the
  /// target was the only display. A reader must know which fields were not the whole panel.
  public var partiallyOccludedFields: [String]

  public init(scenario: CheckupScenario, identity: CheckupDisplayIdentity,
              panelClass: CheckupPanelClass, macOSBuild: String, appBuild: String,
              startedAt: Date, endedAt: Date?, completion: CheckupCompletion,
              claims: [CheckupClaim], plant: CheckupPlantRecord?, showings: [String: Int],
              exposureBookingID: String?, partiallyOccludedFields: [String] = []) {
    self.scenario = scenario
    self.identity = identity
    self.panelClass = panelClass
    self.macOSBuild = macOSBuild
    self.appBuild = appBuild
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.completion = completion
    self.claims = claims
    self.plant = plant
    self.showings = showings
    self.exposureBookingID = exposureBookingID
    self.partiallyOccludedFields = partiallyOccludedFields
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case header, scenario, identity, panelClass, macOSBuild, appBuild, startedAt, endedAt,
         completion, claims, plant, showings, exposureBookingID, partiallyOccludedFields
  }

  /// Every body key this build knows. A stored body with a key outside it was
  /// not written by a Candela of this vintage.
  public static let knownBodyKeys = Set(CodingKeys.allCases.map(\.stringValue))

  /// Hand-written so a key added after a file was written decodes as its
  /// default.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    header = try c.decodeIfPresent(String.self, forKey: .header) ?? Self.headerSentence
    scenario = try c.decode(CheckupScenario.self, forKey: .scenario)
    identity = try c.decode(CheckupDisplayIdentity.self, forKey: .identity)
    panelClass = try c.decode(CheckupPanelClass.self, forKey: .panelClass)
    macOSBuild = try c.decode(String.self, forKey: .macOSBuild)
    appBuild = try c.decode(String.self, forKey: .appBuild)
    startedAt = try c.decode(Date.self, forKey: .startedAt)
    endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
    completion = try c.decode(CheckupCompletion.self, forKey: .completion)
    claims = try c.decode([CheckupClaim].self, forKey: .claims)
    plant = try c.decodeIfPresent(CheckupPlantRecord.self, forKey: .plant)
    showings = try c.decode([String: Int].self, forKey: .showings)
    exposureBookingID = try c.decodeIfPresent(String.self, forKey: .exposureBookingID)
    partiallyOccludedFields =
      try c.decodeIfPresent([String].self, forKey: .partiallyOccludedFields) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    try encode(to: encoder, keys: Self.knownBodyKeys)
  }

  /// Writes only `keys`. The digest has to cover exactly the keys a stored body
  /// carried; writing back a key that decode defaulted would break its hash.
  func encode(to encoder: Encoder, keys: Set<String>) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    func wanted(_ key: CodingKeys) -> Bool { keys.contains(key.stringValue) }
    if wanted(.header) { try c.encode(header, forKey: .header) }
    if wanted(.scenario) { try c.encode(scenario, forKey: .scenario) }
    if wanted(.identity) { try c.encode(identity, forKey: .identity) }
    if wanted(.panelClass) { try c.encode(panelClass, forKey: .panelClass) }
    if wanted(.macOSBuild) { try c.encode(macOSBuild, forKey: .macOSBuild) }
    if wanted(.appBuild) { try c.encode(appBuild, forKey: .appBuild) }
    if wanted(.startedAt) { try c.encode(startedAt, forKey: .startedAt) }
    if wanted(.endedAt) { try c.encodeIfPresent(endedAt, forKey: .endedAt) }
    if wanted(.completion) { try c.encode(completion, forKey: .completion) }
    if wanted(.claims) { try c.encode(claims, forKey: .claims) }
    if wanted(.plant) { try c.encodeIfPresent(plant, forKey: .plant) }
    if wanted(.showings) { try c.encode(showings, forKey: .showings) }
    if wanted(.exposureBookingID) {
      try c.encodeIfPresent(exposureBookingID, forKey: .exposureBookingID)
    }
    if wanted(.partiallyOccludedFields) {
      try c.encode(partiallyOccludedFields, forKey: .partiallyOccludedFields)
    }
  }

  public var summary: CheckupSummary {
    var s = CheckupSummary()
    for claim in claims {
      switch claim.verdict {
      case .observed: s.observed += 1
      case .refused: s.refused += 1
      case .notObserved: s.notObserved += 1
      case .selfReported: s.selfReported += 1
      case .inconclusive: s.inconclusive += 1
      }
    }
    s.controlDetectedAt = plant?.detectedAtPixels
    s.controlMissed = plant?.missed ?? false
    return s
  }

  public var demonstratedSomething: Bool { summary.demonstratedSomething }
}

/// The exported file. The hash covers the canonical body, so a hand edit
/// anywhere in it fails `validate()`.
public struct CheckupReportEnvelope: Codable, Equatable, Sendable {
  public static let schemaVersion = 1
  public let schemaVersion: Int
  public let report: CheckupReport
  public let sha256: String
  /// Keys the source file carried, or every known key when built in memory. The
  /// digest and any re-encode use it, so adding a key needs no version bump.
  let bodyKeys: Set<String>

  enum CodingKeys: String, CodingKey { case schemaVersion, report, sha256 }

  /// Reads the keys a stored body has, including any this build does not know.
  private struct BodyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  private struct Body: Encodable {
    let report: CheckupReport
    let keys: Set<String>
    func encode(to encoder: Encoder) throws { try report.encode(to: encoder, keys: keys) }
  }

  public init(report: CheckupReport) throws {
    self.schemaVersion = Self.schemaVersion
    self.report = report
    self.bodyKeys = CheckupReport.knownBodyKeys
    self.sha256 = try Self.digest(report, keys: CheckupReport.knownBodyKeys)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    report = try c.decode(CheckupReport.self, forKey: .report)
    sha256 = try c.decode(String.self, forKey: .sha256)
    bodyKeys = Set(try c.nestedContainer(keyedBy: BodyKey.self, forKey: .report)
      .allKeys.map(\.stringValue))
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encode(Body(report: report, keys: bodyKeys), forKey: .report)
    try c.encode(sha256, forKey: .sha256)
  }

  /// `bodyKeys` records where the value came from, not what it says, so it is
  /// left out here.
  public static func == (lhs: CheckupReportEnvelope, rhs: CheckupReportEnvelope) -> Bool {
    lhs.schemaVersion == rhs.schemaVersion && lhs.report == rhs.report
      && lhs.sha256 == rhs.sha256
  }

  public func validate() -> Bool {
    // Decoding ignores an unknown key, but Candela never wrote one, so a body
    // carrying one was edited.
    guard bodyKeys.isSubset(of: CheckupReport.knownBodyKeys) else { return false }
    return (try? Self.digest(report, keys: bodyKeys)) == sha256
  }

  public static func canonicalData(
    _ report: CheckupReport, keys: Set<String> = CheckupReport.knownBodyKeys
  ) throws -> Data {
    try CanonicalDigest.canonicalData(Body(report: report, keys: keys))
  }

  static func digest(_ report: CheckupReport,
                     keys: Set<String> = CheckupReport.knownBodyKeys) throws -> String {
    try CanonicalDigest.sha256Hex(Body(report: report, keys: keys))
  }
}
