import CandelaKit
import CoreGraphics
import Testing
import os

private actor HeldRecoveryHDR {
  private var count = 0
  private var pending: [Int: CheckedContinuation<Bool?, Never>] = [:]
  func read() async -> Bool? {
    await withCheckedContinuation { continuation in
      pending[count] = continuation
      count += 1
    }
  }
  func waitForRequests(_ expected: Int) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while count < expected && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    return count >= expected
  }
  func answer(_ request: Int, _ enabled: Bool?) {
    pending.removeValue(forKey: request)?.resume(returning: enabled)
  }
}

/// Answers table reads from a dictionary, so a display can be made to refuse its
/// own baseline. No display in the rig can be told to do that on demand, and
/// the companion leg is defined entirely by what happens when one does.
@MainActor
private final class StubGammaDriver: GammaTableDriving {
  /// Displays that will report a table. Anything absent refuses.
  var tables: [CGDirectDisplayID: GammaSamples] = [:]
  /// Displays with a screen, i.e. ones the activity enforcer can be parked on.
  var screens: Set<CGDirectDisplayID> = []
  var identities: [CGDirectDisplayID: String] = [:]

  private(set) var writes: [(target: CGDirectDisplayID, samples: GammaSamples)] = []
  private(set) var enforcedCount = 0
  private(set) var restoreCount = 0

  func readTable(_ displayID: CGDirectDisplayID, capacity _: UInt32) -> GammaReadOutcome {
    guard let table = tables[displayID] else { return .failed(.failure) }
    return .table(table)
  }

  func writeTable(_ displayID: CGDirectDisplayID, _ samples: GammaSamples) -> CGError {
    writes.append((displayID, samples))
    return .success
  }

  func restoreColorSyncSettings() { restoreCount += 1 }
  func moveEnforcer(to displayID: CGDirectDisplayID) -> Bool { screens.contains(displayID) }
  func enforceActivity() { enforcedCount += 1 }
  func recoveryIdentity(on displayID: CGDirectDisplayID) -> String? {
    screens.contains(displayID) ? identities[displayID] : nil
  }
}

