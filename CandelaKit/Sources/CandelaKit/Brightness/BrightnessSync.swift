import os

/// Cross-display brightness sync (fork `AppDelegate.job`). A change observed on
/// a native source, such as Control Center or the ambient-light sensor,
/// replicates onto every other display so a whole desk tracks one move.
public enum BrightnessSync {
  /// Accumulates `delta` into the source's `SyncDeadband` and applies what
  /// comes back out to every controller except `source`.
  ///
  /// Takes movement rather than a value because of the deadband: the built-in's
  /// ambient auto-brightness hunts continuously, and fanning those
  /// sub-perceptual nudges out oscillated the externals and left a permanent
  /// DDC write stream. Deltas below the band are held, not dropped.
  ///
  /// A disabled call re-centres the band, so movement observed while sync was
  /// off does not replay when it comes back on. Only movement re-centres it, so
  /// a residual can survive a quiet off/on cycle and ride out with the first
  /// nudge. One band is the whole exposure, which is why the toggle is not
  /// wired to it.
  ///
  /// No feedback loop by construction: a native target's write lands in its own
  /// expected-native slot, so the poller sees the replicated value as an echo,
  /// and the source's own adoption never re-submits a native write.
  @MainActor
  public static func fanOut(
    delta: Double,
    from source: BrightnessController,
    to controllers: [BrightnessController],
    isEnabled: Bool
  ) {
    guard isEnabled else {
      source.syncDeadband.reset()
      return
    }
    guard delta != 0, let step = source.syncDeadband.admit(delta) else { return }
    for target in controllers where target !== source {
      // Same `path` category as the controller's own mode and settle lines, so
      // one predicate shows the source's adoption and every replication.
      // `delta=` is the released accumulation, not the source's own step.
      pathLog.log(
        "sync fan-out delta=\(step, format: .fixed(precision: 4)) from=\(source.displayID) to=\(target.displayID)"
      )
      target.setBrightness(target.brightness + step)
    }
  }
}
