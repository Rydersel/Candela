import Foundation

/// Startup/wake restore choreography (D5; fork AppDelegate.soberNow +
/// startupActionWriteRepeatAfterSober): after wake, wait out the 3.0 s sober
/// delay ("some displays take time to recover"), then run the restore pass
/// 10 times at 1.0 s intervals. The pass itself is injected by the app and
/// covers brightness DDC leg + contrast + volume + mute companion —
/// DIVERGENCE: the fork's wake loop covered only contrast + brightness;
/// volume/mute were forgotten (fork DisplayManager.restoreOtherDisplays).
@MainActor
public final class RestoreCoordinator {
  private let startupAction: () -> StartupAction
  private let soberDelay: Duration
  private let repeatInterval: Duration
  private let repeatCount: Int
  /// The injected pass MUST reset every controller's duplicate memo before
  /// re-writing, or repeats 2…10 are coalesced away and never hit the wire
  /// (the fork has the same trap via writeDDCLastSavedValue).
  public var restorePass: (@MainActor () -> Void)?
  /// Supersession token (fork startupActionWriteCounter): a newer wake
  /// restarts the chain and the older one's next check orphans it.
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

  /// Launch and reconfigure restore: one pass, no repeats (fork parity — only
  /// wake earns the repeat loop).
  public func noteLaunchOrReconfigure() {
    guard startupAction() == .write else { return }
    restorePass?()
  }

  public func noteWake() {
    guard startupAction() == .write else { return }
    wakeGeneration &+= 1
    let generation = wakeGeneration
    // Plain Task, NOT detached (test-design F10): main-actor inheritance is
    // what makes the wakeGeneration check race-free and what the tests'
    // "no pass before the sober delay" assertion relies on. Do not "fix"
    // this to Task.detached under strict-concurrency friction.
    Task { [weak self] in
      // The strong ref deliberately pins the coordinator for the chain's
      // whole duration (~13 s): once a wake chain has started it must run to
      // completion, not evaporate mid-way. Safe because AppModel /
      // StatusItemController own the coordinator for the app's lifetime.
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
