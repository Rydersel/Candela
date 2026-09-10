import Foundation
import Testing

@testable import CandelaKit

/// The cadence term a displayed nomination gets, and the state test the fast
/// term and the input monitor share. The three-term truth table this extends
/// lives in `LockDimTests`.
@Suite("OLED care cadence (displayed nomination)")
struct OledCareCadenceNominationTests {
  /// The defect: the old fast term counted any overlay, so a nomination on an
  /// `.active` display held the loop at 10 Hz. No input clears that mask.
  @Test func aDisplayedNominationTicksAtTheWindowFollowIntervalRatherThanFast() {
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: false, anyLockDimEngaged: false, verificationPending: false,
        nominationDisplayed: true
      ) == OledCareCadence.windowFollow
    )
    #expect(OledCareCadence.windowFollow == .seconds(1))
  }

  @Test func hoverReturnKeepsAFastTickEvenWhenItsMaskIsCurrentlyClear() {
    #expect(OledCareCadence.interval(
      anyOverlayUp: false, anyLockDimEngaged: false, verificationPending: false,
      windowRestorationPending: true, nominationDisplayed: false) == .milliseconds(100))
    #expect(OledCareCadence.interval(
      anyOverlayUp: false, anyLockDimEngaged: false, verificationPending: false,
      windowRestorationPending: false, nominationDisplayed: false) == .seconds(2))
  }

  /// The geometry refresh under the mask is throttled at one second, so the
  /// slow fall-through would double the wait a moved window's dim sheds in.
  @Test func theWindowFollowIntervalSitsBetweenFastAndSlow() {
    #expect(OledCareCadence.fast < OledCareCadence.windowFollow)
    #expect(OledCareCadence.windowFollow < OledCareCadence.slow)
  }

  /// Every term that means a restore is owed still outranks it: the mask can
  /// wait a second, a person's input cannot wait past the restore gate.
  @Test func everyFastTermOutranksADisplayedNomination() {
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: true, anyLockDimEngaged: false, verificationPending: false,
        nominationDisplayed: true
      ) == OledCareCadence.fast
    )
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: false, anyLockDimEngaged: true, verificationPending: false,
        nominationDisplayed: true
      ) == OledCareCadence.fast
    )
    // A mask change sets the verification marker, which is how a new mask still
    // lands its achieved-state check at 100 ms.
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: false, anyLockDimEngaged: false, verificationPending: true,
        nominationDisplayed: true
      ) == OledCareCadence.fast
    )
  }

  /// Nothing on screen, nothing to follow: the term has to be off for the idle
  /// cost this exists to cut to be cut at all.
  @Test func noNominationLeavesTheOtherTermsAlone() {
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: false, anyLockDimEngaged: false, verificationPending: false,
        nominationDisplayed: false
      ) == OledCareCadence.slow
    )
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: false, anyLockDimEngaged: false, verificationPending: false,
        nominationDisplayed: false, anythingEnrolled: false
      ) == OledCareCadence.idle
    )
    // The default matters: the parameter was added below the three the existing
    // truth table passes, and every one of those cells omits it.
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: false, anyLockDimEngaged: false, verificationPending: false
      ) == OledCareCadence.slow
    )
  }

  /// A mask on screen is work in flight, whatever the caller believes about
  /// enrollment. Contradictory input, decided toward the shorter interval for
  /// the reason `anythingEnrolled` defaults to true.
  @Test func aDisplayedNominationOutranksTheIdleFallThrough() {
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: false, anyLockDimEngaged: false, verificationPending: false,
        nominationDisplayed: true, anythingEnrolled: false
      ) == OledCareCadence.windowFollow
    )
  }

  /// The states an input event should end. `.active` is excluded even though it
  /// can hold a nomination overlay, and `.suspended` holds nothing to end.
  @Test func onlyTheDimsAnInputEndsLiftOnInput() {
    #expect(OledDimState.idleDim.liftsOnInput)
    #expect(OledDimState.blackout.liftsOnInput)
    #expect(OledDimState.lockDim.liftsOnInput)
    #expect(OledDimState.unfocusedDim.liftsOnInput)
    #expect(!OledDimState.active.liftsOnInput)
    #expect(!OledDimState.suspended.liftsOnInput)
  }
}
