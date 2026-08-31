import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

// MARK: - Fakes

@MainActor
final class RecordingAlerts: EngineAlerting {
  private(set) var offers: [(displayName: String, onAccept: @MainActor () -> Void)] = []

  func offerShadeFallback(displayName: String, onAccept: @escaping @MainActor () -> Void) {
    offers.append((displayName, onAccept))
  }

  /// Stands in for the user clicking "Use Shade Dimming".
  func acceptLast() { offers.last?.onAccept() }
}

/// Hand-advanced clock for the verify throttle.
@MainActor
final class ManualClock {
  var instant = ContinuousClock.now
  func advance(_ duration: Duration) { instant = instant.advanced(by: duration) }
}

// MARK: - Harness

@MainActor
private struct Fixture {
  let gamma = RecordingGamma()
  let alerts = RecordingAlerts()
  let clock = ManualClock()
  let monitor: GammaInterferenceMonitor

  static let displayID: CGDirectDisplayID = 3
  static let displayName = "MAG341C"

  init(threshold: Int = 3) {
    monitor = GammaInterferenceMonitor(gamma: gamma, alerts: alerts, threshold: threshold)
    let clock = clock
    monitor.now = { clock.instant }
  }

  /// One check, past the throttle window so every call actually reads the table.
  func check(onSwitch: @escaping @MainActor () -> Void = {}) {
    clock.advance(.milliseconds(600))
    monitor.checkBeforeApply(
      displayID: Self.displayID,
      displayName: Self.displayName,
      onSwitchToShade: onSwitch
    )
  }
}

// MARK: - Detection

@MainActor
@Test func intactTableIsSilent() {
  let fixture = Fixture()
  fixture.gamma.intact = true
  for _ in 0 ..< 5 { fixture.check() }
  #expect(fixture.monitor.interferenceCounts.isEmpty)
  #expect(fixture.alerts.offers.isEmpty)
  #expect(!fixture.monitor.suspendedForSession)
}

@MainActor
@Test func clobberedTableCountsAndLetsTheApplyThrough() {
  let fixture = Fixture()
  fixture.gamma.intact = false
  fixture.check()
  #expect(fixture.monitor.interferenceCounts[Fixture.displayID] == 1)
  #expect(fixture.alerts.offers.isEmpty)
  // The monitor itself never writes gamma: the check sits immediately before
  // the apply it guards, so the caller's own write is the re-apply.
  #expect(fixture.gamma.appliedScales.isEmpty)
}

/// The re-apply the fork does explicitly, observed end-to-end: the hook fires,
/// the interference is counted, and the controller's own gamma write lands
/// right after — our scale is back on the table with a single write.
@MainActor
@Test func controllerReappliesScaleRightAfterTheCheck() async {
  let gamma = RecordingGamma()
  let alerts = RecordingAlerts()
  let monitor = GammaInterferenceMonitor(gamma: gamma, alerts: alerts)
  let defaults = InMemoryDefaults()
  defaults.set(true, forKey: "forceSw.gi")
  let controller = BrightnessController(
    writer: FakeDDC(readResult: nil),
    backends: BrightnessBackends(
      applierNative: NativeBrightnessApplier(displayID: 3) { _, _ in false },
      hdr: nil,
      shade: nil,
      gamma: gamma
    ),
    prefs: DisplayPrefs(defaults: defaults, persistenceKey: "gi"),
    displayID: 3,
    wireSiblings: []
  )
  controller.preGammaApplyHook = {
    monitor.checkBeforeApply(displayID: 3, displayName: "MAG341C", onSwitchToShade: {})
  }
  gamma.intact = false

  controller.setBrightness(0.5)

  #expect(monitor.interferenceCounts[3] == 1)
  #expect(gamma.events.count == 2)
  #expect(gamma.events.first == .verify(3))
  if case let .apply(scale) = gamma.events.last {
    #expect(scale == DimmingMath.swTransform(0.5, allowZero: false))
  } else {
    Issue.record("expected the controller's gamma apply right after the check")
  }
}

