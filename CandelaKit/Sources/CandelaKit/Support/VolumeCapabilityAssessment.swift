import Foundation

/// Effective volume support, without changing the display's advertised commands.
public struct VolumeCapabilityAssessment: Sendable, Equatable {
  public let support: VCPSupport
  public let usesCompatibilityException: Bool

  public init(reportedSupport: VCPSupport, hardwareName: String, manufacturerID: String?) {
    // These two GKT models accept volume writes while omitting 0x62 from their
    // capabilities. Keep this scoped to the hardware identities in the report,
    // never a friendly name or a brand-wide match. No mute support is inferred.
    // https://github.com/Rydersel/Candela/issues/70
    let name = hardwareName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let manufacturer = manufacturerID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    usesCompatibilityException = reportedSupport == .unsupported
      && manufacturer == "GKT" && (name == "KUYCON P27U" || name == "KUYCON P32U")
    support = usesCompatibilityException ? .supported : reportedSupport
  }
}
