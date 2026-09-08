import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// `CGCompleteDisplayConfiguration` can return `.success` over a mode it did not
/// apply; the mirroring path had already measured the platform doing that.
@Suite("Mode apply verification")
struct ModeApplyVerificationTests {
  private func mode(
    id: Int32 = 1,
    logical: (Int, Int) = (2560, 1080),
    pixels: (Int, Int) = (5120, 2160),
    hz: Double = 120,
    native: Bool = false
  ) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: logical.0, logicalHeight: logical.1,
      pixelWidth: pixels.0, pixelHeight: pixels.1, refreshHz: hz, isNative: native)
  }

  /// The Dell publishes 42 pairs alike in everything but the mode number, and the
  /// live read can answer with either, so an id compare would fail every apply.
  @Test func equalGeometryUnderDifferentIdsIsHonoured() {
    #expect(
      ModeApplyVerification.verdict(requested: mode(id: 7), achieved: mode(id: 291)) == .honoured)
  }

  @Test func aSizeMissIsUnhonoured() {
    #expect(
      ModeApplyVerification.verdict(
        requested: mode(), achieved: mode(logical: (1920, 1080))) == .unhonoured)
    // The 1x twin of the same logical size: the display is scanning out half the
    // pixels the user asked for.
    #expect(
      ModeApplyVerification.verdict(
        requested: mode(), achieved: mode(pixels: (2560, 1080))) == .unhonoured)
  }

  /// A rate-only change looks identical on screen, so nobody answering the keep
  /// card would notice a display left at the rate it started on.
  @Test func aRefreshOnlyMissIsUnhonoured() {
    #expect(
      ModeApplyVerification.verdict(requested: mode(hz: 120), achieved: mode(hz: 60))
        == .unhonoured)
  }

  /// CoreGraphics reports 59.997 for a 60 Hz mode, and an exact compare would
  /// call every honoured apply a failure.
  @Test func refreshNoiseIsStillHonoured() {
    #expect(
      ModeApplyVerification.verdict(requested: mode(hz: 60), achieved: mode(hz: 59.997))
        == .honoured)
  }

  /// The edges of the half-hertz tolerance: an NTSC rate and its integer twin
  /// collapse into one match, a real neighbouring rate does not.
  @Test func theRefreshToleranceCollapsesNTSCAndKeepsRealRatesApart() {
    #expect(
      ModeApplyVerification.verdict(requested: mode(hz: 60), achieved: mode(hz: 59.94))
        == .honoured)
    #expect(
      ModeApplyVerification.verdict(requested: mode(hz: 60), achieved: mode(hz: 61))
        == .unhonoured)
  }

  /// No readable mode is not evidence the mode landed, so it takes the same
  /// answer as a miss.
  @Test func anUnreadableModeIsUnhonoured() {
    #expect(ModeApplyVerification.verdict(requested: mode(), achieved: nil) == .unhonoured)
  }

  /// `isNative` is a fact about the panel, not part of a mode's identity; the
  /// live read carries whatever flag the panel reports.
  @Test func theNativeFlagDoesNotDecideTheVerdict() {
    #expect(
      ModeApplyVerification.verdict(requested: mode(native: true), achieved: mode(native: false))
        == .honoured)
  }

  /// Callers branch on this: only a refusal may be reported as "nothing changed",
  /// so sharing `CGError.failure` with a never-opened transaction would hide it.
  @Test func anUnhonouredCommitIsDistinguishableFromARefusal() {
    let committed = DisplayConfigError(
      unhonouredCommit: .init(requested: mode(), achieved: mode(logical: (1920, 1080))))
    #expect(committed.didCommit)
    #expect(committed.cgErrorCode == DisplayConfigError.unhonouredCommitCode)
    #expect(committed.cgErrorCode != CGError.failure.rawValue)
    #expect(committed.unhonouredCommit?.achieved?.logicalWidth == 1920)

    #expect(!DisplayConfigError(cgErrorCode: CGError.failure.rawValue).didCommit)
    #expect(!DisplayConfigError(cgErrorCode: -1).didCommit)
  }
}

/// The bounded settle both apply paths verify through. The window server lands a
/// mode change asynchronously, so one immediate read can describe the OUTGOING
/// mode and report an honoured apply as unhonoured.
@Suite("Mode apply settle")
struct ModeApplySettleTests {
  private let configurator = CoreGraphicsDisplayConfigurator()

  /// Time the test moves by hand, so the settle spends none.
  private final class FakeClock {
    private var seconds: TimeInterval = 0
    func now() -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
    func advance(_ interval: TimeInterval) { seconds += interval }
  }

