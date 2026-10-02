import Foundation

/// Bounds shared by temporary display controls and their date picker.
public enum TimedControlDeadline {
  public static let maximumInterval: TimeInterval = 365 * 24 * 60 * 60

  public static func isValid(_ deadline: Date, now: Date) -> Bool {
    let interval = deadline.timeIntervalSince(now)
    return interval.isFinite && interval > 0 && interval <= maximumInterval
  }
}
