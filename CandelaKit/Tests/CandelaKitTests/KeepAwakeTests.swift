import Foundation
import Testing
@testable import CandelaKit

@Suite("Keep awake")
@MainActor
struct KeepAwakeTests {
  /// Records the pairing rather than taking a real assertion, so the suite can
  /// state "exactly one held" without asking the system what it is holding.
  private final class RecordingHolder: PowerAssertionHolding {
    var created: [String] = []
    var released: [UInt32] = []
    var refuses = false
    private var next: UInt32 = 100

    var outstanding: Int { created.count - released.count }

    func createPreventDisplaySleep(named name: String) -> UInt32? {
      guard !refuses else { return nil }
      created.append(name)
      next += 1
      return next
    }

    func release(_ id: UInt32) { released.append(id) }
  }

  @Test func customDeadlineIsExactAndReplacesWithoutAnotherAssertion() {
    let holder = RecordingHolder()
    let now = Date(timeIntervalSince1970: 1_000)
    let awake = KeepAwake(holder: holder, now: { now })
    defer { awake.setOn(false) }
    #expect(awake.start(until: Date(timeIntervalSince1970: 1_123)))
    #expect(awake.expiresAt == Date(timeIntervalSince1970: 1_123))
    #expect(awake.start(until: Date(timeIntervalSince1970: 1_234)))
    #expect(holder.outstanding == 1)
    #expect(holder.created.count == 1)
    awake.expireIfNeeded(at: Date(timeIntervalSince1970: 1_123))
    #expect(awake.isOn)
    awake.expireIfNeeded(at: Date(timeIntervalSince1970: 1_234))
    #expect(!awake.isOn)
    #expect(holder.outstanding == 0)
  }

  @Test func invalidCustomDeadlinePreservesExistingHold() {
    let holder = RecordingHolder()
    let now = Date(timeIntervalSince1970: 1_000)
    let awake = KeepAwake(holder: holder, now: { now })
    defer { awake.setOn(false) }
    awake.start(for: 900)
    for date in [now, now.addingTimeInterval(-1), Date.distantFuture,
                 Date(timeIntervalSince1970: .infinity)] {
      #expect(!awake.start(until: date))
      #expect(awake.expiresAt == Date(timeIntervalSince1970: 1_900))
      #expect(holder.outstanding == 1)
    }
    awake.setOn(false)
    holder.refuses = true
    #expect(!awake.start(until: now.addingTimeInterval(60)))
    #expect(awake.expiresAt == nil)
  }

  @Test func onTakesOneAssertionAndOffReleasesIt() {
    let holder = RecordingHolder()
    let keepAwake = KeepAwake(holder: holder)
    #expect(keepAwake.isOn == false)
    #expect(holder.outstanding == 0)

    keepAwake.setOn(true)
    #expect(keepAwake.isOn)
    #expect(holder.outstanding == 1)

    keepAwake.setOn(false)
    #expect(keepAwake.isOn == false)
    #expect(holder.outstanding == 0)
  }

  /// The name is what a person reads in `pmset -g assertions`, and the hardware
  /// check for this feature is "check the name, not just the count".
  @Test func theAssertionCarriesTheAppsName() {
    let holder = RecordingHolder()
    KeepAwake(holder: holder).setOn(true)
    #expect(holder.created == ["Candela Keep Awake"])
  }

  /// A second `true` must not take a second assertion: one `false` releases one
  /// id, so the extra would stay held with no control left pointing at it.
  @Test func turningItOnTwiceLeavesExactlyOneAssertionHeld() {
    let holder = RecordingHolder()
    let keepAwake = KeepAwake(holder: holder)
    keepAwake.setOn(true)
    keepAwake.setOn(true)
    #expect(holder.created.count == 1)

    keepAwake.setOn(false)
    #expect(holder.outstanding == 0)
  }

  @Test func turningItOffWhenItWasNeverOnReleasesNothing() {
    let holder = RecordingHolder()
    KeepAwake(holder: holder).setOn(false)
    #expect(holder.created.isEmpty)
    #expect(holder.released.isEmpty)
  }

