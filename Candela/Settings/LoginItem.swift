import Foundation
import Observation
import ServiceManagement

/// Launch-at-login via SMAppService (D10). ONE source of truth: `isEnabled` is
/// a LIVE read of `SMAppService.mainApp.status` — never a mirrored bool — so a
/// failed register() shows OFF plus an error instead of the fork's lying
/// checkbox.
///
/// Follow-up (Task 18): a one-line `status: @escaping () -> SMAppService.Status`
/// injection seam would make that invariant testable. Left out here because M5
/// adds no app test target and an untested seam buys nothing.
@MainActor @Observable
final class LoginItem {
  /// D10: ONE source of truth. Never a mirrored bool — Task 8's settings reset
  /// unregisters the main app directly (`SMAppService.mainApp.unregister()`),
  /// and System Settings → General → Login Items can disable it at any moment
  /// with no notification to us. Both would leave a mirror reading ON forever,
  /// which is exactly the fork defect D10 exists to fix.
  ///
  /// `refreshToken` is the observation dependency: `@Observable` cannot track a
  /// computed property backed by an external system, so mutating the token is
  /// how a view is told to re-read. `refresh()` is safe to call on every window
  /// appearance and on `didBecomeActive`.
  private var refreshToken = 0

  var isEnabled: Bool {
    _ = refreshToken // observation dependency; the value below is always live
    return SMAppService.mainApp.status == .enabled
  }

  private(set) var lastError: String?

  func refresh() { refreshToken &+= 1 }

  func setEnabled(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
    refresh()
  }
}
