import Foundation

/// CK9: one protocol per family, a live implementation and a fake for each.
///
/// Every runner returns claims rather than a Bool, because a claim carries the
/// evidence it was graded from. Nothing here may grade from an acknowledgement:
/// a DDC write ACK and a successful configuration return are evidence of
/// nothing, so each live runner re-reads the achieved state and quotes it.
public protocol CheckupCapabilitiesRunning: Sendable {
  func run() async -> [CheckupClaim]
}

public protocol CheckupModeRunning: Sendable {
  func runNativeMode() async -> [CheckupClaim]
  func runRefreshSweep() async -> [CheckupClaim]
  /// Puts the display back on the mode it had before either run.
  func restore() async
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
