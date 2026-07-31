import AppKit
// @preconcurrency: `kAXTrustedCheckOptionPrompt` is imported as a mutable C
// global (extern CFStringRef), which Swift 6 otherwise refuses to reference.
// It is de-facto immutable — set once at framework load.
@preconcurrency import ApplicationServices
import CandelaKit
import Foundation
import Observation

/// Tracks the Accessibility (TCC) grant the media-key event tap needs.
///
/// D9: the grant is observed for the app's whole lifetime and transitions are
/// reported in BOTH directions. It is not enough to wait for the grant and then
/// stop: an ad-hoc re-sign silently drops it (that is the normal deploy loop
/// here), and a user can revoke it in System Settings at any time — either way
/// the media keys die, and without live observation nothing in the UI says so.
///
/// Two sources, because neither alone is sufficient:
/// - Fast path: the undocumented `com.apple.accessibility.api` distributed
///   notification the fork listens to. It is not API, so it cannot be relied
///   on...
/// - ...which is why a slow poll backstops it — 2 s while the grant is missing
///   (a snappy banner-clear and tap hand-off once the user flips the switch),
///   10 s while it is held (revocation is rarer and less urgent, and this tick
///   costs a `AXIsProcessTrustedWithOptions` call).
@MainActor @Observable
final class AccessibilityPermission {
  private(set) var isGranted: Bool

  @ObservationIgnored private var pollTimer: Timer?
  @ObservationIgnored private var onChange: (@MainActor (Bool) -> Void)?
  @ObservationIgnored private var notificationObserver: (any NSObjectProtocol)?
  /// Gates `scheduleBackstop()` inside `applyGranted`: `promptIfNeeded()` can
  /// flip the grant before `startMonitoring` has ever run, and a backstop timer
  /// scheduled then would tick against a nil callback.
  @ObservationIgnored private var isMonitoring = false

  /// The fork's mechanism (`AppDelegate` line 174): undocumented, posted by the
  /// Accessibility subsystem when the trusted-process list changes.
  private static let accessibilityAPIChanged = NSNotification.Name("com.apple.accessibility.api")

  init() {
    isGranted = AXIsProcessTrustedWithOptions(nil)
  }

  /// Shows the system Accessibility prompt when the grant is missing. No
  /// NSAlert — the system prompt plus the panel banner replace the fork's
  /// modal (spec §6).
  func promptIfNeeded() {
    guard !isGranted else { return }
    // Fork precedent (MediaKeyTapManager.readPrivileges): the prompt key is
    // the unmanaged constant, not a string literal.
    let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
    // Through `applyGranted`, not a bare assignment: in the (unlikely, but not
    // impossible) case that this call observes the grant already present, the
    // transition must reach `onChange` — otherwise the tap would never start
    // and `recheck` would see no change to report, latching in the one state
    // D9 exists to prevent.
    applyGranted(AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary))
  }

  /// Observes the grant for the app's lifetime and calls `onChange` on every
  /// TRANSITION — grant *and* revocation. Never fires for steady state; the
  /// caller reads `isGranted` for that.
  ///
  /// Idempotent: a second call replaces the observer, the callback and the
  /// backstop timer rather than stacking a second set (it is reached from more
  /// than one place).
  func startMonitoring(onChange: @escaping @MainActor (Bool) -> Void) {
    if let notificationObserver {
      DistributedNotificationCenter.default().removeObserver(notificationObserver)
    }
    self.onChange = onChange
    isMonitoring = true
    notificationObserver = DistributedNotificationCenter.default().addObserver(
      forName: Self.accessibilityAPIChanged, object: nil, queue: nil
    ) { [weak self] _ in
      // TCC needs a moment to settle after the notification is posted — the
      // fork waits 100 ms before re-reading, and reading immediately can still
      // return the pre-change answer. The backstop covers us if it does.
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
    // `Timer(timeInterval:)` + an explicit `RunLoop.main.add(_:forMode: .common)`,
    // NOT `Timer.scheduledTimer`: `.common` mode is load-bearing. A menu
    // tracking session holds the run loop in event-tracking mode, so a
    // default-mode timer would stop firing exactly while the panel is open —
    // which is precisely when the banner has to appear or clear. Reviewed and
    // settled; do not "simplify" this to `scheduledTimer`.
    //
    // KNOWN TRAP: the block is `@Sendable`-typed and `MainActor.assumeIsolated`
    // *traps* rather than degrading if the timer is ever scheduled on another
    // run loop. It is added to `RunLoop.main` two lines below and nowhere else;
    // if that ever changes, this must become a `Task { @MainActor … }` hop —
    // safe here, unlike the status-item KVO guard, because nothing depends on
    // this running synchronously.
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.recheck() }
    }
    pollTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  /// Reads the live grant and reports it if it changed. Deliberately never
  /// invalidates the timer on success — the latching behavior is the defect.
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
  /// grant, so an all-custom rig is fully functional without it and Task 7
  /// deliberately refuses to prompt on that rig. The Keyboard pane's warning
  /// row (Task 12) gates on exactly this predicate, so the panel banner must
  /// use it too — otherwise the pane would say "fine" while the banner nagged.
  ///
  /// Read inside a SwiftUI `body`, this tracks `isGranted` through observation;
  /// the key-mode prefs are plain `UserDefaults` and re-render on the panel's
  /// existing `prefsRevision` touch.
  var isWarningWarranted: Bool {
    guard !isGranted else { return false }
    let prefs = DisplayPrefs(persistenceKey: "app")
    return KeyModePolicy.requiresAccessibility(
      brightness: prefs.keyboardBrightness, volume: prefs.keyboardVolume
    )
  }
}