  /// An honoured apply pays nothing: the read is taken before any sleep.
  @Test func aReadingThatAlreadyMatchesCostsOneRead() {
    let clock = FakeClock()
    var reads = 0
    var sleeps = 0
    let observed = configurator.settled(
      now: clock.now, sleep: { sleeps += 1; clock.advance($0) },
      read: {
        reads += 1
        return 7
      }, until: { $0 == 7 })
    #expect(observed == 7)
    #expect(reads == 1)
    #expect(sleeps == 0)
  }

  /// The whole point: a mode still landing on the first look is re-read rather
  /// than reported as a divergence.
  @Test func aLateArrivalIsSeenOnALaterRead() {
    let clock = FakeClock()
    var reads = 0
    let observed = configurator.settled(
      now: clock.now, sleep: { clock.advance($0) },
      read: {
        reads += 1
        return reads < 3 ? 1 : 7
      }, until: { $0 == 7 })
    #expect(observed == 7)
    #expect(reads == 3)
  }

  /// A change that never lands returns the LAST reading, not the first: the
  /// caller reports what the display says now, and the error it throws carries
  /// that geometry. Bounded, so a wedged display cannot hold the thread.
  @Test func aChangeThatNeverLandsIsBoundedAndReturnsTheLastReading() {
    let clock = FakeClock()
    var reads = 0
    var slept: TimeInterval = 0
    let observed = configurator.settled(
      now: clock.now,
      sleep: {
        slept += $0
        clock.advance($0)
      },
      read: {
        reads += 1
        return reads
      }, until: { _ in false })
    #expect(observed == reads)
    #expect(reads > 1)
    // The bound, with one poll interval of overshoot allowed: the deadline is
    // checked before each sleep rather than after it.
    #expect(slept <= CoreGraphicsDisplayConfigurator.modeSettleWindow
      + CoreGraphicsDisplayConfigurator.modeSettlePoll)
  }

  private func revealed(id: Int32) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: 3440, logicalHeight: 1440,
      pixelWidth: 6880, pixelHeight: 2880, refreshHz: 120, isNative: false)
  }

  /// Through the revealed path's OWN settle-and-verdict, not a predicate the test
  /// wrote: the requested id is the one the loop keeps comparing against, so a
  /// mode still landing on the first look is waited for rather than reported as a
  /// divergence.
  @Test func theRevealedSettleWaitsForTheRequestedId() {
    let clock = FakeClock()
    let mode = revealed(id: 291)
    var reads = 0
    let observed = configurator.settledRevealedModeID(
      requested: mode, now: clock.now, sleep: { clock.advance($0) },
      read: {
        reads += 1
        return reads < 3 ? 7 : mode.ioModeID
      })
    #expect(observed == mode.ioModeID)
    #expect(reads == 3)
  }

  /// The requested side is FIXED across the loop, which is what "like with like"
  /// means here: a read side that keeps changing to other ids never satisfies it,
  /// and the loop ends on the bound with the last id read, which is what the
  /// caller reports.
  @Test func theRevealedSettleNeverAcceptsAnotherId() {
    let clock = FakeClock()
    let mode = revealed(id: 291)
    var reads = 0
    let observed = configurator.settledRevealedModeID(
      requested: mode, now: clock.now, sleep: { clock.advance($0) },
      read: {
        reads += 1
        return Int32(reads)
      })
    #expect(observed != mode.ioModeID)
    #expect(observed == Int32(reads))
    #expect(reads > 1)
  }

  /// A display that reports no mode at all is not one the mode landed on, and it
  /// does not end the settle early either.
  @Test func theRevealedSettleTreatsAnUnreadableModeAsNotLanded() {
    let clock = FakeClock()
    let mode = revealed(id: 291)
    var reads = 0
    let observed = configurator.settledRevealedModeID(
      requested: mode, now: clock.now, sleep: { clock.advance($0) },
      read: {
        reads += 1
        return reads < 2 ? nil : mode.ioModeID
      })
    #expect(observed == mode.ioModeID)
    #expect(reads == 2)
  }

  /// An honoured revealed apply pays nothing: one read, no sleep.
  @Test func theRevealedSettleCostsNothingOnAnHonouredApply() {
    let clock = FakeClock()
    let mode = revealed(id: 291)
    var reads = 0
    var sleeps = 0
    let observed = configurator.settledRevealedModeID(
      requested: mode, now: clock.now, sleep: { _ in sleeps += 1 },
      read: {
        reads += 1
        return mode.ioModeID
      })
    #expect(observed == mode.ioModeID)
    #expect(reads == 1)
    #expect(sleeps == 0)
  }
}
