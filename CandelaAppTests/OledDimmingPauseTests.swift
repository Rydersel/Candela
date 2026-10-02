import CandelaKit
import CoreGraphics
import Foundation
import Testing

@Suite("Timed OLED dimming pause") @MainActor
struct OledDimmingPauseTests {
  private final class TimeSource {
    var now = Date(timeIntervalSince1970: 1_000)
  }

  private func state() -> OledCareCoordinator.PerDisplay {
    OledCareCoordinator.PerDisplay(
      engine: IdleDimmingEngine(config: OledDimConfig(
        idleDimSeconds: 300, idleDimBrightness: 0.5, lockDim: true,
        blackoutEnabled: true, blackoutSeconds: 900, unfocusedDimEnabled: true,
        unfocusedDimSeconds: 300, unfocusedDimBrightness: 0.5)),
      unfocusedDimEnabled: true, hoursTracking: true, telemetryEnabled: true,
      windowObservationEnabled: true, detectionDimmingEnabled: true)
  }

  private func signals(idle: Double = 2_000, locked: Bool = false,
                       mirrored: Bool = false, field: Bool = false,
                       unfocused: Double? = nil) -> OledDimSignals {
    OledDimSignals(idleSeconds: idle, assertionHeld: false, isLocked: locked,
      isMirrored: mirrored, isHDRSettling: false, unfocusedSeconds: unfocused,
      isCheckupFieldShowing: field)
  }

  @Test func customPauseKeepsExactDeadlineAndOtherDisplaysIndependent() {
    let clock = TimeSource()
    let care = OledCareCoordinator(now: { clock.now })
    care.pauseDimming(for: "other", duration: 900)
    #expect(care.pauseDimming(for: "panel", until: Date(timeIntervalSince1970: 1_123)))
    #expect(care.dimmingPauseDeadline(for: "panel") == Date(timeIntervalSince1970: 1_123))
    #expect(care.dimmingPauseDeadline(for: "other") == Date(timeIntervalSince1970: 1_900))
    clock.now = Date(timeIntervalSince1970: 1_123)
    #expect(care.dimmingPauseDeadline(for: "panel") == nil)
    #expect(care.dimmingPauseDeadline(for: "other") != nil)
  }

  @Test func expiredCustomPauseCannotReplaceExistingPauseOrBypassReset() {
    let clock = TimeSource()
    let care = OledCareCoordinator(now: { clock.now })
    care.pauseDimming(for: "panel", duration: 900)
    for date in [clock.now, clock.now.addingTimeInterval(-1), Date.distantFuture] {
      #expect(!care.pauseDimming(for: "panel", until: date))
      #expect(care.dimmingPauseDeadline(for: "panel") == Date(timeIntervalSince1970: 1_900))
    }
    care.prepareForReset()
    #expect(!care.pauseDimming(for: "panel", until: clock.now.addingTimeInterval(60)))
    #expect(care.dimmingPauseDeadline(for: "panel") == nil)
  }

  @Test func deadlinesAreIndependentReplaceableAndSessionOnly() {
    let clock = TimeSource()
    let coordinator = OledCareCoordinator(now: { clock.now })
    coordinator.pauseDimming(for: "one", duration: 900)
    coordinator.pauseDimming(for: "two", duration: 3_600)
    #expect(coordinator.dimmingPauseDeadline(for: "one") == Date(timeIntervalSince1970: 1_900))
    #expect(coordinator.dimmingPauseDeadline(for: "two") == Date(timeIntervalSince1970: 4_600))
    clock.now = Date(timeIntervalSince1970: 1_100)
    coordinator.pauseDimming(for: "one", duration: 3_600)
    clock.now = Date(timeIntervalSince1970: 1_900)
    #expect(coordinator.dimmingPauseDeadline(for: "one") == Date(timeIntervalSince1970: 4_700))
    coordinator.resumeDimming(for: "two")
    #expect(coordinator.dimmingPauseDeadline(for: "two") == nil)
    #expect(coordinator.dimmingPauseDeadline(for: "one") != nil)
    #expect(OledCareCoordinator().dimmingPauseDeadline(for: "one") == nil)
    clock.now = Date(timeIntervalSince1970: 4_700)
    #expect(coordinator.dimmingPauseDeadline(for: "one") == nil)
  }

  @Test func pauseRemovesBlackoutAndRegionalEvidenceButKeepsMeasurementEligible() {
    let coordinator = OledCareCoordinator(windowList: { _ in [] }, lowBattery: { false })
    var display = state()
    #expect(coordinator.updateDimming(for: "panel", state: &display, signals: signals()) == .blackout)
    coordinator.pauseDimming(for: "panel", duration: 900)
    display.nominatedMask = .uniform(0.7)
    display.unfocusedSince = .now - .seconds(2_000)
    let dim = coordinator.updateDimming(for: "panel", state: &display, signals: signals())
    #expect(dim == .active)
    #expect(display.nominatedMask == nil)
    #expect(display.unfocusedSince == nil)
    #expect(OledCareCoordinator.effectiveLevel(state: dim, engine: display.engine, brightness: 0.8) == 0.8)
    let target = OledTelemetryTarget(panel: 0xFFFF_FFFE, topology: MirrorTopology([]))
    let now = SuspendingClock.now
    var captures: [OledCareCoordinator.CaptureRequest] = []
    coordinator.updateTelemetry(for: "panel", state: &display, dimState: dim,
      on: target, panelIsAwake: true, at: now, into: &captures)
    // The absent display has no capture geometry, but the real telemetry
    // qualification takes its slot. A suspension would leave it untouched.
    #expect(display.lastSampleAt == now)
    #expect(display.hoursTracking)
    #expect(display.telemetryEnabled)
  }

