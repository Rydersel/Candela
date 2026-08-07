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
  private var totalSeconds: Double
  private var sinceStandbySeconds: Double
  private var unwrittenSeconds: Double = 0
  private var noteDismissed = false

  public init(defaults: UserDefaults = .standard, persistenceKey: String) {
    self.defaults = defaults
    self.totalKey = "oledPanelSeconds.\(persistenceKey)"
    self.standbyKey = "oledStandbySeconds.\(persistenceKey)"
    self.totalSeconds = defaults.double(forKey: totalKey)
    self.sinceStandbySeconds = defaults.double(forKey: standbyKey)
  }

  public var totalHours: Double { totalSeconds / 3600 }
  public var hoursSinceStandby: Double { sinceStandbySeconds / 3600 }
  public var shouldShowStandbyNote: Bool {
    !noteDismissed && hoursSinceStandby >= Self.standbyNoteThresholdHours
  }

  /// Suppresses the note for the current run only; the next standby re-arms it.
  public func dismissStandbyNote() { noteDismissed = true }

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

  /// Display slept, departed, or answered a DDC power-mode (0xD6) standby.
  public func noteStandby() {
    sinceStandbySeconds = 0
    noteDismissed = false
    writeThrough()
  }

  public func reset() {
    totalSeconds = 0
    sinceStandbySeconds = 0
    // A wiped counter that can never speak again is worse than one that never
    // counted: without this, a dismissal taken before the reset outlives it.
    noteDismissed = false
    writeThrough()
  }

  private func writeThrough() {
    defaults.set(totalSeconds, forKey: totalKey)
    defaults.set(sinceStandbySeconds, forKey: standbyKey)
    unwrittenSeconds = 0
  }
}
