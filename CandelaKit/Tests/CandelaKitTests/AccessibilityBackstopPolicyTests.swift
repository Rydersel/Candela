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

  /// The cadence an hour into a missing grant that the tap wants, for each edge.
  ///
  /// The edge goes THROUGH the policy, exactly as `AccessibilityPermission`'s two
  /// doors do: nothing here decides for it, so hard-coding the predicate either way
  /// moves one of the two answers below. What is modelled is only what the permission
  /// object does with the verdict, which is to put the hunt clock back to zero.
  private func cadenceAfterEdge(
    _ edge: AccessibilityBackstopPolicy.Edge,
    granted: Bool = false,
    requires: Bool = true
  ) -> TimeInterval? {
    let reopens = AccessibilityBackstopPolicy.reopensHunt(
      edge: edge, granted: granted, requiresAccessibility: requires
    )
    return interval(granted: granted, requires: requires, missingFor: reopens ? 0 : 3600)
  }

  /// A pref that re-arms the tap says nothing about whether anyone is at System
  /// Settings, and most of them are not about keys at all, so the clock stays put.
  @Test func anUnrelatedTapRearmLeavesTheRestingCadence() {
    #expect(cadenceAfterEdge(.tapRearmed) == 30)
    #expect(AccessibilityBackstopPolicy.reopensHunt(
      edge: .tapRearmed, granted: false, requiresAccessibility: true
    ) == false)
  }

  /// The one edge that does mean someone may be about to grant it.
  @Test func aKeyModeWriteReopensTheHunt() {
    #expect(cadenceAfterEdge(.keyModesWritten) == 2)
    #expect(AccessibilityBackstopPolicy.reopensHunt(
      edge: .keyModesWritten, granted: false, requiresAccessibility: true
    ))
  }

  /// The prompt and the two buttons that open the Accessibility list: the user is
  /// at System Settings by construction, so the backstop polls fast for their
  /// return however long the grant has been gone.
  @Test func beingSentToSystemSettingsReopensTheHunt() {
    #expect(cadenceAfterEdge(.sentToSystemSettings) == 2)
    #expect(AccessibilityBackstopPolicy.reopensHunt(
      edge: .sentToSystemSettings, granted: false, requiresAccessibility: true
    ))
  }

  /// Same two halves as the key-mode write. The all-custom case is the live one:
  /// the onboarding flow can offer the list before any key family wants the grant.
  @Test func beingSentToSystemSettingsReopensNothingWithoutBothStateHalves() {
    #expect(cadenceAfterEdge(.sentToSystemSettings, granted: true) == 10)
    #expect(cadenceAfterEdge(.sentToSystemSettings, requires: false) == nil)
    #expect(AccessibilityBackstopPolicy.reopensHunt(
      edge: .sentToSystemSettings, granted: true, requiresAccessibility: true
    ) == false)
    #expect(AccessibilityBackstopPolicy.reopensHunt(
      edge: .sentToSystemSettings, granted: false, requiresAccessibility: false
    ) == false)
  }

  /// The state halves, on the edge that can carry them: a held grant is not being
  /// hunted for, and an all-custom rig runs no timer for a re-stamp to move.
  @Test func aKeyModeWriteReopensNothingWithoutBothStateHalves() {
    #expect(cadenceAfterEdge(.keyModesWritten, granted: true) == 10)
    #expect(cadenceAfterEdge(.keyModesWritten, requires: false) == nil)
    #expect(AccessibilityBackstopPolicy.reopensHunt(
      edge: .keyModesWritten, granted: true, requiresAccessibility: true
    ) == false)
    #expect(AccessibilityBackstopPolicy.reopensHunt(
      edge: .keyModesWritten, granted: false, requiresAccessibility: false
    ) == false)
  }
}
