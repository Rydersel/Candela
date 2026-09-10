import CandelaKit
import CoreGraphics
import Foundation
import Testing

@Suite("Exposure capture lifecycle") @MainActor
struct OledExposureCaptureTests {
  private static let sample = LuminanceSampler.Sample(grid: [0.5], cols: 1, rows: 1)

  @Test func twoDuePanelsShareOneEnumerationAndBookTheirOwnSamples() async throws {
    let rig = CaptureRig()
    let first = try #require(rig.reserve("first", panel: 11))
    let second = try #require(rig.reserve("second", panel: 22))
    rig.resolve(0, Self.sample)
    rig.resolve(1, Self.sample)

    await rig.run([first, second])

    #expect(rig.enumerations == 1)
    #expect(rig.startedDisplays == [11, 22])
    #expect(rig.maps["first"]?.map.sampleCount == 1)
    #expect(rig.maps["second"]?.map.sampleCount == 1)
    #expect(rig.maps["first"]?.map.cells.allSatisfy { $0 == 30 } == true)
    #expect(rig.pipeline.reserve(key: "first", target: first.target,
      transform: first.transform, epoch: 0) != nil)
  }

  @Test func aDelayedPanelDoesNotHoldUpTheOtherPanelsCapture() async throws {
    let rig = CaptureRig()
    let first = try #require(rig.reserve("first", panel: 11))
    let second = try #require(rig.reserve("second", panel: 22))
    let work = Task { await rig.run([first, second]) }
    await rig.waitForCaptureStart()

    // start() is synchronous. All captures must be launched before the first
    // capture task gets the actor, so this assertion needs no scheduling delay.
    #expect(rig.startedDisplays == [11, 22])
    if rig.startedDisplays.count == 2 {
      rig.resolve(1, Self.sample)
      await rig.waitForAcceptance()
      #expect(rig.maps["second"]?.map.sampleCount == 1)
      #expect(rig.maps["first"] == nil)
    }
    // Resolve both even on the failing sequential implementation so the test
    // reports the failed assertion instead of leaving a suspended task behind.
    rig.resolve(0, Self.sample)
    rig.resolve(1, Self.sample)
    await work.value
  }

  @Test func failedCaptureSkipsItsSampleAndDoesNotPreventTheNextPanel() async throws {
    let rig = CaptureRig()
    let first = try #require(rig.reserve("first", panel: 11))
    let second = try #require(rig.reserve("second", panel: 22))
    rig.resolve(0, nil)
    rig.resolve(1, Self.sample)
    await rig.run([first, second])

    #expect(rig.maps["first"] == nil)
    #expect(rig.maps["second"]?.map.sampleCount == 1)
    #expect(rig.failures == ["first"])
    #expect(rig.pipeline.reserve(key: "first", target: first.target,
      transform: first.transform, epoch: 0) != nil)
  }

  @Test func failedEnumerationReleasesEveryReservationWithoutBookingBlackSamples() async throws {
    let rig = CaptureRig()
    let first = try #require(rig.reserve("first", panel: 11))
    let second = try #require(rig.reserve("second", panel: 22))
    rig.enumerationSucceeds = false
    await rig.run([first, second])

    #expect(rig.enumerations == 1)
    #expect(rig.startedDisplays.isEmpty)
    #expect(rig.maps.isEmpty)
    #expect(rig.failures == ["first", "second"])
    #expect(rig.pipeline.reserve(key: "first", target: first.target,
      transform: first.transform, epoch: 0) != nil)
    #expect(rig.pipeline.reserve(key: "second", target: second.target,
      transform: second.transform, epoch: 0) != nil)
  }

  @Test func anEmptyWaveDoesNotEnumerate() async {
    let rig = CaptureRig()
    await rig.run([])
    #expect(rig.enumerations == 0)
  }

  enum Invalidation: CaseIterable {
    case historyDeleted, telemetryOff, displayIDChanged, asleep, locked, resetting
    case dimmed, userMirrored, rotated, resized, departed, lowBattery, missingGeometry
  }

  @Test(arguments: Invalidation.allCases, [true, false])
  func aChangeDuringCaptureRejectsTheResult(_ change: Invalidation, succeeded: Bool) async throws {
    let rig = CaptureRig()
    let request = try #require(rig.reserve("panel", panel: 11))
    let work = Task { await rig.run([request]) }
    await rig.waitForCaptureStart()
    switch change {
    case .historyDeleted: rig.contexts["panel"]?.epoch += 1
    case .telemetryOff: rig.contexts["panel"]?.telemetryEnabled = false
    case .displayIDChanged: rig.contexts["panel"]?.displayID = 33
    case .asleep: rig.contexts["panel"]?.panelIsAwake = false
    case .locked: rig.contexts["panel"]?.isLocked = true
    case .resetting: rig.contexts["panel"]?.isResetting = true
    case .lowBattery: rig.contexts["panel"]?.isLowBattery = true
    case .missingGeometry: rig.contexts["panel"]?.transform = nil
    case .dimmed: rig.contexts["panel"]?.dimState = .idleDim
    case .userMirrored: rig.contexts["panel"]?.dimState = .suspended
    case .rotated:
      rig.contexts["panel"]?.transform = PanelSpaceTransform(
        displaySize: CGSize(width: 120, height: 240), rotation: .ninety)
    case .resized:
      rig.contexts["panel"]?.transform = PanelSpaceTransform(
        displaySize: CGSize(width: 480, height: 240), rotation: .standard)
    case .departed: rig.contexts["panel"] = nil
    }
    rig.resolve(0, succeeded ? Self.sample : nil)
    await work.value

    #expect(rig.maps.isEmpty)
    #expect(rig.failures.isEmpty)
    #expect(rig.pipeline.reserve(key: request.key, target: request.target,
      transform: request.transform, epoch: 1) != nil)
  }

  @Test func aSynthesizedSurfaceIsCapturedButItsPanelReceivesTheSample() async throws {
    let rig = CaptureRig()
    let target = Self.synthesisTarget()
    let request = try #require(rig.reserve("physical", target: target))
    rig.contexts["physical"]?.dimState = .suspended
    rig.resolve(0, Self.sample)
    await rig.run([request])
    #expect(rig.startedDisplays == [79])
    #expect(rig.maps["physical"]?.map.sampleCount == 1)
    #expect(rig.maps.count == 1)
  }

  @Test func endingSynthesisDuringCaptureRejectsTheOldSurface() async throws {
    let rig = CaptureRig()
    let request = try #require(rig.reserve("physical", target: Self.synthesisTarget()))
    let work = Task { await rig.run([request]) }
    await rig.waitForCaptureStart()
    rig.contexts["physical"]?.target = OledTelemetryTarget(panel: 11, topology: MirrorTopology([]))
    rig.resolve(0, Self.sample)
    await work.value
    #expect(rig.maps.isEmpty)
  }

  @Test func aPendingPanelCannotReserveASecondCapture() throws {
    let rig = CaptureRig()
    let request = try #require(rig.reserve("panel", panel: 11))
    #expect(rig.pipeline.reserve(key: request.key, target: request.target,
      transform: request.transform, epoch: 0) == nil)
  }

  @Test(arguments: [true, false])
  func anOldEnrollmentCannotBookOrReleaseItsReplacementsCapture(succeeded: Bool) async throws {
    let rig = CaptureRig()
    let old = try #require(rig.reserve("panel", panel: 11))
    let oldWork = Task { await rig.run([old]) }
    await rig.waitForCaptureStart()
    rig.pipeline.invalidate(key: "panel")
    let replacement = try #require(rig.reserve("panel", panel: 11))
    let newWork = Task { await rig.run([replacement]) }
    await rig.waitForCaptureStart()

    rig.resolve(0, succeeded ? Self.sample : nil)
    await oldWork.value
    #expect(rig.maps.isEmpty)
    #expect(rig.failures.isEmpty)
    #expect(rig.pipeline.reserve(key: replacement.key, target: replacement.target,
      transform: replacement.transform, epoch: 0) == nil)

    rig.resolve(1, Self.sample)
    await newWork.value
    #expect(rig.maps["panel"]?.map.sampleCount == 1)
  }

  @Test func invalidationBeforeEnumerationCompletesDoesNotStartACapture() async throws {
    let rig = CaptureRig()
    let request = try #require(rig.reserve("panel", panel: 11))
    rig.beforeEnumerationReturns = { rig.pipeline.invalidate(key: "panel") }
    rig.resolve(0, Self.sample)
    await rig.run([request])
    #expect(rig.startedDisplays.isEmpty)
    #expect(rig.maps.isEmpty)
  }

  enum HistoryReset: CaseIterable { case deleteHistory, resetSettings }

  @Test(arguments: HistoryReset.allCases)
  func clearingHistoryDuringEnumerationReleasesTheOldWave(_ action: HistoryReset) async throws {
    let rig = CaptureRig()
    let key = "capture-delete-fixture-\(UUID().uuidString)"
    let request = try #require(rig.reserve(key, panel: 11))
    let coordinator = OledCareCoordinator(exposureCapture: rig.pipeline)
    // No model is started, so reset has no overlays, controllers or real
    // displays to touch. History deletion uses only this unique fixture key.
    rig.beforeEnumerationReturns = {
      switch action {
      case .deleteHistory: coordinator.clearExposureHistory(for: key)
      case .resetSettings: coordinator.prepareForReset()
      }
    }
    rig.resolve(0, Self.sample)
    await rig.run([request])

    #expect(rig.startedDisplays.isEmpty)
    #expect(rig.maps.isEmpty)
    #expect(rig.pipeline.reserve(key: key, target: request.target,
      transform: request.transform, epoch: 1) != nil)
  }

  @Test(arguments: HistoryReset.allCases)
  func clearingHistoryReleasesACaptureThatHasNotReturned(_ action: HistoryReset) async throws {
    let rig = CaptureRig()
    let key = "capture-delete-fixture-\(UUID().uuidString)"
    let old = try #require(rig.reserve(key, panel: 11))
    let coordinator = OledCareCoordinator(exposureCapture: rig.pipeline)
    let oldWork = Task { await rig.run([old]) }
    await rig.waitForCaptureStart()
    switch action {
    case .deleteHistory: coordinator.clearExposureHistory(for: key)
    case .resetSettings: coordinator.prepareForReset()
    }
    let replacement = rig.pipeline.reserve(key: key, target: old.target,
      transform: old.transform, epoch: 1)
    #expect(replacement != nil)

    // Release the obsolete work even if the slot assertion fails.
    rig.resolve(0, Self.sample)
    await oldWork.value
    #expect(rig.maps.isEmpty)
    if let replacement {
      #expect(rig.pipeline.reserve(key: key, target: replacement.target,
        transform: replacement.transform, epoch: 1) == nil)
    }
  }

  @Test func aFailedOldEnumerationCannotReleaseAReplacementReservation() async throws {
    let rig = CaptureRig()
    let request = try #require(rig.reserve("panel", panel: 11))
    rig.beforeEnumerationReturns = {
      rig.pipeline.invalidate(key: "panel")
      #expect(rig.reserve("panel", panel: 11) != nil)
    }
    rig.enumerationSucceeds = false
    await rig.run([request])

    #expect(rig.startedDisplays.isEmpty)
    #expect(rig.maps.isEmpty)
    #expect(rig.failures.isEmpty)
    #expect(rig.pipeline.reserve(key: request.key, target: request.target,
      transform: request.transform, epoch: 0) == nil)
  }

  private static func synthesisTarget() -> OledTelemetryTarget {
    func display(_ id: CGDirectDisplayID, mirror: CGDirectDisplayID = 0) -> ConfiguredDisplay {
      ConfiguredDisplay(id: id,
        identity: DisplayConfigIdentity(vendor: 1, model: id, serial: id, isBuiltIn: false),
        name: "Fixture", isBuiltIn: false, mirrorsDisplay: mirror)
    }
    return OledTelemetryTarget(panel: 11,
      topology: MirrorTopology([display(11, mirror: 79), display(79)], synthesisMasters: [79]))
  }
}

