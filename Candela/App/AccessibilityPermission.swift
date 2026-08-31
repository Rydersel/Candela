import AppKit
// @preconcurrency: `kAXTrustedCheckOptionPrompt` is a mutable C global that
// Swift 6 refuses to reference. It is set once at framework load.
@preconcurrency import ApplicationServices
import CandelaKit
import Foundation
import Observation

/// Tracks the Accessibility (TCC) grant the media-key event tap needs.
///
/// D9: observed for the app's whole lifetime, reporting transitions in BOTH
/// directions. Waiting for the grant once is not enough: a re-sign drops it
/// silently and the user can revoke it in System Settings. Either way the media
/// keys die and nothing in the UI would say so.
///
/// The undocumented `com.apple.accessibility.api` distributed notification is
/// the fast path; a poll backstops it at 2 s while the grant is missing, 10 s
/// while it is held.
@MainActor @Observable
final class AccessibilityPermission {
  private(set) var isGranted: Bool

  @ObservationIgnored private var pollTimer: Timer?
  @ObservationIgnored private var onChange: (@MainActor (Bool) -> Void)?
  @ObservationIgnored private var notificationObserver: (any NSObjectProtocol)?
  /// Gates `scheduleBackstop()`: `promptIfNeeded()` can flip the grant before
  /// `startMonitoring` runs, and a timer scheduled then ticks on a nil callback.
  @ObservationIgnored private var isMonitoring = false

  /// Undocumented; the Accessibility subsystem posts it when the trusted-process
  /// list changes.
  private static let accessibilityAPIChanged = NSNotification.Name("com.apple.accessibility.api")

  init() {
    isGranted = AXIsProcessTrustedWithOptions(nil)
  }

  /// Shows the system Accessibility prompt when the grant is missing. No NSAlert:
  /// the system prompt plus the panel banner replace the fork's modal.
  func promptIfNeeded() {
    guard !isGranted else { return }
    // Deliberately the unmanaged constant, not a string literal.
    let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
    // Through `applyGranted`, not a bare assignment: if this call observes the
    // grant already present, the transition still has to reach `onChange` or the
    // tap never starts and `recheck` sees no change to report.
    applyGranted(AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary))
  }

  /// Calls `onChange` on every TRANSITION, grant and revocation both. Never fires
  /// for steady state; the caller reads `isGranted` for that.
  ///
  /// Idempotent: a second call replaces the observer, callback and timer.
  func startMonitoring(onChange: @escaping @MainActor (Bool) -> Void) {
    if let notificationObserver {
      DistributedNotificationCenter.default().removeObserver(notificationObserver)
    }
    self.onChange = onChange
    isMonitoring = true
    notificationObserver = DistributedNotificationCenter.default().addObserver(
      forName: Self.accessibilityAPIChanged, object: nil, queue: nil
    ) { [weak self] _ in
      // TCC needs a moment to settle: reading immediately can still return the
      // pre-change answer. The backstop covers us if it does.
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(100))
        self?.recheck()
      }
    }
    scheduleBackstop()
  }

  static func openSystemSettings() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    )
  }

  /// (Re)arms the backstop poll at the cadence the current state calls for.
  private func scheduleBackstop() {
    pollTimer?.invalidate()
    let interval: TimeInterval = isGranted ? 10 : 2
    // `.common` mode is load-bearing, so this is `Timer(timeInterval:)` plus an
    // explicit `RunLoop.main.add`, not `Timer.scheduledTimer`: a menu tracking
    // session holds the run loop in event-tracking mode, and a default-mode timer
    // would stop firing exactly while the panel is open.
    //
    // The block is `@Sendable`-typed, so `MainActor.assumeIsolated` traps if this
    // timer is ever scheduled on another run loop. It goes on `RunLoop.main` below
    // and nowhere else; if that changes, make it a `Task { @MainActor ... }` hop.
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.recheck() }
    }
    pollTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  /// Never invalidates the timer on success; latching is the defect D9 exists to
  /// prevent.
  private func recheck() {
    applyGranted(AXIsProcessTrustedWithOptions(nil))
  }

  private func applyGranted(_ granted: Bool) {
    guard granted != isGranted else { return }
    isGranted = granted
    // Cadence follows the new state (2 s hunting, 10 s holding).
    if isMonitoring {
      scheduleBackstop()
    }
    onChange?(granted)
  }
}

extension AccessibilityPermission {
  /// Whether a missing grant is worth telling the user about right now.
  ///
  /// Not simply `!isGranted`: custom shortcuts are Carbon hotkeys and need no
  /// grant, so an all-custom rig works without it and must not be nagged. The
  /// Keyboard pane's warning row gates on this same predicate, so the panel
  /// banner has to as well.
  var isWarningWarranted: Bool {
    guard !isGranted else { return false }
    let prefs = DisplayPrefs(persistenceKey: "app")
    return KeyModePolicy.requiresAccessibility(
      brightness: prefs.keyboardBrightness, volume: prefs.keyboardVolume
    )
  }
}
