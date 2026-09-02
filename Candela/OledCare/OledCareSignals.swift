import AppKit
import CoreGraphics
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// The system readings `OledCareCoordinator` turns into `OledDimSignals`. All
/// of it is app-target: the engine takes abstract signals so it stays testable,
/// and every platform call that produces one lives here.
///
/// The isolation is deliberately split. Every reading ahead of the cache is
/// nonisolated: the platform calls are thread-safe and none touches stored
/// state, so the two on the 10 Hz tick path must not be forced through a
/// main-actor hop [MEASURED 2026-08-06: sub-microsecond and 0.07 ms per call].
/// Only `displaySleepMinutes()` is `@MainActor`, because it owns a cache, and it
/// costs 1000x the tick reads.
enum OledCareSignalSources {
  /// Seconds since the last user input, system-wide.
  ///
  /// `kCGAnyInputEventType` is `~0` and the Swift overlay has no constant for it;
  /// `~0` collides with `.tapDisabledByUserInput`, so the raw value is the only
  /// honest spelling. [MEASURED 2026-08-06: `CGEventType(rawValue: ~0)` resolves
  /// and the call returns a live idle count.]
  ///
  /// Counts through system sleep. `IdleDimmingEngine` holds the wake floor that
  /// corrects for it, so this stays a raw reading.
  ///
  /// If it ever stuck at 0: nothing dims, and since the engine detects input as
  /// a FALLING idle count, the input-lift of a lock overlay goes with it. The
  /// unlock notification is then the only recovery, which is why lock dim does
  /// not depend on this reading alone.
  static func systemIdleSeconds() -> Double {
    // 0 reads as "just used", so a raw value that ever stopped resolving costs
    // the dim, not a dim nobody can clear.
    guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
  }

  /// True while anything system-wide holds `PreventUserIdleDisplaySleep`: video,
  /// calls, presentations, caffeinate, and Candela's own Keep Display
  /// Awake. Ours is deliberately NOT excluded: a control that promises to keep
  /// the display awake should not leave it dimmed.
  ///
  /// The status dictionary reports an aggregate LEVEL, not a count, so our own
  /// hold cannot be subtracted out while a video holds one too.
  /// `kIOPMAssertionLevelOff` is 0 and anything above it means held (observed as
  /// 1, not the 255 the constant suggests), hence `> 0`.
  static func displaySleepAssertionHeld() -> Bool {
    var assertions: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsStatus(&assertions) == kIOReturnSuccess,
          let dict = assertions?.takeRetainedValue() as? [String: Int] else { return false }
    return (dict[kIOPMAssertionTypePreventUserIdleDisplaySleep as String] ?? 0) > 0
  }

  /// The low-battery sampling skip's threshold. 20% is where macOS itself starts
  /// warning, and the cost of being wrong either way is one minute of sampling.
  private static let lowBatteryPercent: Double = 20

  /// True while a battery power source is at or below `lowBatteryPercent` AND
  /// actually running on battery.
  ///
  /// Deliberately NOT `ProcessInfo.isLowPowerModeEnabled`: Low Power Mode is a
  /// user preference that can be on at 100% charge, and the condition here is the
  /// charge itself. Read at the 60 s decision point only, never on the 10 Hz
  /// tick, where an IOKit power-source copy is the loop's most expensive call.
  static func onLowBattery() -> Bool {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return false }
    for source in sources {
      guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
        as? [String: Any]
      else { continue }
      // On mains power the charge level is irrelevant: the panel is not being
      // sampled to save a battery that is filling.
      guard description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue else {
        continue
      }
      guard let current = description[kIOPSCurrentCapacityKey] as? Double,
        let capacity = description[kIOPSMaxCapacityKey] as? Double, capacity > 0
      else { continue }
      if current / capacity * 100 <= lowBatteryPercent { return true }
    }
    return false
  }

  @MainActor private static var cachedDisplaySleep: (minutes: Int?, at: ContinuousClock.Instant)?

  /// The system `displaysleep` setting in minutes (0 = never), for the pane's
  /// "your dim never fires" warning. Read via `pmset -g`, since no public API
  /// reports it.
  ///
  /// **79 ms process spawn** [MEASURED 2026-08-06], on the main actor. Call it
  /// once per pane appearance, NEVER from a timer: the 60 s cache is a backstop
  /// against a re-render loop, not a licence to poll.
  @MainActor
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
      // Drain BEFORE waiting: a child that fills the pipe buffer blocks on write
      // while we block on its exit. `pmset -g` is far under 64 KB today.
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

/// PRIVATE API: the screen-lock distributed notifications are undocumented. If
/// they stop arriving on a future macOS, `isLocked` stays false forever and lock
/// dim silently never engages. Nothing crashes, and no other dimming row depends
/// on this observer.
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

  isolated deinit {
    // `isolated` so this can call `stop()` at all: a nonisolated deinit cannot
    // touch the non-Sendable token array on a `@MainActor` class. The blocks
    // capture `self` weakly, so this is tidiness rather than a leak fix.
    stop()
  }
}

/// Resolves which display holds the frontmost app's front window, for
/// unfocused-display dim. `CGWindowListCopyWindowInfo` needs no grant.
///
/// **Contract the coordinator depends on:** a display that gains focus must be
/// reported on the very next sample. The caller derives `unfocusedSeconds` by
/// timestamping these transitions, a focus visit RESETS that clock, and only
/// focus arrival exits `unfocusedDim`. A missed visit is a display that stays
/// dimmed while the user works on it, so this resolves live on every call.
///
/// **Sampling cadence is part of that contract.** At a 5 s poll, a display the
/// user clicks stays dimmed for up to 5 s, which is visibly unusable, so the
/// consumer MUST sample at the overlay-up cadence (0.1 s) for as long as an
/// `unfocusedDim` overlay is up. [MEASURED 2026-08-06: 0.46 ms per call over
/// 200 calls with 24 windows on screen, 0.71 ms on a busier desktop] That is
/// under 1% of a core at 10 Hz.
///
/// **It holds the last resolution** rather than reporting `nil` on a transient
/// miss: Spotlight, a Dock-activated app with no window open yet, and an app
/// whose windows are on another Space all fail the live resolution for a tick or
/// two. `nil` means only "no display resolved yet", before the first sample.
@MainActor
final class FocusSampler {
  private var lastResolved: CGDirectDisplayID?

  /// Forgets the held resolution. The coordinator calls this on every display
  /// reconfiguration, and the reason is ID REASSIGNMENT, not departure: display
  /// IDs reassign across a replug with both panels still present (measured: MAG
  /// 3 to 2, Dell 2 to 3 across one dock cycle), so a held ID can come to name a
  /// DIFFERENT physical panel, and a liveness check cannot catch it. Until the
  /// next `resolve()` re-seeds, `focusedDisplayID()` returns nil, which consumers
  /// must read as "no data" and never as "no display focused".
  func invalidate() {
    self.lastResolved = nil
  }

  func focusedDisplayID() -> CGDirectDisplayID? {
    if let resolved = self.resolve() {
      self.lastResolved = resolved
      return resolved
    }
    return self.lastResolved
  }

  private func resolve() -> CGDirectDisplayID? {
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
      // space (origin top-left of the main display, y down). Do NOT flip them
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
