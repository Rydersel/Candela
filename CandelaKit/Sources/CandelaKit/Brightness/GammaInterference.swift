import CoreGraphics
import os

/// Watches for another app rewriting a display's gamma table under us (f.lux,
/// Night Shift and friends all own the same global resource) and, once it keeps
/// happening, offers to move that display to the shade instead.
///
/// Narrower than the fork by design (plan scope decision 11): the fork checks
/// on every brightness set, Candela only when the gamma backend is actually
/// about to write — above the combined switching point no scale of ours is
/// installed, so there is nothing to fight over and nothing to nag about.
/// `BrightnessController.preGammaApplyHook` is exactly that moment.
@MainActor
public final class GammaInterferenceMonitor {
  /// `verifyTableIntact` is a `CGGetDisplayTransferByTable` round trip; a 60 Hz
  /// drag must not pay one per tick.
  static let verifyThrottle: Duration = .milliseconds(500)

  private let gamma: any GammaApplying
  private let alerts: any EngineAlerting
  private let threshold: Int
  private let log = Logger(subsystem: "com.rydersel.Candela", category: "gamma")

  /// The "Not Now" outcome. Set when the offer is *raised*, not when it is
  /// declined — fork parity with `gammaInterferenceWarningShown`, which the
  /// fork also sets before running its modal. Declining is the absence of a
  /// callback, so suspending up front is what makes a decline stick; it also
  /// keeps a second offer from being raised while one is still on screen
  /// (Candela presents asynchronously, so that window is real).
  public private(set) var suspendedForSession = false

  /// Clobber events per display this session (backlog #5a: one global count
  /// let N displays trip the threshold on the FIRST real event, and the alert
  /// named whichever display came third). Internal: the offer is the public
  /// signal, the counts are a test seam.
  private(set) var interferenceCounts: [CGDirectDisplayID: Int] = [:]

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
  /// No re-apply happens here, unlike the fork (which resets its scale to 1 and
  /// lets the *next* brightness set restore it): this runs one statement before
  /// the apply it guards, so the caller's own write is the re-apply — same end
  /// state, one write instead of two, no flash to full brightness in between.
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
    // No re-arm on accept (backlog #5b, divergence from the fork): re-arming
    // nags up to once per display on 3+-external rigs. Suspended lasts until
    // relaunch, exactly like "Not Now" — the accepted display dims through
    // the shade either way.
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