/// Capture preparation and live context reads are controlled. Reservation,
/// ownership, validation and dispatch run through the production pipeline;
/// accepted samples go through the real exposure accumulator. The history
/// tests also call the coordinator's production deletion and reset entry points.
@MainActor private final class CaptureRig {
  typealias Request = OledExposureCapture.Request
  var enumerations = 0
  var enumerationSucceeds = true
  var beforeEnumerationReturns: (() -> Void)?
  var startedDisplays: [CGDirectDisplayID] = []
  var contexts: [String: OledExposureCapture.Context] = [:]
  var maps: [String: ExposureAccumulator] = [:]
  var failures: [String] = []
  private var results: [Int: Resolution] = [:]
  private var waiting: [Int: CheckedContinuation<LuminanceSampler.Sample?, Never>] = [:]
  private let starts = CaptureEvent()
  private let accepts = CaptureEvent()

  private enum Resolution { case sample(LuminanceSampler.Sample?) }

  lazy var pipeline = OledExposureCapture { [unowned self] in
    enumerations += 1
    let beforeReturn = beforeEnumerationReturns
    beforeEnumerationReturns = nil
    beforeReturn?()
    guard enumerationSucceeds else { return nil }
    return LuminanceSampler.Wave { [unowned self] displayID in
      let index = startedDisplays.count
      startedDisplays.append(displayID)
      return Task { @MainActor in
        self.starts.signal()
        return await withCheckedContinuation { continuation in
          if case let .sample(sample) = self.results[index] {
            continuation.resume(returning: sample)
          } else {
            self.waiting[index] = continuation
          }
        }
      }
    }
  }

