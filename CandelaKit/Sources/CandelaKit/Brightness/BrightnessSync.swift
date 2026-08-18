import os

/// Cross-display brightness sync (fork `AppDelegate.job`,
/// AppDelegate.swift:238-253): a change observed on a native source — Control
/// Center, the ambient-light sensor, a TouchBar slider — replicates onto every
/// other display so a whole desk tracks one move.
public enum BrightnessSync {
  /// Accumulates `delta` into the source's `SyncDeadband` and applies what
  /// comes back out to every controller except `source`.
  ///
  /// The deadband is why this takes movement rather than replicating it: the
  /// built-in's ambient auto-brightness hunts continuously, and fanning those
  /// sub-perceptual nudges out turned an invisible source change into a
  /// visible oscillation on the externals plus a permanent DDC write stream.
  /// Deltas below the band are held, not dropped, so a deliberate change that
  /// arrives as several eased steps still tracks.
  ///
  /// Each target goes through the normal `setBrightness` funnel, so it applies
  /// the step via its own path (combined/native/software) and clamps at the
  /// ends, fork-faithfully.
  ///
  /// A disabled call re-centres the band, so movement observed while sync was
  /// off does not replay when it comes back on. Only movement re-centres it:
  /// the toggle itself never reaches here (its pref propagation rebuilds the
  /// panel and nothing else), so a residual can survive a quiet off/on cycle
  /// and ride out with the first nudge afterwards. Bounded by one band, which
  /// is why that is left alone rather than wired to the pref.
  ///
  /// No feedback loop by construction: a native target's write lands in its own
  /// expected-native slot, so the poller sees the replicated value as an echo;
  /// the source's own adoption never re-submits a native write (Task 6 rule).
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
      // Diagnostics for "the other display followed/didn't follow" reports:
      // the same `path` category as the controller's own mode/settle lines, so
      // one predicate shows the source's adoption and every replication.
      // `delta=` is the released accumulation, not the source's own step, so
      // line COUNTS compare across builds but magnitudes do not.
      pathLog.log(
        "sync fan-out delta=\(step, format: .fixed(precision: 4)) from=\(source.displayID) to=\(target.displayID)"
      )
      target.setBrightness(target.brightness + step)
    }
  }
}
