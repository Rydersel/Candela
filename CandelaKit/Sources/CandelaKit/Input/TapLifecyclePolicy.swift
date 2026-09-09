/// What the app should do to the media-key event tap after the watched-key set
/// is recomputed.
public enum TapLifecycleAction: Sendable, Equatable {
  case start
  case stop
  case reconfigure
  /// Nothing is watched and no tap exists, so there is nothing to do to one. The
  /// empty set is committed anyway: "watching nothing on purpose" and "no tap could
  /// run" are different answers, and diagnostics reports them apart.
  case recordEmpty
  case nothing
}

/// Decides whether the media-key tap should exist at all right now.
///
/// A tap watching nothing still costs a run-loop thread and two watchdog threads
/// while every key passes through, so one exists only while something is watched.
/// The edge is decided from the INTENDED sets, never the tap's `isRunning`: an
/// emergency teardown leaves that flag true.
public enum TapLifecyclePolicy {
  /// `previous` nil: no tap could be armed (no grant, or a failed start). Not the
  /// empty set, and retryable, since most start failures are transient.
  /// `permanentlyUnavailable` is the one failure a retry cannot fix.
  /// Equal non-empty sets still reconfigure: the config also carries the
  /// alternate-brightness-key flag.
  public static func action(
    previous: Set<MediaKey>?,
    next: Set<MediaKey>,
    grantHeld: Bool,
    permanentlyUnavailable: Bool
  ) -> TapLifecycleAction {
    guard grantHeld else { return .nothing }
    // Set only where no tap exists, so there is never one here to stop.
    guard !permanentlyUnavailable else { return .nothing }
    guard let previous else { return next.isEmpty ? .recordEmpty : .start }
    if previous.isEmpty {
      return next.isEmpty ? .nothing : .start
    }
    return next.isEmpty ? .stop : .reconfigure
  }
}
