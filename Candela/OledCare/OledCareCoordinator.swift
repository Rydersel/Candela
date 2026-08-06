import Foundation
import Observation

/// OLED care: the idle/blackout timers, the care dim and the hours tracker.
///
/// A shell in Task 1 — the pref schema lands first so `SettingsActions` has a
/// real destination for `.reapplyOledCare` and the app builds without the
/// engine. Task 7 grows it.
///
/// Owned by `AppModel` for `DisplayModeCoordinator`'s reason: the timers must
/// outlive whatever window or pane started them.
@MainActor
@Observable
final class OledCareCoordinator {
  /// Re-arm this display's care timers after a pref edit; nil means every
  /// enrolled display (an app-level write).
  func reapplyAfterPrefChange(persistenceKey: String?) {}
}
