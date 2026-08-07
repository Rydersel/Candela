import Foundation

/// Accumulated panel-on time for one display (#23, reduced scope).
///
/// Storage keys are engine state rather than `PrefName` cases — nothing routes
/// a usage counter through `SettingsActions`, and `PrefPropagationTests` pins
/// their absence from the enum.
///
/// Deliberately not `Sendable`: confined to whichever actor owns the display's
/// controllers (the main actor today). Making it thread-safe would buy a lock
/// nobody contends and hide the confinement that is actually load-bearing.
public final class PanelHoursTracker {
  public static let standbyNoteThresholdHours: Double = 8
  /// Ticks arrive on the order of seconds; writing each one would put a
  /// defaults write on a permanent timer for every attached display.
  private static let debounceSeconds: Double = 60

  private let defaults: UserDefaults
  private let totalKey: String
  private let standbyKey: String
  private let dismissedKey: String
  private var totalSeconds: Double
  private var sinceStandbySeconds: Double
  private var unwrittenSeconds: Double = 0
  private var noteDismissed: Bool

  public init(defaults: UserDefaults = .standard, persistenceKey: String) {
    self.defaults = defaults
    self.totalKey = "oledPanelSeconds.\(persistenceKey)"
    self.standbyKey = "oledStandbySeconds.\(persistenceKey)"
    self.dismissedKey = "oledStandbyNoteDismissed.\(persistenceKey)"
    self.totalSeconds = defaults.double(forKey: totalKey)
    self.sinceStandbySeconds = defaults.double(forKey: standbyKey)
    self.noteDismissed = defaults.bool(forKey: dismissedKey)
  }

  public var totalHours: Double { totalSeconds / 3600 }
  public var hoursSinceStandby: Double { sinceStandbySeconds / 3600 }
  public var shouldShowStandbyNote: Bool {
    !noteDismissed && hoursSinceStandby >= Self.standbyNoteThresholdHours
  }

  /// Suppresses the note until the next standby. Persisted: an in-memory-only
  /// dismissal comes back on every relaunch while the counter is still over the
  /// threshold, which is exactly the recurring reminder the spec forbids.
  public func dismissStandbyNote() { setDismissed(true) }

  public func noteTick(displayAwake: Bool, secondsSinceLastTick: Double) {
    // The caller derives the delta from wall-clock timestamps, so a clock step
    // backwards yields a negative one. `isFinite` is explicit rather than
    // relying on NaN failing `> 0` incidentally — a NaN or infinite total is
    // unrecoverable once persisted, since every later comparison against it
    // reads false and the counter silently stops meaning anything.
    guard displayAwake, secondsSinceLastTick.isFinite, secondsSinceLastTick > 0 else { return }
    totalSeconds += secondsSinceLastTick
    sinceStandbySeconds += secondsSinceLastTick
    unwrittenSeconds += secondsSinceLastTick
    if unwrittenSeconds > Self.debounceSeconds { writeThrough() }
  }

  /// Display slept, departed, or was powered off over DDC (0xD6). The last of
  /// those is booked by the caller at the moment of the write — the panel goes
  /// dark without macOS noticing anything (#94), so it is never observed.
  public func noteStandby() {
    sinceStandbySeconds = 0
    // The panel got its rest, so the next crossing has earned a fresh note.
    setDismissed(false)
    writeThrough()
  }

  public func reset() {
    totalSeconds = 0
    sinceStandbySeconds = 0
    unwrittenSeconds = 0
    // A wiped counter that can never speak again is worse than one that never
    // counted: without this, a dismissal taken before the reset outlives it.
    noteDismissed = false
    // Removed rather than zeroed: a settings reset should leave no key behind,
    // and every read here already treats absence as zero/false.
    defaults.removeObject(forKey: totalKey)
    defaults.removeObject(forKey: standbyKey)
    defaults.removeObject(forKey: dismissedKey)
  }

  private func setDismissed(_ dismissed: Bool) {
    noteDismissed = dismissed
    if dismissed {
      defaults.set(true, forKey: dismissedKey)
    } else {
      defaults.removeObject(forKey: dismissedKey)  // absence IS "not dismissed"
    }
  }

  private func writeThrough() {
    defaults.set(totalSeconds, forKey: totalKey)
    defaults.set(sinceStandbySeconds, forKey: standbyKey)
    unwrittenSeconds = 0
  }
}