@Suite("Gamma controller baselines")
@MainActor
struct GammaControllerTests {
  @Test func recoveryFollowsANewerSuccessfulWriteWithoutRenewingItsBudget() async throws {
    let driver = StubGammaDriver()
    driver.screens = [2]; driver.identities[2] = "panel-A"
    driver.tables[2] = Self.profileTable()
    let gamma = GammaController(driver: driver)
    gamma.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    let hdr = HeldRecoveryHDR()
    let clock = OSAllocatedUnfairLock(initialState: 0.0)
    let recovery = GammaReconfigurationRecovery(
      gamma: gamma, targets: { [2] }, readHDR: { _ in await hdr.read() },
      epoch: { 0 }, asleep: { false }, now: { clock.withLock { $0 } }, interval: 3600)
    defer { recovery.stop() }
    let first = try #require(recovery.begin())
    try #require(await hdr.waitForRequests(1))
    await hdr.answer(0, false)
    await first.value
    // The normal topology rebuild writes after recovery captured its owner.
    clock.withLock { $0 = 4.8 }
    gamma.applyGammaScale(0.6, on: 2, enforcerOn: 2)
    recovery.tick()
    try #require(await hdr.waitForRequests(2))
    recovery.tick()
    #expect(driver.writes.count == 2) // the old HDR reply cannot authorize it
    await hdr.answer(1, false)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while driver.writes.count == 2 && ContinuousClock.now < deadline {
      recovery.tick()
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(driver.writes.count == 3)
    #expect(driver.writes.last?.samples == Self.profileTable().scaled(by: 0.6))
    clock.withLock { $0 = 5 }
    recovery.tick()
    #expect(driver.writes.count == 3)
    #expect(recovery.begin() == nil)
  }

  @Test(arguments: [4.9, 6.0, 120.0])
  func aNewReconfigurationAfterTheFinalPassHasItsOwnBoundedWindow(start: Double) async throws {
    let driver = StubGammaDriver()
    driver.screens = [2]; driver.identities[2] = "panel-A"
    let baseline = Self.profileTable()
    driver.tables[2] = baseline
    let gamma = GammaController(driver: driver)
    gamma.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    let clock = OSAllocatedUnfairLock(initialState: 0.0)
    let epoch = OSAllocatedUnfairLock(initialState: UInt64(0))
    let recovery = GammaReconfigurationRecovery(
      gamma: gamma, targets: { [2] }, readHDR: { _ in false },
      epoch: { epoch.withLock { $0 } }, asleep: { false },
      now: { clock.withLock { $0 } }, interval: 3600)
    defer { recovery.stop() }
    recovery.beginFinalPass()
    let settling = try #require(recovery.endFinalPass())
    await settling.value
    // The reconnect may begin just before, just after, or long after the
    // departure's post-pass watch expires. All are separate bursts.
    clock.withLock { $0 = start }
    epoch.withLock { $0 = 1 }
    let reconnect = try #require(recovery.begin())
    await reconnect.value
    clock.withLock { $0 = start + 0.2 }
    recovery.tick()
    #expect(driver.writes.count == 2)
    // Further CG events in this burst must not renew its allowance.
    clock.withLock { $0 = start + 4.9 }
    epoch.withLock { $0 = 2 }
    let repeated = try #require(recovery.begin())
    await repeated.value
    clock.withLock { $0 = start + 5 }
    recovery.tick()
    #expect(driver.writes.count == 2)
    #expect(recovery.begin() == nil)
  }

  @Test func aLateResetAfterTheFinalPassDoesNotWaitForAnotherNotification() async throws {
    let driver = StubGammaDriver()
    driver.screens = [2]; driver.identities[2] = "panel-A"
    let baseline = Self.profileTable()
    driver.tables[2] = baseline
    let gamma = GammaController(driver: driver)
    gamma.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    let clock = OSAllocatedUnfairLock(initialState: 0.0)
    let recovery = GammaReconfigurationRecovery(
      gamma: gamma, targets: { [2] }, readHDR: { _ in false },
      epoch: { 0 }, asleep: { false }, now: { clock.withLock { $0 } }, interval: 3600)
    defer { recovery.stop() }
    recovery.beginFinalPass()
    gamma.resetAllGamma()
    gamma.recaptureDefaultTable(on: 2)
    gamma.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    driver.tables[2] = baseline.scaled(by: 0.5)
    let settling = try #require(recovery.endFinalPass())
    await settling.value
    recovery.tick()
    #expect(driver.writes.count == 2)
    // Measured on hardware: the system reset arrives 3.6 seconds after
    // the completed pass, before its delayed AppKit notification.
    clock.withLock { $0 = 3.6 }
    driver.tables[2] = baseline
    recovery.tick()
    #expect(driver.writes.count == 3)
    #expect(driver.writes.last?.samples == baseline.scaled(by: 0.5))
  }

  @Test func aStaleHDRReplyCannotAuthorizeRecoveryForANewerEpoch() async throws {
    let driver = StubGammaDriver()
    driver.screens = [2]; driver.identities[2] = "panel-A"
    driver.tables[2] = Self.profileTable()
    let gamma = GammaController(driver: driver)
    gamma.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    let epoch = OSAllocatedUnfairLock(initialState: UInt64(0))
    let hdr = HeldRecoveryHDR()
    let recovery = GammaReconfigurationRecovery(
      gamma: gamma, targets: { [2] }, readHDR: { _ in await hdr.read() },
      epoch: { epoch.withLock { $0 } }, asleep: { false }, now: { 0 }, interval: 3600)
    defer { recovery.stop() }
    let old = try #require(recovery.begin())
    try #require(await hdr.waitForRequests(1))
    epoch.withLock { $0 = 1 }
    let new = try #require(recovery.begin())
    try #require(await hdr.waitForRequests(2))
    await hdr.answer(1, true)
    await new.value
    // The old SDR answer arrives AFTER the new HDR answer.
    await hdr.answer(0, false)
    await old.value
    recovery.tick()
    #expect(driver.writes.count == 1)
    // A fresh brightness write establishes ownership after the HDR stand-down.
    gamma.applyGammaScale(0.6, on: 2, enforcerOn: 2)
    epoch.withLock { $0 = 2 }
    let current = try #require(recovery.begin())
    try #require(await hdr.waitForRequests(3))
    await hdr.answer(2, false)
    await current.value
    recovery.tick()
    #expect(driver.writes.count == 3)
  }

  @Test func anUnfamiliarCurveStopsRecoveryAcrossRepeatedNotifications() async throws {
    let driver = StubGammaDriver()
    driver.screens = [2]; driver.identities[2] = "panel-A"
    let baseline = Self.profileTable()
    driver.tables[2] = baseline
    let gamma = GammaController(driver: driver)
    gamma.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    let recovery = GammaReconfigurationRecovery(
      gamma: gamma, targets: { [2] }, readHDR: { _ in false },
      epoch: { 0 }, asleep: { false }, now: { 0 }, interval: 3600)
    defer { recovery.stop() }
    let first = try #require(recovery.begin())
    await first.value
    driver.tables[2] = GammaSamples.linear(count: Self.sampleCount)
    recovery.tick()
    driver.tables[2] = baseline
    if let repeated = recovery.begin() { await repeated.value }
    recovery.tick()
    #expect(driver.writes.count == 1)
    // A fresh brightness write deliberately establishes a new recovery owner.
    gamma.applyGammaScale(0.6, on: 2, enforcerOn: 2)
    let fresh = try #require(recovery.begin())
    await fresh.value
    recovery.tick()
    #expect(driver.writes.count == 3)
  }

  @Test func aFinalPassStopsAnHDRReplyBeforeItCanTouchTheBaseline() async throws {
    let driver = StubGammaDriver()
    driver.screens = [2]; driver.identities[2] = "panel-A"
    driver.tables[2] = Self.profileTable()
    let gamma = GammaController(driver: driver)
    gamma.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    let hdr = HeldRecoveryHDR()
    let recovery = GammaReconfigurationRecovery(
      gamma: gamma, targets: { [2] }, readHDR: { _ in await hdr.read() },
      epoch: { 0 }, asleep: { false }, now: { 0 }, interval: 3600)
    defer { recovery.stop() }
    let preparation = try #require(recovery.begin())
    try #require(await hdr.waitForRequests(1))
    recovery.beginFinalPass()
    gamma.resetAllGamma()
    await hdr.answer(0, false)
    await preparation.value
    recovery.tick()
    #expect(driver.writes.count == 1)
    gamma.recaptureDefaultTable(on: 2)
    recovery.endFinalPass()
    recovery.tick()
    #expect(driver.writes.count == 1)
  }

  @Test func aDelayedSystemResetRestoresTheCapturedProfileWithoutCompounding() throws {
    let driver = StubGammaDriver()
    driver.screens = [2]
    driver.identities[2] = "panel-A"
    let baseline = Self.profileTable()
    driver.tables[2] = baseline
    let controller = GammaController(driver: driver)
    #expect(controller.applyGammaScale(0.5, on: 2, enforcerOn: 2))
    let snapshot = try #require(controller.recoverySnapshot(on: 2))
    driver.tables[2] = baseline.scaled(by: 0.5)
    #expect(controller.recoverBaselineIfReset(snapshot, hdrEnabled: false) == .unchanged)
    #expect(driver.writes.count == 1)
    // The table can remain intact at notification time and reset later.
    driver.tables[2] = baseline
    #expect(controller.recoverBaselineIfReset(snapshot, hdrEnabled: false) == .written)
    #expect(driver.writes.count == 2)
    #expect(driver.writes.last?.samples == baseline.scaled(by: 0.5))
    #expect(controller.recoverBaselineIfReset(snapshot, hdrEnabled: false) == .written)
    #expect(driver.writes.count == 3)
    #expect(driver.writes.last?.samples == baseline.scaled(by: 0.5))
  }

  @Test func recoveryDoesNotOverwriteAnUnfamiliarCurveWithTheSamePeak() throws {
    let driver = StubGammaDriver()
    driver.screens = [2]
    driver.identities[2] = "panel-A"
    driver.tables[2] = Self.profileTable()
    let controller = GammaController(driver: driver)
    controller.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    let snapshot = try #require(controller.recoverySnapshot(on: 2))
    driver.tables[2] = GammaSamples.linear(count: Self.sampleCount)
    #expect(controller.recoverBaselineIfReset(snapshot, hdrEnabled: false) == .stopped)
    #expect(driver.writes.count == 1)
  }

  @Test(arguments: [true, nil] as [Bool?])
  func recoveryRequiresAnAffirmativeSDRObservation(hdr: Bool?) throws {
    let driver = StubGammaDriver()
    driver.screens = [2]
    driver.identities[2] = "panel-A"
    driver.tables[2] = Self.profileTable()
    let controller = GammaController(driver: driver)
    controller.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    let snapshot = try #require(controller.recoverySnapshot(on: 2))
    #expect(controller.recoverBaselineIfReset(snapshot, hdrEnabled: hdr) == .stopped)
    #expect(driver.writes.count == 1)
  }

  @Test func recoveryRejectsIDReuseAndMissingScreensButDistinguishesNewBrightness() throws {
    let driver = StubGammaDriver()
    driver.screens = [2]
    driver.identities[2] = "panel-A"
    driver.tables[2] = Self.profileTable()
    let controller = GammaController(driver: driver)
    controller.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    let snapshot = try #require(controller.recoverySnapshot(on: 2))
    driver.identities[2] = "panel-B"
    #expect(controller.recoverBaselineIfReset(snapshot, hdrEnabled: false) == .stopped)
    driver.identities[2] = "panel-A"
    driver.screens = []
    #expect(controller.recoverBaselineIfReset(snapshot, hdrEnabled: false) == .stopped)
    driver.screens = [2]
    controller.applyGammaScale(0.7, on: 2, enforcerOn: 2)
    #expect(controller.recoverBaselineIfReset(snapshot, hdrEnabled: false) == .superseded)
    #expect(driver.writes.count == 2)
    driver.identities[2] = "panel-B"
    controller.applyGammaScale(0.8, on: 2, enforcerOn: 2)
    #expect(controller.recoverBaselineIfReset(snapshot, hdrEnabled: false) == .stopped)
    #expect(driver.writes.count == 3)
  }

  @Test func cancellingAnOldSnapshotPreservesANewerBrightnessOwner() throws {
    let driver = StubGammaDriver()
    driver.screens = [2]; driver.identities[2] = "panel-A"
    driver.tables[2] = Self.profileTable()
    let gamma = GammaController(driver: driver)
    gamma.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    let old = try #require(gamma.recoverySnapshot(on: 2))
    gamma.applyGammaScale(0.6, on: 2, enforcerOn: 2)
    gamma.cancelRecovery(old)
    #expect(gamma.recoverySnapshot(on: 2) != nil)
  }

  @Test func aMissingIdentityCannotRegainOwnershipWithoutAFreshWrite() {
    let driver = StubGammaDriver()
    driver.screens = [2]; driver.identities[2] = "panel-A"
    driver.tables[2] = Self.profileTable()
    let gamma = GammaController(driver: driver)
    gamma.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    driver.identities[2] = nil
    #expect(gamma.recoverySnapshot(on: 2) == nil)
    driver.identities[2] = "panel-A"
    #expect(gamma.recoverySnapshot(on: 2) == nil)
    gamma.applyGammaScale(0.6, on: 2, enforcerOn: 2)
    #expect(gamma.recoverySnapshot(on: 2) != nil)
  }

  @Test func finalResetInvalidatesRecoveryBeforeBaselineRecapture() throws {
    let driver = StubGammaDriver()
    driver.screens = [2]
    driver.identities[2] = "panel-A"
    driver.tables[2] = Self.profileTable()
    let controller = GammaController(driver: driver)
    controller.applyGammaScale(0.5, on: 2, enforcerOn: 2)
    let snapshot = try #require(controller.recoverySnapshot(on: 2))
    controller.resetAllGamma()
    #expect(controller.recoverBaselineIfReset(snapshot, hdrEnabled: false) == .stopped)
    #expect(driver.writes.count == 1)
    controller.recaptureDefaultTable(on: 2)
    #expect(controller.recoverySnapshot(on: 2) == nil)
  }

  @Test func recoveryNeverCapturesAnUnknownBaselineOrUsesACompanionTarget() {
    let driver = StubGammaDriver()
    driver.screens = [2, 5]
    driver.identities = [2: "panel-A", 5: "virtual"]
    let controller = GammaController(driver: driver)
    controller.applyGammaScale(assumingLinearBaseline: 0.5, on: 2, enforcerOn: 2)
    #expect(controller.recoverySnapshot(on: 2) == nil)
    driver.tables[2] = Self.profileTable()
    controller.applyGammaScale(0.5, on: 2, enforcerOn: 5)
    #expect(controller.recoverySnapshot(on: 2) == nil)
  }

  @Test func repeatedNotificationsDoNotExtendTheRecoveryDeadlineOrWriteBudget() {
    var budget = GammaRecoveryBudget()
    let allowed0 = budget.begin(at: 10)
    #expect(allowed0)
    let allowed1 = budget.begin(at: 14.99)
    #expect(allowed1)
    let allowed2 = budget.begin(at: 15)
    #expect(!allowed2)
    budget.finish()
    let allowed3 = budget.begin(at: 20)
    #expect(allowed3)
    for _ in 0..<8 { budget.recordWrite() }
    let allowed4 = budget.begin(at: 20.1)
    #expect(!allowed4)
    budget.finish()
    let allowed5 = budget.begin(at: 30)
    #expect(allowed5)
  }

  private static let panelID: CGDirectDisplayID = 2
  private static let virtualID: CGDirectDisplayID = 5
  private static let sampleCount = 256

  /// A profile curve that is visibly not the straight ramp, so a test cannot
  /// pass by accident when the identity fallback fires where it should not.
  private static func profileTable() -> GammaSamples {
    let ramp = (0 ..< sampleCount).map { CGGammaValue(pow(Double($0) / Double(sampleCount - 1), 2.2)) }
    return GammaSamples(red: ramp, green: ramp, blue: ramp)
  }

  /// A virtual display cannot be read back by the process that created it, so
  /// the companion leg has no baseline to scale. It still must receive the
  /// table, so the table is written against the straight ramp.
  @Test func theCompanionLegWritesTheIdentityScaledTableWhenTheBaselineCannotBeCaptured() {
    let driver = StubGammaDriver()
    driver.screens = [Self.virtualID]
    let controller = GammaController(driver: driver)

    let landed = controller.applyGammaScale(
      assumingLinearBaseline: 0.5, on: Self.virtualID, enforcerOn: Self.virtualID
    )

    #expect(landed)
    #expect(driver.writes.count == 1)
    #expect(driver.writes.first?.target == Self.virtualID)
    #expect(
      driver.writes.first?.samples == GammaSamples.linear(count: Self.sampleCount).scaled(by: 0.5)
    )
  }

