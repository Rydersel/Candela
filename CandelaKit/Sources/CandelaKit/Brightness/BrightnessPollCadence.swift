import Foundation

/// How often the native poller looks, decided fresh on every tick.
///
/// Never STOPPED while a display exists: an external entering HDR flips onto the
/// native path through no call of ours, and only a running poller notices. An
/// idle rig pays a longer interval, never no poller.
public enum BrightnessPollCadence: Sendable, Equatable, CaseIterable {
  /// A value is moving: chase it, as the fork did.
  case fast
  /// Something is consuming the value right now.
  case idle
  /// Nothing is consuming it, on mains.
  case slowIdle
  /// Nothing is consuming it, on battery.
  case batterySlowIdle

  /// For the log line that makes the cadence readable from outside the process.
  public var name: String {
    switch self {
    case .fast: "fast"
    case .idle: "idle"
    case .slowIdle: "slow"
    case .batterySlowIdle: "slow-on-battery"
    }
  }

  /// `isExternalNativeActive` ignores the built-in on purpose: it is always native
  /// and would pin every laptop to the short interval. Its only consumer with no
  /// surface open is a brightness key, which takes its own read before stepping.
  /// `isOnBattery` is an autoclosure: the power-source read costs something and
  /// only the slow branch needs it.
  public static func choose(
    isMoving: Bool,
    isSyncEnabled: Bool,
    isSurfaceVisible: Bool,
    isExternalNativeActive: Bool,
    isOnBattery: @autoclosure () -> Bool
  ) -> BrightnessPollCadence {
    if isMoving { return .fast }
    if isSyncEnabled || isSurfaceVisible || isExternalNativeActive { return .idle }
    return isOnBattery() ? .batterySlowIdle : .slowIdle
  }
}
