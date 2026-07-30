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

  func recaptureDefaultTable(on _: CGDirectDisplayID) {}
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
  #expect(fixture.monitor.interferenceCount == 0)
  #expect(fixture.alerts.offers.isEmpty)
  #expect(!fixture.monitor.suspendedForSession)
}

@MainActor
@Test func clobberedTableCountsAndLetsTheApplyThrough() {
  let fixture = Fixture()
  fixture.gamma.intact = false
  fixture.check()
  #expect(fixture.monitor.interferenceCount == 1)
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
  let defaults = UserDefaults(suiteName: "com.rydersel.Candela.tests.gamma-interference")!
  defaults.set(true, forKey: "forceSw.gi")
  defer { defaults.removePersistentDomain(forName: "com.rydersel.Candela.tests.gamma-interference") }
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

  #expect(monitor.interferenceCount == 1)
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
@Test func acceptSwitchesToShadeAndRearms() {
  let fixture = Fixture()
  var switched = 0
  fixture.gamma.intact = false
  for _ in 0 ..< 3 { fixture.check { switched += 1 } }
  #expect(fixture.alerts.offers.count == 1)

  fixture.alerts.acceptLast()

  #expect(switched == 1)
  #expect(fixture.monitor.interferenceCount == 0)
  // Checking re-arms (fork parity) — avoidGamma now keeps this display off the
  // gamma path anyway, so the hook simply stops firing for it.
  #expect(!fixture.monitor.suspendedForSession)
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

  #expect(fixture.monitor.interferenceCount == 3)
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

  #expect(fixture.monitor.interferenceCount == 0)
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
  #expect(fixture.monitor.interferenceCount == 1)

  fixture.clock.advance(.milliseconds(500))
  fixture.monitor.checkBeforeApply(displayID: 3, displayName: "MAG341C", onSwitchToShade: {})

  #expect(fixture.gamma.verifyCount == 2)
  #expect(fixture.monitor.interferenceCount == 2)
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
