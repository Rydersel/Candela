import Testing
@testable import CandelaKit

@Suite("DDC wire health (WD1)")
struct DDCWireHealthTests {
  @Test func aFreshWireIsTrusted() {
    let health = DDCWireHealth()
    #expect(health.consecutiveFailures == 0)
    #expect(!health.isUnresponsive)
  }

  /// Two failures are still a wire that might take the next command. The
  /// threshold is the third, and the count below it is pinned so a future edit
  /// cannot quietly demote a display on the first dropped write.
  @Test func threeConsecutiveFailuresDemoteAndNoFewerDo() {
    var health = DDCWireHealth()
    health.noteApply(succeeded: false, hdrExcluded: false)
    #expect(!health.isUnresponsive)
    health.noteApply(succeeded: false, hdrExcluded: false)
    #expect(!health.isUnresponsive)
    health.noteApply(succeeded: false, hdrExcluded: false)
    #expect(health.isUnresponsive)
  }

  /// CONSECUTIVE is the word doing the work: a bare failure counter would
  /// demote a display that has failed three times over an afternoon of writes
  /// that otherwise all landed.
  @Test func aSuccessInBetweenStartsTheCountAgain() {
    var health = DDCWireHealth()
    health.noteApply(succeeded: false, hdrExcluded: false)
    health.noteApply(succeeded: false, hdrExcluded: false)
    health.noteApply(succeeded: true, hdrExcluded: false)
    #expect(health.consecutiveFailures == 0)
    health.noteApply(succeeded: false, hdrExcluded: false)
    health.noteApply(succeeded: false, hdrExcluded: false)
    #expect(!health.isUnresponsive)
  }

  /// The demotion lifts on the next landed write, without a replug and without
  /// a relaunch.
  @Test func aSuccessAfterTheDemotionLiftsIt() {
    var health = DDCWireHealth()
    for _ in 0 ..< 5 { health.noteApply(succeeded: false, hdrExcluded: false) }
    #expect(health.isUnresponsive)
    health.noteApply(succeeded: true, hdrExcluded: false)
    #expect(!health.isUnresponsive)
  }

  /// A DDC failure under live HDR is expected and temporary: the register is
  /// locked and the display is being driven natively. Counting it is the
  /// defect this whole feature is specified against.
  @Test func failuresFlaggedHDRExcludedNeverCount() {
    var health = DDCWireHealth()
    for _ in 0 ..< 10 { health.noteApply(succeeded: false, hdrExcluded: true) }
    #expect(health.consecutiveFailures == 0)
    #expect(!health.isUnresponsive)
  }

  /// The exclusion drops the attempt, rather than reading it as a success. An
  /// HDR-window "success" is an ACK from a locked register, so letting it clear
  /// a count the wire had honestly earned would promote a dead wire on the
  /// strength of a write that reached nothing.
  @Test func anHDRExcludedSuccessDoesNotClearAnEarnedCount() {
    var health = DDCWireHealth()
    health.noteApply(succeeded: false, hdrExcluded: false)
    health.noteApply(succeeded: false, hdrExcluded: false)
    health.noteApply(succeeded: true, hdrExcluded: true)
    #expect(health.consecutiveFailures == 2)
    health.noteApply(succeeded: false, hdrExcluded: false)
    #expect(health.isUnresponsive)
  }

  @Test func resetClearsTheCountAndTheDemotion() {
    var health = DDCWireHealth()
    for _ in 0 ..< 4 { health.noteApply(succeeded: false, hdrExcluded: false) }
    #expect(health.isUnresponsive)
    health.reset()
    #expect(health.consecutiveFailures == 0)
    #expect(!health.isUnresponsive)
  }

  /// After a reset the next writes decide again, from zero: a reset that only
  /// masked the verdict would demote again on the very next failure.
  @Test func afterAResetTheCountStartsFromZero() {
    var health = DDCWireHealth()
    for _ in 0 ..< 3 { health.noteApply(succeeded: false, hdrExcluded: false) }
    health.reset()
    health.noteApply(succeeded: false, hdrExcluded: false)
    health.noteApply(succeeded: false, hdrExcluded: false)
    #expect(!health.isUnresponsive)
    health.noteApply(succeeded: false, hdrExcluded: false)
    #expect(health.isUnresponsive)
  }
}
