import Foundation

/// The app's unattended restore passes — reapply stored resolutions, then
/// restore the saved layout — run as ONE operation, in order, and never
/// overlapping an earlier call's.
///
/// ## Why it exists
///
/// Both passes claim the same `DisplayReconfigurationGate` (AR12), and a refused
/// pass hands its arrival claims back and returns. Handing them back is right —
/// keeping them would mean "never", since an arrival is only re-armed by an
/// observed absence or a topology-signature change — but it is only survivable
/// if something calls the pass again, and what was relied on for that was the
/// holder's own reconfiguration event.
///
/// **Neither pass produces one in its dominant case.** Both decide to apply
/// nothing most of the time: a user with no stored modes, or no saved layout,
/// or a layout the machine is already in. No `CGCompleteDisplayConfiguration`
/// runs, so no reconfiguration event follows, so the refused pass is never
/// called again for that arrival. Fired back-to-back, whichever claimed second
/// lost — silently, and in whichever direction won the race that time.
///
/// Sequencing removes the race instead of scheduling a retry against it: the
/// first pass has released the gate before the second claims, so neither can
/// starve the other. It also turns §7.4's ordering — modes BEFORE layout,
/// because a resolution change resizes the footprints a layout is tiled
/// against — from an intent into a guarantee.
///
/// What it deliberately does not do is claim the gate itself. A third claimant
/// (mirroring, rotation, an interactive resolution pick) can still interpose
/// between the two passes and refuse the second — and there the released
/// premise is TRUE, because those claimants hold the gate only while a
/// reconfiguration or an unanswered preview is outstanding, and resolving one
/// is itself a reconfiguration.
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
  /// it is suspended is not waited on, which is what keeps a test that calls
  /// this deterministic rather than open-ended.
  public func settle() async {
    _ = await pending?.value
  }
}
