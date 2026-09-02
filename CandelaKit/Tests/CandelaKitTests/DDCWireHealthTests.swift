import Testing
@testable import CandelaKit

@Suite("DDC wire health")
struct DDCWireHealthTests {
  @Test func aFreshWireIsTrusted() {
    let health = DDCWireHealth()
    #expect(health.consecutiveFailures == 0)
    #expect(!health.isUnresponsive)
  }

  /// Two failures are still a wire that might take the next command. Pinned so
  /// a later edit cannot demote a display on the first dropped write.
  @Test func threeConsecutiveFailuresDemoteAndNoFewerDo() {
    var health = DDCWireHealth()
    health.noteApply(succeeded: false, hdrExcluded: false)
    #expect(!health.isUnresponsive)
    health.noteApply(succeeded: false, hdrExcluded: false)
    #expect(!health.isUnresponsive)
    health.noteApply(succeeded: false, hdrExcluded: false)
    #expect(health.isUnresponsive)
  }

  /// CONSECUTIVE is the word doing the work: a bare failure counter would demote
  /// a display that failed three times over an afternoon of writes that landed.
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

  /// The demotion lifts on the next landed write, with no replug or relaunch.
  @Test func aSuccessAfterTheDemotionLiftsIt() {
    var health = DDCWireHealth()
    for _ in 0 ..< 5 { health.noteApply(succeeded: false, hdrExcluded: false) }
    #expect(health.isUnresponsive)
    health.noteApply(succeeded: true, hdrExcluded: false)
    #expect(!health.isUnresponsive)
  }

  /// A DDC failure under live HDR is expected and temporary: the register is
  /// locked and the display is driven natively.
  @Test func failuresFlaggedHDRExcludedNeverCount() {
    var health = DDCWireHealth()
    for _ in 0 ..< 10 { health.noteApply(succeeded: false, hdrExcluded: true) }
    #expect(health.consecutiveFailures == 0)
    #expect(!health.isUnresponsive)
  }

  /// An HDR-window "success" is an ACK from a locked register, so the exclusion
  /// drops the attempt rather than letting it clear an earned count.
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

  /// From zero: a reset that only masked the verdict would demote again on the
  /// next failure.
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
