import Foundation

public enum CheckupFieldKind: String, Codable, CaseIterable, Sendable {
  case black, red, green, blue, gray7, gray50, ramp, white, witness

  /// The field order the flow shows them in; white is last and shortest (CK17).
  public static let protocolOrder: [CheckupFieldKind] = [.black, .red, .green, .blue, .gray7, .gray50, .ramp, .white]

  public var capSeconds: Int { self == .white ? 10 : 20 }

  /// Pixel fields carry the plant; the others are ungraded attestations (CK23).
  public var carriesPlant: Bool {
    switch self {
    case .black, .red, .green, .blue, .white: true
    case .gray7, .gray50, .ramp, .witness: false
    }
  }
}
