import Foundation
import Observation
import Sparkle

/// Owns the app's one Sparkle updater and adapts it for SwiftUI observation.
///
/// Sparkle is the store for every updater setting (`SUEnableAutomaticChecks`
/// and friends live in our defaults domain but are Sparkle's schema, not
/// `PrefName` cases), so the toggle below writes through to the updater rather
/// than persisting anything of our own: the same one-source-of-truth shape as
/// launch-at-login. `automaticallyChecksForUpdates` is a stored mirror
/// ONLY because `@Observable` cannot invalidate a view from a computed property
/// over foreign storage. The user-driver delegate is wired here too, for the
/// scheduled-update reminder the menu bar shows; it adds no preference either.
@MainActor @Observable
final class UpdaterModel {
  let completion = UpdateCompletionState()
  let reminder = UpdateReminderState()
  @ObservationIgnored private let controller: SPUStandardUpdaterController
  // Sparkle holds both delegates weakly, so the model owns them.
  @ObservationIgnored private let relaunchDelegate = UpdateRelaunchDelegate()
  @ObservationIgnored private let reminderDelegate: UpdateReminderDelegate

  /// False while a check or install is in flight; drives the button's
  /// disabled state. Mirrored from Sparkle's KVO-compliant property.
  private(set) var canCheckForUpdates = false
  private(set) var lastUpdateCheckDate: Date?

  var automaticallyChecksForUpdates: Bool {
    didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
  }

  @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

  init() {
    // Sparkle's recommended shape; the scheduled check fires only if automatic
    // checks are enabled. The `--vd-engage` helper never reaches here: it exits
    // inside CandelaMain before any app machinery is built.
    reminderDelegate = UpdateReminderDelegate(reminder: reminder)
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: relaunchDelegate,
      userDriverDelegate: reminderDelegate
    )
    automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    lastUpdateCheckDate = controller.updater.lastUpdateCheckDate
    canCheckObservation = controller.updater.observe(
      \.canCheckForUpdates, options: [.initial, .new]
    ) { [weak self] updater, _ in
      // KVO delivers on the main thread here, but the closure is nonisolated;
      // hop rather than assume. Re-reading the check date on every flip is what
      // refreshes "Last checked".
      let canCheck = updater.canCheckForUpdates
      let lastCheck = updater.lastUpdateCheckDate
      Task { @MainActor [weak self] in
        self?.canCheckForUpdates = canCheck
        self?.lastUpdateCheckDate = lastCheck
      }
    }
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }

  /// Brings the already-prepared alert back into focus for the panel's reminder
  /// row. Sparkle's route for that is this same call: the deferred session is
  /// still open, so nothing starts a second check.
  func bringUpdateForward() {
    controller.checkForUpdates(nil)
  }

  /// For the settings reset, whose wipe takes Sparkle's keys with it. The toggle
  /// is assigned only on change, so nothing echoes back through `didSet`.
  func refreshFromUpdater() {
    let automatic = controller.updater.automaticallyChecksForUpdates
    if automaticallyChecksForUpdates != automatic { automaticallyChecksForUpdates = automatic }
    lastUpdateCheckDate = controller.updater.lastUpdateCheckDate
    canCheckForUpdates = controller.updater.canCheckForUpdates
  }
}
