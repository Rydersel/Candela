import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// The system readings `OledCareCoordinator` turns into `OledDimSignals`. All
/// of it is app-target: the engine takes abstract signals so it stays testable,
/// and every platform call that produces one lives here.
@MainActor
enum OledCareSignalSources {
  /// Seconds since the last user input, system-wide.
  ///
  /// `kCGAnyInputEventType` is `~0` and the Swift overlay has no constant for
  /// it; `~0` collides with `.tapDisabledByUserInput`, so the raw value is the
  /// only honest spelling. [MEASURED 2026-08-06: `CGEventType(rawValue: ~0)`
  /// resolves, and the call returns a live idle count.]
  ///
  /// Counts through system sleep — `IdleDimmingEngine` holds the wake floor
  /// that corrects for it, deliberately, so this stays a raw reading.
  static func systemIdleSeconds() -> Double {
    // 0 reads as "just used", so a raw value that ever stopped resolving costs
    // the dim, not a dim nobody can clear.
    guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
  }

  /// True while anything system-wide holds `PreventUserIdleDisplaySleep` —
  /// video, calls, presentations, caffeinate. Candela itself holds none
  /// (OC14), so there is nothing to self-exclude.
  ///
  /// The status dictionary reports an aggregate LEVEL, not a count:
  /// `kIOPMAssertionLevelOff` is 0 and anything above it means held (observed
  /// as 1, not the 255 the constant suggests), hence `> 0` rather than a
  /// comparison against `kIOPMAssertionLevelOn`.
  static func displaySleepAssertionHeld() -> Bool {
    var assertions: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsStatus(&assertions) == kIOReturnSuccess,
          let dict = assertions?.takeRetainedValue() as? [String: Int] else { return false }
    return (dict[kIOPMAssertionTypePreventUserIdleDisplaySleep as String] ?? 0) > 0
  }

  private static var cachedDisplaySleep: (minutes: Int?, at: ContinuousClock.Instant)?

  /// The system `displaysleep` setting in minutes (0 = never), for the pane's
  /// "your dim never fires" warning. Read via `pmset -g` — no public API
  /// reports it — and cached for 60 s because this spawns a process.
  static func displaySleepMinutes() -> Int? {
    if let cached = cachedDisplaySleep, cached.at.duration(to: .now) < .seconds(60) {
      return cached.minutes
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g"]
    let pipe = Pipe()
    process.standardOutput = pipe
    var minutes: Int?
    if (try? process.run()) != nil {
      // Drain BEFORE waiting: a child that fills the pipe buffer blocks on
      // write while we block on its exit. `pmset -g` is far under 64 KB today,
      // and the deadlock would only ever appear on some future machine.
      let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      process.waitUntilExit()
      for line in output.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "displaysleep" { minutes = Int(parts[1]) }
      }
    }
    // The failure is cached too: a pmset that cannot run will not start working
    // within the next 60 s, and re-spawning per poll would be worse than nil.
    cachedDisplaySleep = (minutes, .now)
    return minutes
  }
}

/// PRIVATE API: the screen-lock distributed notifications are undocumented.
/// Degradation per spec §3: if they stop arriving on a future macOS, `isLocked`
/// stays false forever and lock dim silently never engages — nothing crashes,
/// and no other dimming row depends on this observer. The W3a tracking issue
/// carries the `private-api` label for it.
@MainActor
final class LockStateObserver {
  private(set) var isLocked = false
  var onLock: () -> Void = {}
  var onUnlock: () -> Void = {}
  private var tokens: [any NSObjectProtocol] = []

  /// Idempotent: a second `start()` without a `stop()` would register a second
  /// pair of observers, and every lock would then fire `onLock` twice.
  func start() {
    guard tokens.isEmpty else { return }
    let center = DistributedNotificationCenter.default()
    tokens.append(center.addObserver(
      forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { [weak self] _ in
      // `queue: .main` guarantees the main *thread*; assumeIsolated asserts the
      // isolation the compiler cannot infer through a @Sendable block.
      MainActor.assumeIsolated {
        self?.isLocked = true
        self?.onLock()
      }
    })
    tokens.append(center.addObserver(
      forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.isLocked = false
        self?.onUnlock()
      }
    })
  }

  func stop() {
    let center = DistributedNotificationCenter.default()
    for token in tokens { center.removeObserver(token) }
    tokens.removeAll()
  }
}

/// Resolves which display holds the frontmost app's front window, for
/// unfocused-display dim. `CGWindowListCopyWindowInfo` needs no grant
/// (CLAUDE.md's screenshot rule relies on the same fact).
///
/// **Contract the coordinator depends on:** a display that gains focus must be
/// reported on the very next sample, because the caller derives
/// `unfocusedSeconds` by timestamping the transitions this returns — a focus
/// visit RESETS that clock, and a missed visit is a display that stays dimmed
/// while the user works on it. Spec §3 row 5 is explicit that only focus
/// arrival exits `unfocusedDim`; global input does not. So this samples live
/// state every call and caches nothing.
///
/// `nil` means "could not be determined" and the caller must treat it as
/// everything-focused rather than nothing-focused — the failure mode of a
/// wrong guess here is a dimmed display the user is looking at.
@MainActor
final class FocusSampler {
  func focusedDisplayID() -> CGDirectDisplayID? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
      as? [[String: Any]] else { return nil }
    // Front-to-back order, so the frontmost app's first normal-level window is
    // the one it would key. Layer 0 filters out its panels, menus and HUDs.
    for info in windows {
      guard info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
            (info[kCGWindowLayer as String] as? Int) == 0,
            let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
      // Both these bounds and `CGGetDisplaysWithPoint` speak the global display
      // space (origin top-left of the main display, y down) — do NOT flip them
      // into AppKit's coordinates on the way through.
      let midpoint = CGPoint(x: boundsDict["X", default: 0] + boundsDict["Width", default: 0] / 2,
                             y: boundsDict["Y", default: 0] + boundsDict["Height", default: 0] / 2)
      var display: CGDirectDisplayID = 0
      var count: UInt32 = 0
      if CGGetDisplaysWithPoint(midpoint, 1, &display, &count) == .success, count > 0 {
        return display
      }
    }
    return nil
  }
}
