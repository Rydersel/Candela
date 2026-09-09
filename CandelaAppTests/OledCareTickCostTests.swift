import CandelaKit
import CoreGraphics
import Foundation
import Testing

/// What one care tick is allowed to cost. The driver runs at up to 10 Hz while
/// a dim is up, with the telemetry gate riding it at its own 60 s cadence.
/// Everything pinned here is about WHERE a reading happens, never what it answers.
@Suite("Care tick cost") @MainActor
struct OledCareTickCostTests {
  /// Not a real display: the transform resolves to nil, which ends the pass
  /// before any capture is issued.
  private static let absentDisplay: CGDirectDisplayID = 0xFFFF_FFFE

  @MainActor private final class ReadCount {
    var reads = 0
  }

  private func enrolled() -> OledCareCoordinator.PerDisplay {
    OledCareCoordinator.PerDisplay(
      engine: IdleDimmingEngine(config: OledDimConfig(
        idleDimSeconds: 600, idleDimBrightness: 0.5, lockDim: false,
        blackoutEnabled: false, blackoutSeconds: 900, unfocusedDimEnabled: false,
        unfocusedDimSeconds: 300, unfocusedDimBrightness: 0.5)),
      unfocusedDimEnabled: false, hoursTracking: true, telemetryEnabled: true,
      windowObservationEnabled: false)
  }

  /// The IOKit power-source copy is read at the 60 s decision point, never on
  /// the tick, which holds only while the throttle runs BEFORE the qualification.
  @Test("The battery read happens once a sampling slot, not once a tick")
  func batteryIsReadOnlyAtTheSamplingSlot() {
    let counter = ReadCount()
    let coordinator = OledCareCoordinator(
      windowList: { _ in [] },
      lowBattery: {
        counter.reads += 1
        return false
      })
    let target = OledTelemetryTarget(panel: Self.absentDisplay, topology: MirrorTopology([]))
    let now = SuspendingClock.now
    var state = enrolled()
    var captures: [OledCareCoordinator.CaptureRequest] = []

    state.lastSampleAt = now - .seconds(5)
    coordinator.updateTelemetry(
      for: "panel", state: &state, dimState: .active, on: target, panelIsAwake: true, at: now,
      into: &captures)
    #expect(counter.reads == 0)
    // The throttle turned the tick away, so the slot it belongs to is untouched.
    #expect(state.lastSampleAt == now - .seconds(5))

    state.lastSampleAt = now - .seconds(61)
    coordinator.updateTelemetry(
      for: "panel", state: &state, dimState: .active, on: target, panelIsAwake: true, at: now,
      into: &captures)
    #expect(counter.reads == 1)
    #expect(state.lastSampleAt == now)
    // The transform gate ends the pass before a capture is queued.
    #expect(captures.isEmpty)
  }

  /// A slot is taken only when both gates pass, so an unqualified display keeps
  /// waiting from its last accepted sample rather than resetting its clock.
  @Test("An unqualified display takes no sampling slot")
  func unqualifiedDisplayKeepsItsSlot() {
    let counter = ReadCount()
    let coordinator = OledCareCoordinator(
      windowList: { _ in [] },
      lowBattery: {
        counter.reads += 1
        return false
      })
    let target = OledTelemetryTarget(panel: Self.absentDisplay, topology: MirrorTopology([]))
    let now = SuspendingClock.now
    var state = enrolled()
    var captures: [OledCareCoordinator.CaptureRequest] = []
    state.lastSampleAt = now - .seconds(61)

    // Asleep: the qualification refuses it after the throttle has let it by.
    coordinator.updateTelemetry(
      for: "panel", state: &state, dimState: .active, on: target, panelIsAwake: false, at: now,
      into: &captures)
    #expect(state.lastSampleAt == now - .seconds(61))
    #expect(counter.reads == 0)

    // Dimmed: refused before the battery is ever consulted.
    coordinator.updateTelemetry(
      for: "panel", state: &state, dimState: .idleDim, on: target, panelIsAwake: true, at: now,
      into: &captures)
    #expect(state.lastSampleAt == now - .seconds(61))
    #expect(counter.reads == 0)
    #expect(captures.isEmpty)
  }

  /// Pinned exactly, not as a floor: the slow tick carries the sampling
  /// throttle, which books a fixed 60 s however late the slot ran, so slack
  /// there under-books exposure. 10% of cadence keeps that under 0.35%.
  @Test("Tolerance is zero on the fast cadence and a tenth of the slower ones")
  func toleranceFollowsTheCadence() {
    #expect(OledCareCoordinator.sleepTolerance(for: OledCareCadence.fast) == .zero)
    #expect(
      OledCareCoordinator.sleepTolerance(for: OledCareCadence.windowFollow)
        == .milliseconds(100))
    #expect(
      OledCareCoordinator.sleepTolerance(for: OledCareCadence.slow) == .milliseconds(200))
    #expect(OledCareCoordinator.sleepTolerance(for: OledCareCadence.idle) == .seconds(3))
  }

  /// A cadence the enum does not name is a cadence nobody has reasoned about,
  /// so it gets the strict answer rather than the nearest neighbour's.
  @Test("An unrecognized interval gets no tolerance")
  func unknownIntervalHasNoTolerance() {
    #expect(OledCareCoordinator.sleepTolerance(for: .milliseconds(250)) == .zero)
    #expect(OledCareCoordinator.sleepTolerance(for: .seconds(7)) == .zero)
  }

  /// Neither half enabled is the cheapest tick there is, and it stays that way.
  @Test("A display with telemetry off reads nothing")
  func telemetryOffReadsNothing() {
    let counter = ReadCount()
    let coordinator = OledCareCoordinator(
      windowList: { _ in [] },
      lowBattery: {
        counter.reads += 1
        return false
      })
    let target = OledTelemetryTarget(panel: Self.absentDisplay, topology: MirrorTopology([]))
    let now = SuspendingClock.now
    var state = enrolled()
    var captures: [OledCareCoordinator.CaptureRequest] = []
    state.telemetryEnabled = false
    state.lastSampleAt = now - .seconds(61)

    coordinator.updateTelemetry(
      for: "panel", state: &state, dimState: .active, on: target, panelIsAwake: true, at: now,
      into: &captures)
    #expect(counter.reads == 0)
    #expect(state.lastSampleAt == now - .seconds(61))
    #expect(captures.isEmpty)
  }
}
