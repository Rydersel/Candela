import Foundation
import Observation
import ServiceManagement

/// Launch-at-login via SMAppService (D10). ONE source of truth: `isEnabled` is
/// always re-read from `SMAppService.mainApp.status` after every mutation —
/// never a mirrored bool — so a failed register() shows OFF plus an error
/// instead of the fork's lying checkbox.
///
/// Follow-up (Task 18): a one-line `status: @escaping () -> SMAppService.Status`
/// injection seam would make that invariant testable. Left out here because M5
/// adds no app test target and an untested seam buys nothing.
@MainActor @Observable
final class LoginItem {
  private(set) var isEnabled: Bool
  private(set) var lastError: String?

  init() {
    isEnabled = SMAppService.mainApp.status == .enabled
  }

  func refresh() {
    isEnabled = SMAppService.mainApp.status == .enabled
  }

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