  /// A refused assertion leaves the control OFF. Reporting on over a display
  /// that will sleep anyway is the one outcome worse than not offering it.
  @Test func aRefusedAssertionLeavesTheControlOff() {
    let holder = RecordingHolder()
    holder.refuses = true
    let keepAwake = KeepAwake(holder: holder)

    keepAwake.setOn(true)

    #expect(keepAwake.isOn == false)
    #expect(holder.outstanding == 0)
  }

  @Test func toggleFlipsBothWays() {
    let holder = RecordingHolder()
    let keepAwake = KeepAwake(holder: holder)
    keepAwake.toggle()
    #expect(keepAwake.isOn)
    keepAwake.toggle()
    #expect(keepAwake.isOn == false)
    #expect(holder.outstanding == 0)
  }
  @Test func aTimedHoldReleasesAtItsDeadline() throws {
    let holder = RecordingHolder()
    let keepAwake = KeepAwake(holder: holder)
    keepAwake.start(for: 900)
    #expect(holder.outstanding == 1)
    let deadline = try #require(keepAwake.expiresAt)
    keepAwake.expireIfNeeded(at: deadline.addingTimeInterval(-1))
    #expect(keepAwake.isOn)
    keepAwake.expireIfNeeded(at: deadline)
    #expect(!keepAwake.isOn)
    #expect(keepAwake.expiresAt == nil)
    #expect(holder.outstanding == 0)
  }

  @Test func replacingATimerDoesNotReleaseTheNewHoldAtTheOldDeadline() throws {
    let holder = RecordingHolder()
    let keepAwake = KeepAwake(holder: holder)
    keepAwake.start(for: 900)
    let old = try #require(keepAwake.expiresAt)
    keepAwake.start(for: 3600)
    #expect(holder.created.count == 1)
    keepAwake.expireIfNeeded(at: old)
    #expect(keepAwake.isOn)
    keepAwake.setOn(false)
    #expect(keepAwake.expiresAt == nil)
    #expect(holder.outstanding == 0)
  }

  @Test func anIndefiniteHoldClearsThePreviousDeadline() throws {
    let holder = RecordingHolder()
    let keepAwake = KeepAwake(holder: holder)
    keepAwake.start(for: 900)
    let deadline = try #require(keepAwake.expiresAt)
    keepAwake.setOn(true)
    keepAwake.expireIfNeeded(at: deadline.addingTimeInterval(3600))
    #expect(keepAwake.expiresAt == nil)
    #expect(keepAwake.isOn)
    keepAwake.setOn(false)
  }

  @Test func aRefusedTimedHoldAndInvalidDurationsLeaveNoTimer() {
    let holder = RecordingHolder()
    holder.refuses = true
    let keepAwake = KeepAwake(holder: holder)
    keepAwake.start(for: 900)
    #expect(!keepAwake.isOn)
    #expect(keepAwake.expiresAt == nil)
    holder.refuses = false
    for seconds in [0, -1, Double.infinity, Double.nan] { keepAwake.start(for: seconds) }
    #expect(holder.created.isEmpty)
    #expect(keepAwake.expiresAt == nil)
  }

  @Test func aTimedHoldExpiresWithoutOpeningThePanel() async throws {
    let holder = RecordingHolder()
    let keepAwake = KeepAwake(holder: holder)
    keepAwake.start(for: 0.02)
    #expect(keepAwake.isOn)
    let limit = ContinuousClock.now.advanced(by: .seconds(2))
    while keepAwake.isOn && ContinuousClock.now < limit {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!keepAwake.isOn)
    #expect(holder.outstanding == 0)
  }

  @Test func anEarlyTimerRechecksUntilTheWallClockDeadline() async throws {
    let holder = RecordingHolder()
    var clock = Date()
    let keepAwake = KeepAwake(holder: holder, now: { clock })
    keepAwake.start(for: 0.02)
    let deadline = try #require(keepAwake.expiresAt)
    // The timer fires while the wall clock has not reached the deadline.
    try await Task.sleep(for: .milliseconds(100))
    #expect(keepAwake.isOn)
    clock = deadline
    let limit = ContinuousClock.now.advanced(by: .seconds(1))
    while keepAwake.isOn && ContinuousClock.now < limit {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!keepAwake.isOn)
    #expect(holder.outstanding == 0)
    keepAwake.setOn(false)
  }

