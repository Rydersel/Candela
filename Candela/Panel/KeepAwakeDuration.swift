import CandelaKit
import Foundation

/// Ordered stops keep a short slider useful across minutes, hours and an indefinite hold.
enum KeepAwakeDuration: Int, CaseIterable {
  case fifteenMinutes, thirtyMinutes, oneHour, twoHours, fourHours, eightHours, untilTurnedOff

  var seconds: TimeInterval? {
    switch self {
    case .fifteenMinutes: 900
    case .thirtyMinutes: 1_800
    case .oneHour: 3_600
    case .twoHours: 7_200
    case .fourHours: 14_400
    case .eightHours: 28_800
    case .untilTurnedOff: nil
    }
  }

  var title: String {
    switch self {
    case .fifteenMinutes: "15 minutes"
    case .thirtyMinutes: "30 minutes"
    case .oneHour: "1 hour"
    case .twoHours: "2 hours"
    case .fourHours: "4 hours"
    case .eightHours: "8 hours"
    case .untilTurnedOff: "Until turned off"
    }
  }

  static func closest(to remaining: TimeInterval) -> Self {
    allCases.filter { $0.seconds != nil }.min {
      abs($0.seconds! - remaining) < abs($1.seconds! - remaining)
    } ?? .oneHour
  }

  /// A stop the time left lands within a minute of, or nil when no stop
  /// describes it.
  static func matching(remaining: TimeInterval) -> Self? {
    allCases.first { $0.seconds.map { abs($0 - remaining) <= 60 } ?? false }
  }

  /// The stop the panel's Duration row names for a running hold, or nil for
  /// "Custom". The name is decided once, when the hold starts, so the same
  /// hold keeps one name as its time left runs down.
  @MainActor static func describing(_ keepAwake: KeepAwake) -> Self? {
    guard keepAwake.isOn else { return nil }
    guard let expiresAt = keepAwake.expiresAt else { return .untilTurnedOff }
    guard let started = lastStarted, started.expiresAt == expiresAt else { return nil }
    return started.duration
  }

  /// Starts a hold at a chosen instant. It takes a stop's name only if it
  /// lands within a minute of one now, so a three-day hold never reads as the
  /// nearest stop the switch would start.
  @MainActor static func start(_ keepAwake: KeepAwake, until deadline: Date, now: Date = Date()) -> Bool {
    guard keepAwake.start(until: deadline) else { return false }
    // Confirming the dialog unchanged keeps the hold's own deadline, so the stop
    // it started from keeps its name instead of re-matching the time left.
    if lastStarted?.expiresAt != deadline {
      lastStarted = matching(remaining: deadline.timeIntervalSince(now)).map { ($0, deadline) }
    }
    return true
  }

  @MainActor private static var lastStarted: (duration: Self, expiresAt: Date)?

  @MainActor func apply(to keepAwake: KeepAwake) {
    if let seconds {
      keepAwake.start(for: seconds)
      Self.lastStarted = keepAwake.expiresAt.map { (self, $0) }
    } else {
      keepAwake.setOn(true)
    }
  }
}