// MARK: - Threshold + outcomes

@MainActor
@Test func thirdClobberRaisesTheOfferExactlyOnce() {
  let fixture = Fixture()
  fixture.gamma.intact = false
  fixture.check()
  fixture.check()
  #expect(fixture.alerts.offers.isEmpty)
  fixture.check()
  #expect(fixture.alerts.offers.count == 1)
  #expect(fixture.alerts.offers.first?.displayName == Fixture.displayName)
  fixture.check()
  #expect(fixture.alerts.offers.count == 1)
}

@MainActor
@Test func perDisplayCountsPreventCrossDisplayThresholdTripping() {
  // N displays clobbering once each must not trip the threshold: the alert has to
  // name the display that actually earned it.
  let gamma = RecordingGamma()
  let alerts = RecordingAlerts()
  let monitor = GammaInterferenceMonitor(gamma: gamma, alerts: alerts, threshold: 3)
  // Defeat the 500 ms per-display verify throttle deterministically: every
  // `now()` read jumps a full second.
  nonisolated(unsafe) var tick = ContinuousClock.now
  monitor.now = {
    tick += .seconds(1)
    return tick
  }
  gamma.intact = false
  monitor.checkBeforeApply(displayID: 1, displayName: "One") {}
  monitor.checkBeforeApply(displayID: 2, displayName: "Two") {}
  monitor.checkBeforeApply(displayID: 3, displayName: "Three") {}
  #expect(alerts.offers.isEmpty) // global counter would have fired here
  #expect(monitor.interferenceCounts[1] == 1)
  monitor.checkBeforeApply(displayID: 1, displayName: "One") {}
  monitor.checkBeforeApply(displayID: 1, displayName: "One") {}
  #expect(alerts.offers.map(\.displayName) == ["One"])
}

@MainActor
@Test func acceptDoesNotReArmTheMonitor() {
  // The fork's re-arm on accept nags once per display on a multi-monitor rig, so
  // Candela keeps the session suspended after accept, same as "Not Now".
  let gamma = RecordingGamma()
  let alerts = RecordingAlerts()
  let monitor = GammaInterferenceMonitor(gamma: gamma, alerts: alerts, threshold: 1)
  gamma.intact = false
  var switched = 0
  monitor.checkBeforeApply(displayID: 1, displayName: "One") { switched += 1 }
  #expect(monitor.suspendedForSession)
  alerts.acceptLast() // user clicks "Use Shade Dimming"
  #expect(switched == 1) // the accepted display still switches to the shade
  #expect(monitor.suspendedForSession) // still suspended — no nag loop
}

@MainActor
@Test func acceptPathReconfigureSkipsTheRecapture() async {
  // At accept time the interfering app may own the table, so recapturing would bake
  // its curve in as the default and `clearSoftwareLeg` would resurface it as a tint.
  let defaults = InMemoryDefaults()
  let gamma = RecordingGamma()
  let controller = BrightnessController(
    writer: FakeDDC(readResult: nil),
    backends: BrightnessBackends(
      applierNative: NativeBrightnessApplier(displayID: 5) { _, _ in false },
      hdr: nil, shade: nil, gamma: gamma
    ),
    prefs: DisplayPrefs(defaults: defaults, persistenceKey: "rc"),
    displayID: 5,
    wireSiblings: []
  )
  await controller.handleReconfigure(recapture: false)
  #expect(gamma.recaptured.isEmpty)
  await controller.handleReconfigure() // default keeps the M3 behavior
  #expect(gamma.recaptured == [5])
}

@MainActor
@Test func declineSuspendsForTheSession() {
  let fixture = Fixture()
  fixture.gamma.intact = false
  for _ in 0 ..< 3 { fixture.check() }
  #expect(fixture.alerts.offers.count == 1)
  // Decline = the alert never calls back; suspension is set when the offer is
  // raised, so no further check does anything.
  #expect(fixture.monitor.suspendedForSession)

  let readsBefore = fixture.gamma.verifyCount
  fixture.check()

  #expect(fixture.monitor.interferenceCounts[Fixture.displayID] == 3)
  #expect(fixture.alerts.offers.count == 1)
  #expect(fixture.gamma.verifyCount == readsBefore) // not even a table read
}