  func reserve(_ key: String, panel: CGDirectDisplayID) -> Request? {
    reserve(key, target: OledTelemetryTarget(panel: panel, topology: MirrorTopology([])))
  }

  func reserve(_ key: String, target: OledTelemetryTarget) -> Request? {
    let transform = PanelSpaceTransform(displaySize: CGSize(width: 240, height: 120), rotation: .standard)
    contexts[key] = OledExposureCapture.Context(
      epoch: 0, displayID: target.panel, target: target, transform: transform,
      telemetryEnabled: true, dimState: .active, isResetting: false,
      isLocked: false, panelIsAwake: true, isLowBattery: false)
    return pipeline.reserve(key: key, target: target, transform: transform, epoch: 0)
  }

  func run(_ requests: [Request]) async {
    await pipeline.run(requests, current: { [unowned self] request in contexts[request.key] },
      accept: { [unowned self] request, sample in
        var map = maps[request.key] ?? ExposureAccumulator()
        map.accumulate(displayGrid: sample.grid, cols: sample.cols, rows: sample.rows,
          through: request.transform, elapsed: 60, at: Date(timeIntervalSince1970: 0))
        maps[request.key] = map
        accepts.signal()
      }, failed: { [unowned self] request in failures.append(request.key) })
  }

  func resolve(_ index: Int, _ sample: LuminanceSampler.Sample?) {
    results[index] = .sample(sample)
    waiting.removeValue(forKey: index)?.resume(returning: sample)
  }

  func waitForCaptureStart() async { await starts.next() }
  func waitForAcceptance() async { await accepts.next() }
}

@MainActor private final class CaptureEvent {
  private var available = 0
  private var waiting: CheckedContinuation<Void, Never>?

  func signal() {
    if let continuation = waiting {
      waiting = nil
      continuation.resume()
    } else {
      available += 1
    }
  }

  func next() async {
    if available > 0 {
      available -= 1
      return
    }
    await withCheckedContinuation { waiting = $0 }
  }
}
