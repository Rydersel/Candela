import Foundation

/// Accumulated panel-on time for one display.
///
/// Storage keys are engine state rather than `PrefName` cases: nothing routes a
/// usage counter through `SettingsActions`, and a test pins their absence.
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
  /// Read publicly as whole seconds by the provenance record: going out through
  /// the hours accessors and back multiplies a rounding error into the file.
  public private(set) var totalSeconds: Double
  public private(set) var secondsSinceStandby: Double
  private var unwrittenSeconds: Double = 0
  private var noteDismissed: Bool

  public init(defaults: UserDefaults = .standard, persistenceKey: String) {
    self.defaults = defaults
    self.totalKey = "oledPanelSeconds.\(persistenceKey)"
    self.standbyKey = "oledStandbySeconds.\(persistenceKey)"
    self.dismissedKey = "oledStandbyNoteDismissed.\(persistenceKey)"
    self.totalSeconds = defaults.double(forKey: totalKey)
    self.secondsSinceStandby = defaults.double(forKey: standbyKey)
    self.noteDismissed = defaults.bool(forKey: dismissedKey)
  }

  public var totalHours: Double { totalSeconds / 3600 }
  public var hoursSinceStandby: Double { secondsSinceStandby / 3600 }
  public var shouldShowStandbyNote: Bool {
    !noteDismissed && hoursSinceStandby >= Self.standbyNoteThresholdHours
  }

  /// Suppresses the note until the next standby. Persisted: an in-memory-only
  /// dismissal returns on every relaunch while the counter is over threshold,
  /// which is the recurring reminder the spec forbids.
  public func dismissStandbyNote() { setDismissed(true) }

  public func noteTick(displayAwake: Bool, secondsSinceLastTick: Double) {
    // The caller derives the delta from wall-clock timestamps, so a clock step
    // backwards yields a negative one. `isFinite` is explicit: a NaN or infinite
    // total is unrecoverable once persisted, because every later comparison
    // against it reads false and the counter stops meaning anything.
    guard displayAwake, secondsSinceLastTick.isFinite, secondsSinceLastTick > 0 else { return }
    totalSeconds += secondsSinceLastTick
    secondsSinceStandby += secondsSinceLastTick
    unwrittenSeconds += secondsSinceLastTick
    if unwrittenSeconds > Self.debounceSeconds { writeThrough() }
  }

  /// Display slept or departed. A panel switched off at the monitor itself may
  /// be neither: macOS reports a DPMS-blanked panel as awake and never
  /// reconfigures (measured for a `0xD6` write), so a panel held in soft standby
  /// is invisible here. If the button instead deasserts hot-plug detect the
  /// display departs and this IS called; untested, and it varies per monitor.
  public func noteStandby() {
    secondsSinceStandby = 0
    // The panel got its rest, so the next crossing has earned a fresh note.
    setDismissed(false)
    writeThrough()
  }

  public func reset() {
    totalSeconds = 0
    secondsSinceStandby = 0
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
    defaults.set(secondsSinceStandby, forKey: standbyKey)
    unwrittenSeconds = 0
  }
}
