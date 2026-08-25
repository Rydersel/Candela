import Foundation
import os

/// The serial chain a display-configuration coordinator runs its work through,
/// so that no two reconfigurations of the same kind are ever in flight at once.
///
/// Four coordinators (mode, mirror, rotation, arrangement) each held their own
/// byte-identical copy of this. #64 is why it is only extractable now: rotation's
/// copy folded `isApplying` INTO the primitive, and consolidating before that was
/// fixed would have frozen the divergent shape into the shared abstraction and
/// spread the defect to the other three.
///
/// **Ordering only.** It deliberately knows nothing about `isApplying`, which is
/// raised at the command site by whoever is applying something. Everything else
/// that queues work here (a countdown tick, a departure discard, an answer)
/// reconfigures nothing on its own, and a queue that greyed out controls for
/// those is exactly the defect #64 fixed.
///
/// A reference type rather than the value type the consolidation issue sketched:
/// `enqueueReturning` both mutates `pending` and suspends, and a `mutating async`
/// method on a struct stored in a class property holds exclusive access across
/// the suspension.
///
/// In CandelaKit rather than the app target, which is a deliberate departure from
/// #68's plan. There is no app test target (D21, #80), so an app-target copy of
/// this would be verifiable only by running the UI; here it is pure plumbing with
/// no AppKit or SwiftUI in it, and it has tests.
public final class PreviewQueue: Sendable {
  /// Behind a lock rather than a main-actor stored property so `cancel()` can be
  /// `nonisolated`. Every coordinator cancels from its `deinit`, which is
  /// nonisolated and cannot hop; a main-actor-only tail would have quietly
  /// dropped that cancellation, and losing teardown as a side effect of a
  /// consolidation is exactly what "behaviour-preserving" rules out.
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
