import CryptoKit
import Foundation

public struct CheckupDisplayIdentity: Codable, Equatable, Sendable {
  public let identityKey: String
  public let vendorID: UInt32
  public let modelID: UInt32
  /// The literal "no serial reported" when the display reports none (CK6).
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

  public init(scenario: CheckupScenario, identity: CheckupDisplayIdentity,
              panelClass: CheckupPanelClass, macOSBuild: String, appBuild: String,
              startedAt: Date, endedAt: Date?, completion: CheckupCompletion,
              claims: [CheckupClaim], plant: CheckupPlantRecord?, showings: [String: Int],
              exposureBookingID: String?) {
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

  public init(report: CheckupReport) throws {
    self.schemaVersion = Self.schemaVersion
    self.report = report
    self.sha256 = try Self.digest(report)
  }

  public func validate() -> Bool {
    (try? Self.digest(report)) == sha256
  }

  public static func canonicalData(_ report: CheckupReport) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(report)
  }

  static func digest(_ report: CheckupReport) throws -> String {
    SHA256.hash(data: try canonicalData(report)).map { String(format: "%02x", $0) }.joined()
  }
}
