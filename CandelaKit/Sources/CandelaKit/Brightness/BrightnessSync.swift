//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others

import os

/// Cross-display brightness sync (fork `AppDelegate.job`,
/// AppDelegate.swift:238-253): a change observed on a native source — Control
/// Center, the ambient-light sensor, a TouchBar slider — replicates onto every
/// other display so a whole desk tracks one move.
public enum BrightnessSync {
  /// Applies `delta` to every controller except `source`.
  ///
  /// Each target goes through the normal `setBrightness` funnel, so it applies
  /// the step via its own path (combined/native/software) and clamps at the
  /// ends, fork-faithfully. Per-tick deltas are the poller's eased ~1/3-gap
  /// steps, so replication is smooth by construction.
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
    guard delta != 0, isEnabled else { return }
    for target in controllers where target !== source {
      // Diagnostics for "the other display followed/didn't follow" reports:
      // the same `path` category as the controller's own mode/settle lines, so
      // one predicate shows the source's adoption and every replication.
      pathLog.log(
        "sync fan-out delta=\(delta, format: .fixed(precision: 4)) from=\(source.displayID) to=\(target.displayID)"
      )
      target.setBrightness(target.brightness + delta)
    }
  }
}