  /// The panel leg must NOT acquire the fallback. A display whose real table
  /// could not be read still has a colour profile, and writing a straight ramp
  /// over it would flatten that profile while reporting success: the honest
  /// refusal is the whole reason this leg returns a `Bool`.
  @Test func theOrdinaryLegStillRefusesADisplayWhoseBaselineCannotBeCaptured() {
    let driver = StubGammaDriver()
    driver.screens = [Self.panelID]
    let controller = GammaController(driver: driver)

    let landed = controller.applyGammaScale(0.5, on: Self.panelID, enforcerOn: Self.panelID)

    #expect(!landed)
    #expect(driver.writes.isEmpty)
  }

  /// The fallback is a last resort, not a shortcut: a display that DOES report
  /// its table is scaled against that table on both legs, so a real profile
  /// curve survives the companion write as well as the panel write.
  @Test func aCapturedBaselineIsUsedByBothLegs() {
    let driver = StubGammaDriver()
    driver.screens = [Self.panelID]
    driver.tables[Self.panelID] = Self.profileTable()
    let controller = GammaController(driver: driver)

    controller.applyGammaScale(0.5, on: Self.panelID, enforcerOn: Self.panelID)
    controller.applyGammaScale(
      assumingLinearBaseline: 0.5, on: Self.panelID, enforcerOn: Self.panelID
    )

    let expected = Self.profileTable().scaled(by: 0.5)
    #expect(driver.writes.count == 2)
    #expect(driver.writes.allSatisfy { $0.samples == expected })
  }

  /// The enforcer rule is unchanged on the new leg: no screen, no write, and the
  /// refusal is reported rather than recorded as applied.
  @Test func theCompanionLegStillRefusesWhenTheEnforcerHasNoScreen() {
    let driver = StubGammaDriver()
    let controller = GammaController(driver: driver)

    let landed = controller.applyGammaScale(
      assumingLinearBaseline: 0.5, on: Self.virtualID, enforcerOn: Self.virtualID
    )

    #expect(!landed)
    #expect(driver.writes.isEmpty)
  }

  /// A display written only through the assumed-baseline leg has no captured
  /// reference for a readback to compare against. It must read as intact, or the
  /// engine drives the shade fallback on a display whose gamma nobody touched.
  @Test func aDisplayWithNoCapturedBaselineReadsAsIntact() {
    let driver = StubGammaDriver()
    driver.screens = [Self.virtualID]
    let controller = GammaController(driver: driver)

    controller.applyGammaScale(
      assumingLinearBaseline: 0.5, on: Self.virtualID, enforcerOn: Self.virtualID
    )

    #expect(controller.verifyTableIntact(on: Self.virtualID))
  }
}
