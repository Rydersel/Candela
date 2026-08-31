import CoreGraphics
import os

/// Watches for another app rewriting a display's gamma table under us (f.lux,
/// Night Shift and friends all own the same global resource) and, once it keeps
/// happening, offers to move that display to the shade instead.
///
/// Narrower than the fork by design: the fork checks on every brightness set,
/// Candela only when the gamma backend is about to write. Above the combined
/// switching point no scale of ours is installed, so there is nothing to fight
/// over. `BrightnessController.preGammaApplyHook` is that moment.
@MainActor
public final class GammaInterferenceMonitor {
  /// `verifyTableIntact` is a `CGGetDisplayTransferByTable` round trip; a 60 Hz
  /// drag must not pay one per tick.
  static let verifyThrottle: Duration = .milliseconds(500)

  private let gamma: any GammaApplying
  private let alerts: any EngineAlerting
  private let threshold: Int
  private let log = Logger(subsystem: "com.rydersel.Candela", category: "gamma")

  /// The "Not Now" outcome, set when the offer is RAISED rather than when it is
  /// declined. Declining is the absence of a callback, so suspending up front is
  /// what makes a decline stick, and it also keeps a second offer from being
  /// raised while one is still on screen.
  public private(set) var suspendedForSession = false

  /// Clobber events per display this session. One global count let N displays
  /// trip the threshold on the FIRST real event, and the alert then named
  /// whichever display came third. Internal: the offer is the public signal and
  /// `interferenceCount(for:)` reads one entry.
  private(set) var interferenceCounts: [CGDirectDisplayID: Int] = [:]

  /// How many times another app has taken THIS display's color profile back
  /// this session (B7), so the pane can say why the offer appeared, or that a
  /// fight is going on below the threshold.
  ///
  /// An accessor rather than a public dictionary: a display nobody clobbered
  /// reads zero instead of a nil every caller re-interprets.
  ///
  /// This type is not `@Observable`, so a row reading it refreshes on the pane's
  /// existing invalidation, not the instant a clobber is detected. A live badge
  /// would mean making the monitor observable.
  public func interferenceCount(for displayID: CGDirectDisplayID) -> Int {
    interferenceCounts[displayID, default: 0]
  }

  private var lastVerified: [CGDirectDisplayID: ContinuousClock.Instant] = [:]

  /// Test seam for the throttle window.
  var now: @MainActor () -> ContinuousClock.Instant = { .now }

  public init(gamma: any GammaApplying, alerts: any EngineAlerting, threshold: Int = 3) {
    self.gamma = gamma
    self.alerts = alerts
    self.threshold = threshold
  }

  /// Call immediately before a gamma-path software apply.
  ///
  /// No re-apply here, unlike the fork, which resets its scale to 1 and lets the
  /// NEXT brightness set restore it. This runs one statement before the apply it
  /// guards, so the caller's own write is the re-apply: one write instead of
  /// two, and no flash to full brightness in between.
  public func checkBeforeApply(
    displayID: CGDirectDisplayID,
    displayName: String,
    onSwitchToShade: @escaping @MainActor () -> Void
  ) {
    guard !suspendedForSession else { return }
    let instant = now()
    if let last = lastVerified[displayID], last.duration(to: instant) < Self.verifyThrottle {
      return
    }
    lastVerified[displayID] = instant
    guard !gamma.verifyTableIntact(on: displayID) else { return }

    interferenceCounts[displayID, default: 0] += 1
    let count = interferenceCounts[displayID, default: 0]
    log.info("Gamma table interference on display \(displayID, privacy: .public), event \(count)")
    guard count >= threshold else { return }

    suspendedForSession = true
    // No re-arm on accept, a divergence from the fork: re-arming nags once per
    // display on a multi-external rig. Suspended lasts until relaunch, exactly
    // like "Not Now"; the accepted display dims through the shade either way.
    alerts.offerShadeFallback(displayName: displayName) {
      onSwitchToShade()
    }
  }

  /// Reconfiguration intake: the fork zeroes its counter on every configure,
  /// so a long session doesn't accumulate unrelated events into an offer.
  /// `suspendedForSession` survives — "Not Now" lasts until relaunch.
  public func resetCounter() {
    interferenceCounts.removeAll()
    // The tables were reset and re-captured around this event; the next apply
    // deserves a fresh look rather than waiting out a stale throttle window.
    lastVerified.removeAll()
  }
}
