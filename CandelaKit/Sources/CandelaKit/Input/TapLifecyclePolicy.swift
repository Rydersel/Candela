/// What the app should do to the media-key event tap after the watched-key set
/// is recomputed.
public enum TapLifecycleAction: Sendable, Equatable {
  case start
  case stop
  case reconfigure
  case nothing
}

/// Decides whether the media-key tap should exist at all right now.
///
/// A tap watching nothing still costs a run-loop thread and two watchdog threads
/// while every key passes through, so one exists only while something is watched.
/// The edge is decided from the INTENDED sets, never the tap's `isRunning`: an
/// emergency teardown leaves that flag true.
public enum TapLifecyclePolicy {
  /// `previous` is the last watched set the app committed to: nil when no tap
  /// could be armed at all (no grant, or a start that failed), which is not the
  /// same as an empty set. Empty means the app deliberately watches nothing and
  /// can pick the tap back up the moment a key needs it; nil means something
  /// outside this decision has to change first, so restarting from here would
  /// retry a failed start on every reconfigure and every menu close.
  ///
  /// Two non-empty sets always reconfigure, equal or not: the config carries the
  /// alternate-brightness-key flag as well, and that pref reaches the tap
  /// through this same path.
  public static func action(
    previous: Set<MediaKey>?,
    next: Set<MediaKey>,
    grantHeld: Bool
  ) -> TapLifecycleAction {
    guard grantHeld else { return .nothing }
    guard let previous else { return .nothing }
    if previous.isEmpty {
      return next.isEmpty ? .nothing : .start
    }
    return next.isEmpty ? .stop : .reconfigure
  }
}