@MainActor
@Test func resetCounterZeroesCountButKeepsSuspension() {
  let fixture = Fixture()
  fixture.gamma.intact = false
  for _ in 0 ..< 3 { fixture.check() }
  #expect(fixture.monitor.suspendedForSession)

  fixture.monitor.resetCounter()

  #expect(fixture.monitor.interferenceCounts.isEmpty)
  #expect(fixture.monitor.suspendedForSession)
}

// MARK: - Throttle

@MainActor
@Test func twoChecksInsideTheThrottleWindowReadTheTableOnce() {
  let fixture = Fixture()
  fixture.gamma.intact = false
  fixture.monitor.checkBeforeApply(displayID: 3, displayName: "MAG341C", onSwitchToShade: {})
  fixture.clock.advance(.milliseconds(100))
  fixture.monitor.checkBeforeApply(displayID: 3, displayName: "MAG341C", onSwitchToShade: {})

  #expect(fixture.gamma.verifyCount == 1)
  #expect(fixture.monitor.interferenceCounts[3] == 1)

  fixture.clock.advance(.milliseconds(500))
  fixture.monitor.checkBeforeApply(displayID: 3, displayName: "MAG341C", onSwitchToShade: {})

  #expect(fixture.gamma.verifyCount == 2)
  #expect(fixture.monitor.interferenceCounts[3] == 2)
}

@MainActor
@Test func throttleIsPerDisplay() {
  let fixture = Fixture()
  fixture.gamma.intact = false
  fixture.monitor.checkBeforeApply(displayID: 3, displayName: "A", onSwitchToShade: {})
  fixture.monitor.checkBeforeApply(displayID: 4, displayName: "B", onSwitchToShade: {})

  #expect(fixture.gamma.events == [.verify(3), .verify(4)])
}

@MainActor
@Test func reconfigureClearsTheThrottleSoTheNextApplyIsChecked() {
  let fixture = Fixture()
  fixture.gamma.intact = true
  fixture.monitor.checkBeforeApply(displayID: 3, displayName: "A", onSwitchToShade: {})
  fixture.monitor.resetCounter()
  fixture.monitor.checkBeforeApply(displayID: 3, displayName: "A", onSwitchToShade: {})

  #expect(fixture.gamma.verifyCount == 2)
}

// MARK: - Per-display interference count (B7)

/// An accessor rather than the dictionary: a view has no business iterating displays
/// it does not own. One global count let N displays trip the threshold on the first
/// real event, with the alert naming whichever came third.
@MainActor
@Test func interferenceIsCountedPerDisplayAndReadableForOne() {
  // Threshold far above anything this test reaches: the offer would suspend
  // the monitor for the session and stop the counting we are measuring.
  let fixture = Fixture(threshold: 99)
  fixture.gamma.intact = false

  #expect(fixture.monitor.interferenceCount(for: Fixture.displayID) == 0)
  fixture.monitor.checkBeforeApply(
    displayID: Fixture.displayID, displayName: Fixture.displayName, onSwitchToShade: {}
  )
  #expect(fixture.monitor.interferenceCount(for: Fixture.displayID) == 1)
  // The display nobody clobbered reads zero, not the neighbour's count.
  #expect(fixture.monitor.interferenceCount(for: 4) == 0)
}

/// A display that has never been checked is a legitimate query — the pane asks
/// about every display it lists, including the ones with no gamma leg at all.
/// Zero, not a crash and not a nil the caller has to re-interpret.
@MainActor
@Test func interferenceCountForAnUnknownDisplayIsZero() {
  let fixture = Fixture()
  #expect(fixture.monitor.interferenceCount(for: 999) == 0)
}