  @Test func aForwardClockChangeExpiresAnElapsedDeadlineImmediately() async throws {
    let holder = RecordingHolder()
    let notifications = NotificationCenter()
    var clock = Date()
    let keepAwake = KeepAwake(holder: holder, now: { clock }, clockNotifications: notifications)
    keepAwake.start(for: 3_600)
    let deadline = try #require(keepAwake.expiresAt)
    clock = deadline.addingTimeInterval(1)
    notifications.post(name: .NSSystemClockDidChange, object: nil)
    // Delivery may hop to MainActor, but must not wait for the hour-long timer.
    let limit = ContinuousClock.now.advanced(by: .seconds(2))
    while keepAwake.isOn && ContinuousClock.now < limit {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!keepAwake.isOn)
    #expect(keepAwake.expiresAt == nil)
    #expect(holder.outstanding == 0)
    keepAwake.setOn(false)
  }

  @Test func aClockChangeBeforeTheDeadlineKeepsTheSameAssertionAndDeadline() async throws {
    let holder = RecordingHolder()
    let notifications = NotificationCenter()
    var clock = Date()
    let keepAwake = KeepAwake(holder: holder, now: { clock }, clockNotifications: notifications)
    keepAwake.start(for: 3_600)
    let deadline = try #require(keepAwake.expiresAt)
    clock = clock.addingTimeInterval(-3_600)
    notifications.post(name: .NSSystemClockDidChange, object: nil)
    try await Task.sleep(for: .milliseconds(20))
    #expect(keepAwake.isOn)
    #expect(keepAwake.expiresAt == deadline)
    #expect(holder.created.count == 1)
    #expect(holder.released.isEmpty)
    clock = deadline
    notifications.post(name: .NSSystemClockDidChange, object: nil)
    let limit = ContinuousClock.now.advanced(by: .seconds(2))
    while keepAwake.isOn && ContinuousClock.now < limit {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!keepAwake.isOn)
    #expect(holder.outstanding == 0)
    keepAwake.setOn(false)
  }

  @Test func aForwardClockChangeReschedulesAFutureDeadline() async throws {
    let holder = RecordingHolder()
    let notifications = NotificationCenter()
    var clock = Date()
    let keepAwake = KeepAwake(holder: holder, now: { clock }, clockNotifications: notifications)
    keepAwake.start(for: 3_600)
    let deadline = try #require(keepAwake.expiresAt)
    clock = deadline.addingTimeInterval(-0.02)
    notifications.post(name: .NSSystemClockDidChange, object: nil)
    try await Task.sleep(for: .milliseconds(50))
    #expect(keepAwake.isOn)
    clock = deadline
    // No second notification: the shortened timer must perform this check.
    let limit = ContinuousClock.now.advanced(by: .seconds(2))
    while keepAwake.isOn && ContinuousClock.now < limit {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!keepAwake.isOn)
    #expect(holder.created.count == 1)
    #expect(holder.outstanding == 0)
    keepAwake.setOn(false)
  }

  /// A relative timer does not count time the Mac spends asleep, so the wake
  /// hook must move the next check to the wall-clock deadline. Without that, a
  /// hold outlives its advertised end by the length of the sleep.
  @Test func wakingFromSleepRearmsTheCheckAtTheWallClockDeadline() async throws {
    let holder = RecordingHolder()
    var clock = Date()
    let keepAwake = KeepAwake(holder: holder, now: { clock }, clockNotifications: NotificationCenter())
    keepAwake.start(for: 3_600)
    let deadline = try #require(keepAwake.expiresAt)
    // The Mac slept for almost the whole hour; the hour-long timer did not run.
    clock = deadline.addingTimeInterval(-0.02)
    keepAwake.expireIfNeeded(at: clock)
    #expect(keepAwake.isOn)
    #expect(keepAwake.expiresAt == deadline)
    #expect(holder.created.count == 1)
    clock = deadline
    // No further wake or clock notification: the re-armed timer must end it.
    let limit = ContinuousClock.now.advanced(by: .seconds(2))
    while keepAwake.isOn && ContinuousClock.now < limit {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!keepAwake.isOn)
    #expect(holder.outstanding == 0)
    keepAwake.setOn(false)
  }

}
