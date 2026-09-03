import Foundation
import os

/// Drives a preview session's clock: one tick a second until the session
/// returns an outcome, then stops.
///
/// This is the expiry that rescues a display nobody meant to reconfigure. Two
/// details are the whole reason it is written this way:
///
/// - **Detached.** A main thread wedged inside a synchronous reconfiguration
///   callback must not be able to stop the expiry. `Task.detached` does not
///   inherit the caller's actor, so the clock keeps running while the main
///   actor is blocked.
/// - **A fire-and-forget hop back.** The tick does NOT await the main-actor work
///   it schedules. Awaiting it would put the wedged main thread back on the
///   clock's critical path, which is what being detached is for.
///
/// `interval` is injectable so the behaviour is testable in milliseconds rather
/// than by waiting out real seconds; nothing in the app passes anything else.
///
/// In CandelaKit and not the app target, for `PreviewQueue`'s reason: with no
/// app test target, an app-target copy could only be checked by watching a
/// countdown run on hardware.
public final class PreviewCountdownDriver: Sendable {
  /// Behind a lock, not a main-actor property, so `stop()` is `nonisolated`:
  /// every coordinator cancels its clock from a nonisolated `deinit`, which a
  /// main-actor-only stop would silently drop.
  private let slot = OSAllocatedUnfairLock<Slot>(initialState: Slot())
  private let interval: Duration

  /// The generation lets a clock that expires clear its own slot without
  /// touching the one a restart put there after it.
  private struct Slot {
    var task: Task<Void, Never>?
    var generation: UInt64 = 0
  }

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
    // Captured directly, not via `self`: a self-task-self cycle would keep the
    // driver alive past the coordinator `deinit` that is its only `stop()` call.
    let slot = slot
    // One acquisition for cancel, bump and install, so no clock can finish and
    // nothing can `stop()` in between; two live clocks on one session would
    // spend it in half the time. Creating the task here is safe: a detached
    // task never runs inline on its creating thread. The lock is not reentrant:
    // nothing unbounded and no call into app code belongs inside this acquisition.
    slot.withLock { state in
      state.task?.cancel()
      state.generation += 1
      let generation = state.generation
      state.task = Task.detached {
        defer {
          // A spent clock must not read as armed. Only its own generation is
          // cleared: after a restart the slot belongs to the live clock.
          slot.withLock { current in
            if current.generation == generation { current.task = nil }
          }
        }
        while !Task.isCancelled {
          try? await Task.sleep(for: interval)
          if Task.isCancelled { return }
          let outcome = await tick()
          Task { @MainActor in onTick(outcome) }
          // The countdown fires at most once; whatever it returned, it is spent.
          if outcome != nil { return }
        }
      }
    }
  }

  public nonisolated func stop() {
    slot.withLock { current in
      current.task?.cancel()
      current.task = nil
    }
  }

  /// Test seam: whether a clock is currently armed. Not used by the app, which
  /// tracks that through its own preview state.
  public nonisolated var isRunning: Bool {
    slot.withLock { $0.task != nil && !($0.task?.isCancelled ?? true) }
  }
}
