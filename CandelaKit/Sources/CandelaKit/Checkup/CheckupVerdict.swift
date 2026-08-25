import Foundation

/// A verdict never exists without its evidence: the associated string is the
/// quoted observable, refusal, reason or attestation the report prints.
public enum CheckupVerdict: Equatable, Sendable {
  case observed(String)
  case refused(String)
  case notObserved(String)
  case selfReported(String)
  case inconclusive(String)

  public var kind: String {
    switch self {
    case .observed: "observed"
    case .refused: "refused"
    case .notObserved: "notObserved"
    case .selfReported: "selfReported"
    case .inconclusive: "inconclusive"
    }
  }

  public var text: String {
    switch self {
    case .observed(let s), .refused(let s), .notObserved(let s),
      .selfReported(let s), .inconclusive(let s):
      s
    }
  }
}

extension CheckupVerdict: Codable {
  // Encoded as {"kind","text"} so the on-disk form never depends on Swift's
  // enum encoding, which is shipped schema either way.
  private enum CodingKeys: String, CodingKey { case kind, text }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try c.decode(String.self, forKey: .kind)
    let text = try c.decode(String.self, forKey: .text)
    switch kind {
    case "observed": self = .observed(text)
    case "refused": self = .refused(text)
    case "notObserved": self = .notObserved(text)
    case "selfReported": self = .selfReported(text)
    case "inconclusive": self = .inconclusive(text)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: c, debugDescription: "unknown verdict kind \(kind)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(kind, forKey: .kind)
    try c.encode(text, forKey: .text)
  }
}

/// Fixed order; the plan, the flow and the report all iterate it.
public enum CheckupFamily: String, Codable, CaseIterable, Sendable {
  case identity, capabilities, nativeMode, refresh, visualField, hdr
}

/// Recorded on the report and shown in the flow; no check branches on it.
public enum CheckupScenario: String, Codable, CaseIterable, Sendable {
  case newMonitor, usedPurchase, recheck
}

/// Derived once per run from the capabilities string (CheckupPlan.panelClass).
public enum CheckupPanelClass: String, Codable, Sendable {
  case readsDDC, writeOnlyDDC, noDDC
}

public struct CheckupClaim: Codable, Equatable, Sendable {
  public let family: CheckupFamily
  public let id: String
  public let verdict: CheckupVerdict
  /// The plant size in pixels that detected, on the pixel fields only.
  public let detectedAt: Int?

  public init(family: CheckupFamily, id: String, verdict: CheckupVerdict, detectedAt: Int? = nil) {
    self.family = family
    self.id = id
    self.verdict = verdict
    self.detectedAt = detectedAt
  }
}
