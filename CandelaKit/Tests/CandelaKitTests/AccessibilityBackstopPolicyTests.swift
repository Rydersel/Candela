import Foundation
import Testing

@testable import CandelaKit

@Suite("Accessibility backstop cadence")
struct AccessibilityBackstopPolicyTests {
  private func interval(
    granted: Bool = false,
    requires: Bool = true,
    missingFor: TimeInterval = 0,
    sinceNotification: TimeInterval? = nil
  ) -> TimeInterval? {
    AccessibilityBackstopPolicy.interval(
      granted: granted,
      requiresAccessibility: requires,
      secondsSinceMissingBegan: missingFor,
      secondsSinceNotification: sinceNotification
    )
  }

  @Test func aHeldGrantIsPolledForeverAtTenSeconds() {
    #expect(interval(granted: true) == 10)
    #expect(interval(granted: true, missingFor: 100_000) == 10)
  }

  /// The tracked answer feeds the prompt path, which declines to prompt while it
  /// says the grant is held, so the held poll survives the skip.
  @Test func aHeldGrantIsPolledEvenWhenNothingNeedsIt() {
    #expect(interval(granted: true, requires: false) == 10)
  }

  @Test func aMissingGrantHuntsForTheFirstTwoMinutes() {
    #expect(interval(missingFor: 0) == 2)
    #expect(interval(missingFor: 60) == 2)
    #expect(interval(missingFor: 119.9) == 2)
  }

  @Test func theHuntBacksOffOnceTheWindowHasPassed() {
    #expect(interval(missingFor: 120) == 30)
    #expect(interval(missingFor: 3600) == 30)
  }

  @Test func aNotificationReopensTheHuntFromAnyAge() {
    #expect(interval(missingFor: 3600, sinceNotification: 0) == 2)
    #expect(interval(missingFor: 3600, sinceNotification: 29.9) == 2)
  }

  @Test func theNotificationWindowExpiresBackToTheRestingCadence() {
    #expect(interval(missingFor: 3600, sinceNotification: 30) == 30)
    #expect(interval(missingFor: 3600, sinceNotification: 600) == 30)
  }

  /// An all-custom or all-disabled rig runs Carbon hotkeys only, so no timer.
  @Test func nothingIsPolledWhenNoKeyFamilyNeedsTheGrant() {
    #expect(interval(requires: false) == nil)
    #expect(interval(requires: false, missingFor: 3600) == nil)
    #expect(interval(requires: false, sinceNotification: 0) == nil)
  }
}
