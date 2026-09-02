import Foundation

/// Startup and wake restore choreography. After wake it waits out the sober
/// delay, since some displays take time to recover, then repeats the restore pass at
/// a fixed interval. The app injects the pass; it covers the brightness DDC leg,
/// contrast, volume, and the mute companion.
@MainActor
public final class RestoreCoordinator {
  private let startupAction: () -> StartupAction
  private let soberDelay: Duration
  private let repeatInterval: Duration
  private let repeatCount: Int
  /// The injected pass MUST reset every controller's duplicate memo before
  /// rewriting, or the repeats are coalesced away and never hit the wire.
  public var restorePass: (@MainActor () -> Void)?
  /// Supersession token: a newer wake restarts the chain, and the older one's next
  /// check orphans it.
  private var wakeGeneration: UInt64 = 0

  public init(
    startupAction: @escaping () -> StartupAction,
    soberDelay: Duration = .seconds(3),
    repeatInterval: Duration = .seconds(1),
    repeatCount: Int = 10
  ) {
    self.startupAction = startupAction
    self.soberDelay = soberDelay
    self.repeatInterval = repeatInterval
    self.repeatCount = repeatCount
  }

  /// Launch and reconfigure restore: one pass, no repeats. Only wake earns the
  /// repeat loop.
  public func noteLaunchOrReconfigure() {
    guard startupAction() == .write else { return }
    restorePass?()
  }

  public func noteWake() {
    guard startupAction() == .write else { return }
    wakeGeneration &+= 1
    let generation = wakeGeneration
    // Plain Task, NOT detached (F10): main-actor inheritance is what makes the
    // wakeGeneration check race-free and what the "no pass before the sober delay"
    // test relies on. Do not switch to Task.detached under concurrency friction.
    Task { [weak self] in
      // The strong ref deliberately pins the coordinator for the chain's whole
      // duration: once a wake chain starts it must run to completion. Safe because
      // AppModel and StatusItemController own the coordinator for the app's life.
      guard let self else { return }
      try? await Task.sleep(for: self.soberDelay)
      for _ in 0 ..< self.repeatCount {
        guard self.wakeGeneration == generation else { return }
        self.restorePass?()
        try? await Task.sleep(for: self.repeatInterval)
      }
    }
  }
}
