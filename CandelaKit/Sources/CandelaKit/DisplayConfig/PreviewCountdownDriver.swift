import Foundation
import os

/// Drives a preview session's clock: one tick a second until the session
/// returns an outcome, then stops.
///
/// This is the expiry that rescues a display nobody meant to reconfigure, and it
/// existed four times over (mode, mirror, rotation, arrangement) in bodies that
/// differed by one comment. The safety-critical part is the SHAPE, and the shape
/// should exist once.
///
/// Two details that are the whole reason it is written this way, both carried
/// over verbatim:
///
/// - **Detached.** A main thread wedged inside a synchronous reconfiguration
///   callback must not be able to stop the expiry. `Task.detached` does not
///   inherit the caller's actor, so the clock keeps running while the main actor
///   is blocked.
/// - **A fire-and-forget hop back.** The tick does NOT await the main-actor work
///   it schedules. Awaiting it would put the wedged main thread back on the
///   clock's critical path, which is what being detached is for.
///
/// `interval` is injectable so the behaviour is testable in milliseconds rather
/// than by waiting out real seconds; nothing in the app passes anything but the
/// default.
///
/// In CandelaKit and not the app target, for `PreviewQueue`'s reason: with no app
/// test target, an app-target copy could only be checked by watching a countdown
/// run on hardware.
public final class PreviewCountdownDriver: Sendable {
  /// Behind a lock, not a main-actor property, so `stop()` is `nonisolated`:
  /// every coordinator cancels its clock from a nonisolated `deinit`, and a
  /// main-actor-only stop would have silently dropped that.
  private let task = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
  private let interval: Duration

  public init(interval: Duration = .seconds(1)) {
    self.interval = interval
  }

  /// Restarts the clock. `tick` advances the session by one second off the main
  /// actor and returns nil while it is still running; `onTick` is handed
  /// whatever it returned, on the main actor.
  ///
  /// `onTick` should capture its coordinator weakly: this object outlives an
  /// individual countdown, and a strong capture would keep the coordinator alive
  /// through it.
  @MainActor
  public func start<Outcome: Sendable>(
    tick: @escaping @Sendable () async -> Outcome?,
    onTick: @escaping @Sendable @MainActor (Outcome?) -> Void
  ) {
    let interval = interval
    let started = Task.detached {
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        if Task.isCancelled { return }
        let outcome = await tick()
        Task { @MainActor in onTick(outcome) }
        // The countdown fires at most once; whatever it returned, it is spent.
        if outcome != nil { return }
      }
    }
    // Swapped under the lock, so a restart cannot lose the clock it replaces:
    // two live clocks on one session would spend it in half the time.
    task.withLock { current in
      current?.cancel()
      current = started
    }
  }

  public nonisolated func stop() {
    task.withLock { current in
      current?.cancel()
      current = nil
    }
  }

  /// Test seam: whether a clock is currently armed. Not used by the app, which
  /// tracks that through its own preview state.
  public nonisolated var isRunning: Bool {
    task.withLock { $0 != nil && !($0?.isCancelled ?? true) }
  }
}
