import Foundation

/// The app's unattended restore passes (reapply stored resolutions, then restore
/// the saved layout) run as ONE operation, in order, never overlapping an
/// earlier call's.
///
/// Both passes claim the same `DisplayReconfigurationGate` (AR12), and a refused
/// pass hands its arrival claims back and returns. Handing them back is right,
/// since keeping them would mean "never", but it survives only if something
/// calls the pass again, and what was relied on for that was the gate holder's
/// own reconfiguration event.
///
/// **Neither pass produces one in its dominant case.** Both apply nothing most
/// of the time: no stored modes, no saved layout, or a layout the machine is
/// already in. No `CGCompleteDisplayConfiguration` runs, so no reconfiguration
/// event follows, so the refused pass is never called again for that arrival.
/// Fired back-to-back, whichever claimed second lost, silently.
///
/// Sequencing removes the race rather than retrying against it: the first pass
/// releases the gate before the second claims. It also makes the ordering a
/// guarantee, modes BEFORE layout, because a resolution change resizes the
/// footprints a layout is tiled against.
///
/// It deliberately does not claim the gate itself. A third claimant (mirroring,
/// rotation, an interactive resolution pick) can still interpose and refuse the
/// second pass, and there the released premise is TRUE: those claimants hold the
/// gate only while a reconfiguration or an unanswered preview is outstanding,
/// and resolving one is itself a reconfiguration.
@MainActor
public final class UnattendedRestoreSequence {
  private var pending: Task<Void, Never>?

  public init() {}

  /// Runs `passes` in order, after everything an earlier call queued.
  ///
  /// Fire-and-forget: the caller is a debounced topology handler that must not
  /// block on a display reconfiguration, and chaining rather than spawning is
  /// what stops two topology events from interleaving their halves.
  public func run(_ passes: [@MainActor @Sendable () async -> Void]) {
    let previous = pending
    pending = Task { @MainActor in
      _ = await previous?.value
      for pass in passes { await pass() }
    }
  }

  /// Awaits the operation queued **at the time of the call**. Work queued while
  /// it is suspended is not waited on, which keeps a caller deterministic.
  public func settle() async {
    _ = await pending?.value
  }
}
