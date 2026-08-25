import Foundation
import Testing

/// The event-tap deadman switch decides from clock deltas alone, and the one
/// delta it must never trust is the machine's own sleep: at a dark wake the
/// monitor thread runs first and sees the prober's last stamp minutes old in
/// wall time with nothing actually wedged. Measured 2026-08-22 to 08-25:
/// 87 emergency exits in three days, every one `proberDead` alone, every one
/// at a dark wake.
@Suite("The tap watchdog's verdict across a sleep")
struct TapWatchdogVerdictTests {
  private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func clock(wallOffset: TimeInterval, uptime: TimeInterval) -> TapWatchdogClock {
    TapWatchdogClock(wall: t0.addingTimeInterval(wallOffset), uptime: uptime)
  }

  @Test func aDarkWakeAfterFifteenMinutesAsleepIsNotADeadProber() {
    // Previous tick 15 minutes ago on the wall, the machine awake for only one
    // second of it: the prober's stamp is exactly as old as the sleep.
    let outcome = TapWatchdogVerdict.evaluate(
      sample: .init(pingPosted: nil, probing: nil, alive: t0),
      previousTick: clock(wallOffset: 0, uptime: 100),
      now: clock(wallOffset: 15 * 60, uptime: 101)
    )
    #expect(outcome == .sleptAcrossTick(seconds: 15 * 60 - 1))
  }

  @Test func aPingPostedBeforeSleepIsForgivenNotLost() {
    let outcome = TapWatchdogVerdict.evaluate(
      sample: .init(pingPosted: t0.addingTimeInterval(-1), probing: nil, alive: t0),
      previousTick: clock(wallOffset: 0, uptime: 100),
      now: clock(wallOffset: 600, uptime: 101)
    )
    #expect(outcome == .sleptAcrossTick(seconds: 599))
  }

  @Test func aProberSilentForThirteenAwakeSecondsIsDead() {
    // The positive control: both clocks advanced together, so the staleness
    // is real and the verdict must still fire on the prober alone.
    let outcome = TapWatchdogVerdict.evaluate(
      sample: .init(pingPosted: nil, probing: nil, alive: t0),
      previousTick: clock(wallOffset: 12, uptime: 112),
      now: clock(wallOffset: 13, uptime: 113)
    )
    #expect(outcome == .wedged(pingLost: false, probeStuck: false, proberDead: true))
  }

  @Test func anUnansweredPingOverFiveAwakeSecondsIsLost() {
    let outcome = TapWatchdogVerdict.evaluate(
      sample: .init(pingPosted: t0, probing: nil, alive: t0.addingTimeInterval(5)),
      previousTick: clock(wallOffset: 5, uptime: 105),
      now: clock(wallOffset: 6, uptime: 106)
    )
    #expect(outcome == .wedged(pingLost: true, probeStuck: false, proberDead: false))
  }

  @Test func aStuckProbeOverFiveAwakeSecondsFires() {
    let outcome = TapWatchdogVerdict.evaluate(
      sample: .init(pingPosted: nil, probing: t0, alive: t0),
      previousTick: clock(wallOffset: 5, uptime: 105),
      now: clock(wallOffset: 6, uptime: 106)
    )
    #expect(outcome == .wedged(pingLost: false, probeStuck: true, proberDead: false))
  }

  @Test func freshStampsOnAwakeClocksAreHealthy() {
    let outcome = TapWatchdogVerdict.evaluate(
      sample: .init(pingPosted: t0.addingTimeInterval(0.5), probing: nil, alive: t0.addingTimeInterval(0.9)),
      previousTick: clock(wallOffset: 0, uptime: 100),
      now: clock(wallOffset: 1, uptime: 101)
    )
    #expect(outcome == .healthy)
  }

  @Test func ordinaryTickJitterIsNotASleep() {
    // A tick that ran 1.5 s late on both clocks is scheduling noise, not a
    // sleep; the drift between the clocks is what marks a sleep, not the gap.
    let outcome = TapWatchdogVerdict.evaluate(
      sample: .init(pingPosted: nil, probing: nil, alive: t0.addingTimeInterval(2)),
      previousTick: clock(wallOffset: 0, uptime: 100),
      now: clock(wallOffset: 2.5, uptime: 102.5)
    )
    #expect(outcome == .healthy)
  }
}
