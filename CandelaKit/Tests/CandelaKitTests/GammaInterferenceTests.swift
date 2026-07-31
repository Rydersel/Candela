import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

// MARK: - Fakes

/// Gamma backend with a settable intactness verdict, recording every call in
/// order (the re-apply assertion is about ordering: the check runs *before*
/// the apply it guards).
@MainActor
final class FakeInterferenceGamma: GammaApplying {
  enum Event: Equatable {
    case verify(CGDirectDisplayID)
    case apply(Double)
  }

  var intact = true
  private(set) var events: [Event] = []
  /// Displays whose baseline table was re-captured, in order — the accept
  /// path's recapture skip is an absence assertion, so it needs a record.
  private(set) var recaptured: [CGDirectDisplayID] = []

  var verifyCount: Int { events.filter { if case .verify = $0 { return true }; return false }.count }
  var appliedScales: [Double] {
    events.compactMap { if case let .apply(scale) = $0 { return scale }; return nil }
  }

  @discardableResult
  func applyGammaScale(_ scale: Double, on _: CGDirectDisplayID) -> Bool {
    events.append(.apply(scale))
    return true
  }

  func verifyTableIntact(on displayID: CGDirectDisplayID) -> Bool {
    events.append(.verify(displayID))
    return intact
  }

  func recaptureDefaultTable(on displayID: CGDirectDisplayID) { recaptured.append(displayID) }
  func resetAllGamma() {}
}

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
  let gamma = FakeInterferenceGamma()
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
  let gamma = FakeInterferenceGamma()
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
    displayID: 3
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
    #expect(scale == DimmingMath.swTransform(0.5, allowZero: false, reverse: false))
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
  // Backlog #5a: N displays clobbering once each must NOT trip threshold 3 —
  // the alert must name the display that actually earned it.
  let gamma = FakeInterferenceGamma()
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
  // Backlog #5b: the fork-parity re-arm nags once per display on 3+ rigs.
  // Candela keeps the session suspended after accept, same as "Not Now".
  // SUPERSEDES the deleted `acceptSwitchesToShadeAndRearms` (which pinned
  // the fork's reset-and-re-arm accept); its switch-to-shade assertion is
  // folded in here.
  let gamma = FakeInterferenceGamma()
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
  // progress.md:51 poisoned-baseline amendment: at accept time the
  // interfering app may own the table — recapturing would bake its curve in
  // as the "default" and clearSoftwareLeg would later resurface it as a tint.
  let defaults = InMemoryDefaults()
  let gamma = FakeInterferenceGamma()
  let controller = BrightnessController(
    writer: FakeDDC(readResult: nil),
    backends: BrightnessBackends(
      applierNative: NativeBrightnessApplier(displayID: 5) { _, _ in false },
      hdr: nil, shade: nil, gamma: gamma
    ),
    prefs: DisplayPrefs(defaults: defaults, persistenceKey: "rc"),
    displayID: 5
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
