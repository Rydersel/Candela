import AppKit
import Foundation
import Observation
import ServiceManagement

/// The three SMAppService touchpoints behind one injectable value (the D21
/// follow-up, built once its test-target precondition existed). The closures
/// are the seam, not a cache: `status` executes on every read, so D10's
/// live-read invariant survives injection by construction. Production is
/// `.live`; tests substitute a fake whose backing they mutate to prove the
/// answer tracks the system, never a mirror.
@MainActor
struct LoginItemService {
  var status: () -> SMAppService.Status
  var register: () throws -> Void
  var unregister: () throws -> Void

  static let live = LoginItemService(
    status: { SMAppService.mainApp.status },
    register: { try SMAppService.mainApp.register() },
    unregister: { try SMAppService.mainApp.unregister() })
}

/// Launch-at-login via SMAppService (D10). ONE source of truth: `isEnabled` is
/// a LIVE read of the service status — never a mirrored bool — so a
/// failed register() shows OFF plus an error instead of the fork's lying
/// checkbox.
@MainActor @Observable
final class LoginItem {
  @ObservationIgnored private let service: LoginItemService
  /// D10: ONE source of truth. Never a mirrored bool — the settings reset
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
    return service.status() == .enabled
  }

  private(set) var lastError: String?

  /// Registered once, removed in `deinit`. `nonisolated(unsafe)` because a
  /// `deinit` is nonisolated and cannot touch main-actor state; the property is
  /// written exactly once, from `init`, on the main actor.
  @ObservationIgnored nonisolated(unsafe) private var activationObserver: (any NSObjectProtocol)?

  // Optional-with-nil rather than a `.live` default argument: a default is
  // evaluated in a nonisolated context, and `.live` is main-actor state.
  init(service: LoginItemService? = nil) {
    self.service = service ?? .live
    // Closes the last hole in D10: a live *read* is not a
    // live *render*, and `.onAppear` only fires when a pane appears. Becoming
    // active is the moment any already-open window showing this toggle is
    // about to be looked at, and it is the only signal that covers a change
    // made in System Settings → General → Login Items — or by `sfltool` —
    // while Candela sat in the background. With it, the Setup window and the
    // General pane both correct themselves on the way back.
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // `queue: .main` guarantees the main *thread*; assumeIsolated asserts
      // the isolation the compiler cannot infer through a @Sendable block.
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  deinit {
    if let activationObserver {
      NotificationCenter.default.removeObserver(activationObserver)
    }
  }

  func refresh() { refreshToken &+= 1 }

  func setEnabled(_ enabled: Bool) {
    do {
      if enabled {
        try service.register()
      } else {
        try service.unregister()
      }
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
    refresh()
  }
}
