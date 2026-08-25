import Foundation

/// Two readings of "now" for the tap watchdog: the wall clock, which the
/// heartbeat stamps carry, and the system uptime clock, which stops while the
/// machine sleeps. The difference in how far each advanced between two monitor
/// ticks is the sleep the machine took in between.
struct TapWatchdogClock: Sendable, Equatable {
  var wall: Date
  var uptime: TimeInterval

  static func now() -> TapWatchdogClock {
    TapWatchdogClock(wall: Date(), uptime: ProcessInfo.processInfo.systemUptime)
  }
}

/// The deadman switch's decision, kept pure so its one measured false fire
/// stays pinned: at a dark wake the monitor thread resumes before the prober
/// and reads a stamp exactly as old as the sleep. It fired 87 times in three
/// days on the dev machine, always `proberDead` alone, always at a dark wake,
/// each one an exit-and-relaunch of the app with nothing wedged.
enum TapWatchdogVerdict {
  struct Sample: Sendable {
    var pingPosted: Date?
    var probing: Date?
    var alive: Date
  }

  enum Outcome: Equatable, Sendable {
    case healthy
    /// The machine slept for about this long since the previous tick. Every
    /// stamp is that much older than the prober's real silence, so the tick
    /// carries no verdict and the caller resets the stamps.
    case sleptAcrossTick(seconds: TimeInterval)
    case wedged(pingLost: Bool, probeStuck: Bool, proberDead: Bool)
  }

  /// Ping unanswered > 5 s: pipeline wedged. Probe/AX in flight > 5 s or the
  /// prober loop silent > 12 s: the prober is stuck. 5 s tolerates the
  /// platform's legitimate stalls (mode changes and rotation block up to
  /// ~1.1 s, measured on the rotation work).
  static let pingLostAfter: TimeInterval = 5
  static let probeStuckAfter: TimeInterval = 5
  static let proberDeadAfter: TimeInterval = 12
  /// Wall time that passed without uptime passing. Awake, the two clocks
  /// advance together to within scheduling noise; two whole seconds apart is
  /// a sleep, and the shortest dark wake cycle is far longer than that.
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