  @Test func pauseBlocksLockAndUnfocusedDimsWithoutBypassingOtherSuspensions() {
    let coordinator = OledCareCoordinator()
    var display = state()
    display.engine.noteLock(idleSeconds: 2_000)
    #expect(coordinator.updateDimming(for: "panel", state: &display,
      signals: signals(locked: true)) == .lockDim)
    coordinator.pauseDimming(for: "panel", duration: 900)
    #expect(coordinator.updateDimming(for: "panel", state: &display,
      signals: signals(locked: true)) == .active)
    #expect(coordinator.updateDimming(for: "panel", state: &display,
      signals: signals(unfocused: 2_000)) == .active)
    #expect(coordinator.updateDimming(for: "panel", state: &display,
      signals: signals(mirrored: true)) == .suspended)
    #expect(coordinator.updateDimming(for: "panel", state: &display,
      signals: signals(field: true)) == .suspended)
  }

  @Test(arguments: [false, true])
  func resumeAndExpiryDiscardPausedEvidenceAndStartFreshIdleTime(expire: Bool) {
    let clock = TimeSource()
    let coordinator = OledCareCoordinator(now: { clock.now })
    var display = state()
    coordinator.pauseDimming(for: "panel", duration: 900)
    _ = coordinator.updateDimming(for: "panel", state: &display, signals: signals())
    display.nominatedMask = .uniform(0.7)
    if expire { clock.now = Date(timeIntervalSince1970: 5_000) }
    else { coordinator.resumeDimming(for: "panel") }
    #expect(coordinator.updateDimming(for: "panel", state: &display,
      signals: signals(idle: 8_000, unfocused: 8_000)) == .active)
    #expect(display.nominatedMask == nil)
    #expect(coordinator.updateDimming(for: "panel", state: &display,
      signals: signals(idle: 8_299)) == .active)
    #expect(coordinator.updateDimming(for: "panel", state: &display,
      signals: signals(idle: 8_300)) == .idleDim)
  }

  @Test func reconnectUsesTheStableKeyAndSettingsResetClearsPauses() {
    let coordinator = OledCareCoordinator()
    coordinator.pauseDimming(for: "panel", duration: 900)
    var reconnected = state()
    reconnected.lastDisplayID = 42
    #expect(coordinator.updateDimming(for: "panel", state: &reconnected,
      signals: signals()) == .active)
    var other = state()
    #expect(coordinator.updateDimming(for: "other", state: &other,
      signals: signals()) == .blackout)
    coordinator.beginDisplayReset("panel")
    #expect(coordinator.dimmingPauseDeadline(for: "panel") == nil)
    coordinator.pauseDimming(for: "other", duration: 900)
    coordinator.prepareForReset()
    #expect(coordinator.dimmingPauseDeadline(for: "other") == nil)
  }

  @Test func aPauseThatExpiresWhileDisconnectedResumesWithFreshIdleTime() {
    let clock = TimeSource()
    let coordinator = OledCareCoordinator(now: { clock.now })
    coordinator.pauseDimming(for: "panel", duration: 900)
    clock.now = Date(timeIntervalSince1970: 5_000)
    var reconnected = state()
    #expect(coordinator.updateDimming(for: "panel", state: &reconnected,
      signals: signals(idle: 8_000)) == .active)
    #expect(coordinator.updateDimming(for: "panel", state: &reconnected,
      signals: signals(idle: 8_300)) == .idleDim)
  }

  @Test func unenrollmentClearsThePauseEvenWithoutAConnectedDisplay() {
    let key = "dimming-pause-\(UUID().uuidString)"
    let coordinator = OledCareCoordinator()
    coordinator.pauseDimming(for: key, duration: 900)
    // A never-enrolled unique preference key is also the disconnected opt-out
    // state. The preference hook must clear it before requiring a live model.
    coordinator.reapplyAfterPrefChange(persistenceKey: key)
    #expect(coordinator.dimmingPauseDeadline(for: key) == nil)
  }

  @Test(arguments: [0.0, -1, Double.infinity, Double.nan])
  func invalidDurationsDoNotCreateOrReplaceAPause(_ duration: TimeInterval) {
    let clock = TimeSource()
    let coordinator = OledCareCoordinator(now: { clock.now })
    coordinator.pauseDimming(for: "panel", duration: duration)
    #expect(coordinator.dimmingPauseDeadline(for: "panel") == nil)
    coordinator.pauseDimming(for: "panel", duration: 900)
    coordinator.pauseDimming(for: "panel", duration: duration)
    #expect(coordinator.dimmingPauseDeadline(for: "panel") == Date(timeIntervalSince1970: 1_900))
  }
}
