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

  /// IDs no NSScreen carries, so an overlay apply reaches no real window.
  private static let liveID: CGDirectDisplayID = 0xFFFF_FF01
  private static let reconnectedID: CGDirectDisplayID = 0xFFFF_FF02

  /// A hardware-free model whose coordinator holds the model link and reads
  /// enrollment from an in-memory store, with one enrolled key.
  @MainActor private struct Rig {
    let key: String
    let discovery: ScriptedDiscovery
    let model: AppModel

    init(key: String, topology: [(id: CGDirectDisplayID, key: String, name: String)]) async {
      self.key = key
      let defaults = InMemoryDefaults()
      DisplayPrefs(defaults: defaults, persistenceKey: key).oledCareEnrolled = true
      discovery = ScriptedDiscovery(topology)
      model = TestFixtures.appModel(discovery: discovery)
      model.oledCare.prefsDefaults = defaults
      model.oledCare.adopt(model: model)
      await model.refresh()
    }
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
    let store = InMemoryDefaults()
    coordinator.prefsDefaults = store
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
    // Session-only: the pause wrote nothing to the store prefs persist in.
    #expect(store.dictionaryRepresentation().isEmpty)
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

  @Test func reconnectUsesTheStableKeyAndSettingsResetClearsPauses() async throws {
    let rig = await Rig(key: "pause-reconnect", topology: [])
    let care = rig.model.oledCare
    // Paused while disconnected: no per-display state exists to carry it.
    #expect(care.pauseDimming(for: rig.key, until: Date().addingTimeInterval(900)))
    #expect(care.states[rig.key] == nil)
    rig.discovery.topology = [(id: Self.reconnectedID, key: rig.key, name: "Panel")]
    await rig.model.refresh()
    care.reapplyAfterPrefChange(persistenceKey: rig.key)
    var fresh = try #require(care.states[rig.key])
    #expect(fresh.lastDisplayID == Self.reconnectedID)
    #expect(!fresh.dimmingPaused)
    let dim = care.updateDimming(for: rig.key, state: &fresh, signals: signals())
    #expect(dim == .active)
    #expect(fresh.dimmingPaused)
    // What render draws from on that first tick, for any state the engine reports.
    for state in [dim, .idleDim, .blackout] {
      let overlay = OledCareCoordinator.baseOverlay(state, state: fresh)
      #expect(overlay.alpha == nil && !overlay.blackout)
    }
    var other = state()
    let otherDim = care.updateDimming(for: "other", state: &other, signals: signals())
    #expect(otherDim == .blackout)
    #expect(OledCareCoordinator.baseOverlay(otherDim, state: other).blackout)
    care.beginDisplayReset(rig.key)
    #expect(care.dimmingPauseDeadline(for: rig.key) == nil)
    care.pauseDimming(for: "other", duration: 900)
    care.prepareForReset()
    #expect(care.dimmingPauseDeadline(for: "other") == nil)
  }

  /// The immediate lift in `pauseDimming(for:until:)`: a display already in lock
  /// dim must come back now, not on the driver's next tick.
  @Test func pausingEndsALiveLockDimAndClearsTheOverlayAtOnce() async throws {
    let rig = await Rig(key: "pause-lock-dim", topology: [(id: Self.liveID, key: "pause-lock-dim", name: "Panel")])
    let care = rig.model.oledCare
    care.reapplyAfterPrefChange(persistenceKey: rig.key)
    var staged = try #require(care.states[rig.key])
    let controller = try #require(
      rig.model.displays.first { $0.display.persistenceKey == rig.key }?.controller)
    controller.beginTemporaryDim(factor: 0.4)
    staged.lockDimEngaged = true
    staged.lastAppliedAlpha = 0.5
    care.states[rig.key] = staged
    #expect(controller.temporaryDimFactor == 0.4)
    #expect(care.pauseDimming(for: rig.key, until: Date().addingTimeInterval(600)))
    let paused = try #require(care.states[rig.key])
    #expect(!paused.lockDimEngaged)
    #expect(controller.temporaryDimFactor == nil)
    #expect(paused.dimmingPaused)
    #expect(paused.lastAppliedAlpha == nil)
    #expect(care.dimStates[rig.key] == .active)
  }

  @Test func aPauseCannotBeSetWhileItsDisplayIsResetting() {
    let clock = TimeSource()
    let care = OledCareCoordinator(now: { clock.now })
    let deadline = clock.now.addingTimeInterval(600)
    care.beginDisplayReset("panel")
    #expect(!care.pauseDimming(for: "panel", until: deadline))
    care.pauseDimming(for: "panel", duration: 900)
    #expect(care.dimmingPauseDeadline(for: "panel") == nil)
    // Scoped to the display being reset.
    #expect(care.pauseDimming(for: "other", until: deadline))
    care.displayResetDidComplete("panel")
    #expect(care.pauseDimming(for: "panel", until: deadline))
    #expect(care.dimmingPauseDeadline(for: "panel") == deadline)
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
    let key = "dimming-pause"
    let coordinator = OledCareCoordinator()
    coordinator.prefsDefaults = InMemoryDefaults()
    coordinator.pauseDimming(for: key, duration: 900)
    // A never-enrolled key is also the disconnected opt-out state. The preference hook must clear it before requiring a live model.
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
