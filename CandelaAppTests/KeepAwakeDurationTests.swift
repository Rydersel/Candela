import CandelaKit
import Foundation
import Testing

@Suite("Keep awake duration stops") @MainActor
struct KeepAwakeDurationTests {
  private final class Holder: PowerAssertionHolding {
    private(set) var held = 0
    func createPreventDisplaySleep(named name: String) -> UInt32? { held += 1; return UInt32(held) }
    func release(_ id: UInt32) { held -= 1 }
  }

  @Test func everyTimedStopMapsBackToItself() {
    for stop in KeepAwakeDuration.allCases {
      guard let seconds = stop.seconds else { continue }
      #expect(KeepAwakeDuration.closest(to: seconds) == stop)
    }
  }

  @Test(arguments: [
    (0.0, KeepAwakeDuration.fifteenMinutes),
    (1_340, .fifteenMinutes),
    (1_360, .thirtyMinutes),
    (2_800, .oneHour),
    (5_500, .twoHours),
    (10_900, .fourHours),
    (21_700, .eightHours),
    (TimedControlDeadline.maximumInterval, .eightHours),
  ])
  func remainingTimeRoundsToTheNearestTimedStop(remaining: TimeInterval, stop: KeepAwakeDuration) {
    #expect(KeepAwakeDuration.closest(to: remaining) == stop)
  }

  /// A remaining time always has a deadline, so it can never land on the
  /// indefinite stop, however long it is.
  @Test func closestNeverPicksTheIndefiniteStop() {
    #expect(KeepAwakeDuration.closest(to: .greatestFiniteMagnitude) != .untilTurnedOff)
  }

  @Test func applyingATimedStopSetsItsDeadline() {
    let now = Date(timeIntervalSince1970: 1_000)
    let awake = KeepAwake(holder: Holder(), now: { now }, clockNotifications: NotificationCenter())
    defer { awake.setOn(false) }
    KeepAwakeDuration.twoHours.apply(to: awake)
    #expect(awake.isOn)
    #expect(awake.expiresAt == Date(timeIntervalSince1970: 8_200))
  }

  @Test func applyingTheIndefiniteStopClearsAnEarlierDeadline() {
    let holder = Holder()
    let awake = KeepAwake(holder: holder, clockNotifications: NotificationCenter())
    defer { awake.setOn(false) }
    KeepAwakeDuration.fifteenMinutes.apply(to: awake)
    KeepAwakeDuration.untilTurnedOff.apply(to: awake)
    #expect(awake.isOn)
    #expect(awake.expiresAt == nil)
    #expect(holder.held == 1)
  }
}
