import Foundation
import os

/// The serial chain a display-configuration coordinator runs its work through,
/// so that no two reconfigurations of the same kind are ever in flight at once.
///
/// **Ordering only.** It deliberately knows nothing about `isApplying`, which
/// is raised at the command site by whoever is applying something. Everything
/// else that queues work here (a countdown tick, a departure discard, an answer)
/// reconfigures nothing on its own, and a queue that greyed out controls for
/// those was a real defect.
///
/// A reference type rather than a value type: `enqueueReturning` both mutates
/// `pending` and suspends, and a `mutating async` method on a struct stored in a
/// class property holds exclusive access across the suspension.
///
/// In CandelaKit rather than the app target: there is no app test target,
/// so an app-target copy would be verifiable only by running the UI, while here
/// it is pure plumbing with tests.
public final class PreviewQueue: Sendable {
  /// Behind a lock rather than a main-actor stored property so `cancel()` can be
  /// `nonisolated`. Every coordinator cancels from its `deinit`, which cannot
  /// hop, so a main-actor-only tail would quietly drop that cancellation.
  private let pending = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

  public init() {}

  @MainActor
  public func enqueue(_ operation: @escaping @MainActor () async -> Void) {
    let previous = pending.withLock { $0 }
    let task = Task { @MainActor in
      _ = await previous?.value
      await operation()
    }
    pending.withLock { $0 = task }
  }

  @MainActor
  @discardableResult
  public func enqueueReturning<T: Sendable>(
    _ operation: @escaping @MainActor () async -> T
  ) async -> T {
    let previous = pending.withLock { $0 }
    let task = Task { @MainActor () -> T in
      _ = await previous?.value
      return await operation()
    }
    // The chain is Void-typed, so the next operation waits on this one through
    // an erased wrapper rather than on its result.
    let erased = Task { @MainActor in _ = await task.value }
    pending.withLock { $0 = erased }
    return await task.value
  }

  /// Cancels whatever is queued. Called from a coordinator's `deinit`.
  public nonisolated func cancel() {
    pending.withLock { $0?.cancel() }
  }
}
