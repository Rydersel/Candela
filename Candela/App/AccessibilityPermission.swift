import AppKit
// @preconcurrency: `kAXTrustedCheckOptionPrompt` is a mutable C global that
// Swift 6 refuses to reference. It is set once at framework load.
@preconcurrency import ApplicationServices
import CandelaKit
import Foundation
import Observation

/// Tracks the Accessibility (TCC) grant the media-key event tap needs.
///
/// Observed for the app's whole lifetime, reporting transitions in BOTH
/// directions. Waiting for the grant once is not enough: a re-sign drops it
/// silently and the user can revoke it in System Settings. Either way the media
/// keys die and nothing in the UI would say so.
///
/// The undocumented `com.apple.accessibility.api` distributed notification is
/// the fast path; a poll backstops it when that notification is missed or lands
/// before TCC has settled. `AccessibilityBackstopPolicy` owns the cadence.
@MainActor @Observable
final class AccessibilityPermission {
  private(set) var isGranted: Bool

  @ObservationIgnored private var pollTimer: Timer?
  /// Cadence `pollTimer` was armed at, so a tick can tell whether it still applies.
  /// nil means no timer.
  @ObservationIgnored private var scheduledInterval: TimeInterval?
  /// Uptime, not wall clock: a clock change must not shorten or extend the hunt.
  @ObservationIgnored private var missingSince: TimeInterval?
  @ObservationIgnored private var lastNotification: TimeInterval?
  @ObservationIgnored private var onChange: (@MainActor (Bool) -> Void)?
  @ObservationIgnored private var notificationObserver: (any NSObjectProtocol)?
  /// Gates `scheduleBackstop()`: `promptIfNeeded()` can flip the grant before
  /// `startMonitoring` runs, and a timer scheduled then ticks on a nil callback.
  @ObservationIgnored private var isMonitoring = false

  /// Undocumented; the Accessibility subsystem posts it when the trusted-process
  /// list changes.
  private static let accessibilityAPIChanged = NSNotification.Name("com.apple.accessibility.api")

  init() {
    let granted = AXIsProcessTrustedWithOptions(nil)
    isGranted = granted
    // A launch with no grant starts the hunt at launch.
    missingSince = granted ? nil : ProcessInfo.processInfo.systemUptime
  }

  /// Shows the system Accessibility prompt when the grant is missing. No NSAlert:
  /// the system prompt plus the panel banner replace the fork's modal.
  func promptIfNeeded() {
    guard !isGranted else { return }
    // Deliberately the unmanaged constant, not a string literal.
    let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
    let granted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
    // Only where the prompt actually went up. A false answer IS the prompt being
    // shown, and its button opens the Accessibility list; a true answer showed
    // nothing and sent nobody anywhere, so the clock has no reason to move (and
    // `applyGranted` clears it below in any case).
    if !granted { reevaluateBackstop(after: .sentToSystemSettings) }
    // Through `applyGranted`, not a bare assignment: if this call observes the
    // grant already present, the transition still has to reach `onChange` or the
    // tap never starts and `recheck` sees no change to report.
    applyGranted(granted)
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
      // pre-change answer. The backstop covers that, so the hunt reopens before the read.
      Task { @MainActor in
        self?.noteNotification()
        try? await Task.sleep(for: .milliseconds(100))
        self?.recheck()
      }
    }
    scheduleBackstop()
  }

  /// Opens the Accessibility list, and reopens the hunt on the way: this is the
  /// route to the grant, so the backstop has to be at the hunting cadence when the
  /// user comes back rather than resting at thirty seconds.
  func openSystemSettings() {
    reevaluateBackstop(after: .sentToSystemSettings)
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    )
  }

  /// The tap was re-armed. Every pref carrying the re-arm reaches here, most of them
  /// nothing to do with keys (a DDC availability switch, an audio-routing override),
  /// and so does the settings reset, which is the route that leaves an all-custom rig
  /// wanting the tap with no timer running.
  func noteTapRearmed() {
    reevaluateBackstop(after: .tapRearmed)
  }

  /// A key mode was written. Called in both directions: nothing else stands the timer
  /// down when the last key family goes off, or re-arms it when one comes back.
  func noteKeyModesChanged() {
    reevaluateBackstop(after: .keyModesWritten)
  }

  /// Both doors take this path with the same state; the EDGE is the whole difference,
  /// and the policy is what turns it into "reopen the hunt clock" or "leave it".
  private func reevaluateBackstop(after edge: AccessibilityBackstopPolicy.Edge) {
    guard isMonitoring else { return }
    if AccessibilityBackstopPolicy.reopensHunt(
      edge: edge,
      granted: isGranted,
      // Read live, like the cadence below: the settings reset restores key-mode
      // defaults without coming back through a caller that could report them.
      requiresAccessibility: Self.storedModesRequireGrant()
    ) {
      missingSince = ProcessInfo.processInfo.systemUptime
    }
    scheduleBackstop()
  }

  private func noteNotification() {
    lastNotification = ProcessInfo.processInfo.systemUptime
    guard isMonitoring else { return }
    scheduleBackstop()
  }

  private func desiredInterval() -> TimeInterval? {
    let now = ProcessInfo.processInfo.systemUptime
    return AccessibilityBackstopPolicy.interval(
      granted: isGranted,
      // Read live: the settings reset restores key-mode defaults without coming back here.
      requiresAccessibility: Self.storedModesRequireGrant(),
      secondsSinceMissingBegan: missingSince.map { now - $0 } ?? 0,
      secondsSinceNotification: lastNotification.map { now - $0 }
    )
  }

  /// (Re)arms the backstop poll at the cadence the current state calls for, or
  /// stands it down entirely.
  private func scheduleBackstop() {
    pollTimer?.invalidate()
    pollTimer = nil
    scheduledInterval = desiredInterval()
    guard let interval = scheduledInterval else {
      // No key routes through the tap, so nothing reads the grant but the diagnostics
      // report, whose line may lag until the next notification or mode write.
      return
    }
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

  /// Never stops polling on success; latching is the defect this tracking exists
  /// to prevent.
  private func recheck() {
    applyGranted(AXIsProcessTrustedWithOptions(nil))
    // Both windows expire between ticks and `applyGranted` reschedules only on a
    // transition, so the cadence is re-derived here every tick.
    if isMonitoring, desiredInterval() != scheduledInterval {
      scheduleBackstop()
    }
  }

  private func applyGranted(_ granted: Bool) {
    guard granted != isGranted else { return }
    isGranted = granted
    missingSince = granted ? nil : ProcessInfo.processInfo.systemUptime
    if isMonitoring {
      scheduleBackstop()
    }
    onChange?(granted)
  }
}

extension AccessibilityPermission {
  /// The stored key modes' answer to whether the CGEvent tap is wanted at all.
  static func storedModesRequireGrant() -> Bool {
    let prefs = DisplayPrefs(persistenceKey: "app")
    return KeyModePolicy.requiresAccessibility(
      brightness: prefs.keyboardBrightness, volume: prefs.keyboardVolume
    )
  }

  /// Whether a missing grant is worth telling the user about right now.
  ///
  /// Not simply `!isGranted`: custom shortcuts are Carbon hotkeys and need no
  /// grant, so an all-custom rig works without it and must not be nagged. The
  /// Keyboard pane's warning row gates on this same predicate, so the panel
  /// banner has to as well.
  var isWarningWarranted: Bool {
    guard !isGranted else { return false }
    return Self.storedModesRequireGrant()
  }
}
