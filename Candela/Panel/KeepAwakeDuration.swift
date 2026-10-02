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

  @MainActor func apply(to keepAwake: KeepAwake) {
    if let seconds { keepAwake.start(for: seconds) }
    else { keepAwake.setOn(true) }
  }
}
