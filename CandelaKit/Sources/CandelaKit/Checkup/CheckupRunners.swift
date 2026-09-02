import Foundation

/// One protocol per family, a live implementation and a fake for each.
/// Runners return claims, not Bools, because a claim carries its evidence. A
/// DDC ACK or a configuration return grades nothing; each live runner re-reads achieved state.
public protocol CheckupCapabilitiesRunning: Sendable {
  func run() async -> [CheckupClaim]
}

public protocol CheckupModeRunning: Sendable {
  func runNativeMode() async -> [CheckupClaim]
  func runRefreshSweep() async -> [CheckupClaim]
  /// Puts the display back on its pre-run mode and reports whether it is
  /// ACTUALLY on it afterwards; the apply's own return only says the request was accepted.
  func restore() async -> Bool
}

public protocol CheckupHDRRunning: Sendable {
  func run() async -> [CheckupClaim]
}

/// What a run needs; the app builds a live set, tests build fakes.
public struct CheckupRunnerSet: Sendable {
  public var identity: @Sendable () async -> CheckupDisplayIdentity?
  public var capabilities: any CheckupCapabilitiesRunning
  public var mode: any CheckupModeRunning
  public var hdr: any CheckupHDRRunning

  public init(
    identity: @escaping @Sendable () async -> CheckupDisplayIdentity?,
    capabilities: any CheckupCapabilitiesRunning,
    mode: any CheckupModeRunning,
    hdr: any CheckupHDRRunning
  ) {
    self.identity = identity
    self.capabilities = capabilities
    self.mode = mode
    self.hdr = hdr
  }
}
