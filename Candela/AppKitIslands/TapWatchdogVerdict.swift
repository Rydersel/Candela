import Foundation

/// Two readings of "now" for the tap watchdog: the wall clock the heartbeat
/// stamps carry, and the uptime clock, which stops while the machine sleeps.
/// How far the two diverge between ticks is the sleep taken in between.
struct TapWatchdogClock: Sendable, Equatable {
  var wall: Date
  var uptime: TimeInterval

  static func now() -> TapWatchdogClock {
    TapWatchdogClock(wall: Date(), uptime: ProcessInfo.processInfo.systemUptime)
  }
}

/// The deadman switch's decision, kept pure so its one measured false fire stays
/// pinned: at a dark wake the monitor thread resumes before the prober and reads
/// a stamp exactly as old as the sleep. That fired 87 times in three days on the
/// dev machine, always `proberDead` alone, and relaunched a healthy app each time.
enum TapWatchdogVerdict {
  struct Sample: Sendable {
    var pingPosted: Date?
    var probing: Date?
    var alive: Date
  }

  enum Outcome: Equatable, Sendable {
    case healthy
    /// The machine slept about this long since the previous tick, so every stamp
    /// is older than the prober's real silence. No verdict; the caller resets.
    case sleptAcrossTick(seconds: TimeInterval)
    case wedged(pingLost: Bool, probeStuck: Bool, proberDead: Bool)
  }

  /// Ping unanswered > 5 s: pipeline wedged. Probe/AX in flight > 5 s or the
  /// prober loop silent > 12 s: the prober is stuck. 5 s tolerates the platform's
  /// legitimate stalls (mode changes and rotation block up to ~1.1 s, measured).
  static let pingLostAfter: TimeInterval = 5
  static let probeStuckAfter: TimeInterval = 5
  static let proberDeadAfter: TimeInterval = 12
  /// Wall time that passed without uptime passing. Awake, the two clocks track
  /// each other to within scheduling noise, and the shortest dark wake is far
  /// longer than two seconds.
  static let sleepGapAtLeast: TimeInterval = 2

  static func evaluate(
    sample: Sample, previousTick: TapWatchdogClock, now: TapWatchdogClock
  ) -> Outcome {
    let slept = (now.wall.timeIntervalSince(previousTick.wall)) - (now.uptime - previousTick.uptime)
    if slept >= sleepGapAtLeast {
      return .sleptAcrossTick(seconds: slept)
    }
    let pingLost = sample.pingPosted.map { now.wall.timeIntervalSince($0) > pingLostAfter } ?? false
    let probeStuck = sample.probing.map { now.wall.timeIntervalSince($0) > probeStuckAfter } ?? false
    let proberDead = now.wall.timeIntervalSince(sample.alive) > proberDeadAfter
    if pingLost || probeStuck || proberDead {
      return .wedged(pingLost: pingLost, probeStuck: probeStuck, proberDead: proberDead)
    }
    return .healthy
  }
}
