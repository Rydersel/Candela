import CoreGraphics
import Foundation
import os
import Testing
@testable import CandelaKit

// MARK: - Fakes

/// Scriptable HDR backend; records every `setHDR` call.
actor FakeHDR: HDRToggling {
  private(set) var setCalls: [Bool] = []
  private var supports: Bool
  private var enabled: Bool
  private var setResult = true

  init(supports: Bool = true, enabled: Bool = false) {
    self.supports = supports
    self.enabled = enabled
  }

  func supportsHDR(displayID _: CGDirectDisplayID) -> Bool { supports }
  func isHDREnabled(displayID _: CGDirectDisplayID) -> Bool { enabled }

  @discardableResult
  func setHDR(displayID _: CGDirectDisplayID, enabled: Bool) -> Bool {
    setCalls.append(enabled)
    if setResult {
      self.enabled = enabled
    }
    return setResult
  }

  func displaysReconfigured() {}

  func stubSetResult(_ value: Bool) { setResult = value }
  func recordedSetCalls() -> [Bool] { setCalls }
}

@MainActor
final class FakeShade: ShadeRendering {
  private(set) var alphaCalls: [(alpha: Double, id: CGDirectDisplayID)] = []
  private(set) var removed: [CGDirectDisplayID] = []
  private(set) var removedAllCount = 0
  private(set) var repinCount = 0

  func setShadeAlpha(_ alpha: Double, on displayID: CGDirectDisplayID) {
    alphaCalls.append((alpha, displayID))
  }

  func removeShade(for displayID: CGDirectDisplayID) { removed.append(displayID) }
  func removeAllShades() { removedAllCount += 1 }
  func repinFrames() { repinCount += 1 }
}

@MainActor
final class FakeGamma: GammaApplying {
  private(set) var scales: [Double] = []
  private(set) var recaptured: [CGDirectDisplayID] = []
  private(set) var resetCount = 0

  @discardableResult
  func applyGammaScale(_ scale: Double, on _: CGDirectDisplayID) -> Bool {
    scales.append(scale)
    return true
  }

  func verifyTableIntact(on _: CGDirectDisplayID) -> Bool { true }
  func recaptureDefaultTable(on displayID: CGDirectDisplayID) { recaptured.append(displayID) }
  func resetAllGamma() { resetCount += 1 }
}

/// Records every target applied through the native leg (post-coalescing).
/// Copies share the lock's heap storage, so the harness copy observes the
/// controller's writes.
struct FakeNativeApplier: BrightnessApplying {
  private let recorded = OSAllocatedUnfairLock<[HardwareTarget]>(initialState: [])

  func apply(_ target: HardwareTarget) async -> Bool {
    recorded.withLock { $0.append(target) }
    return true
  }

  func targets() -> [HardwareTarget] { recorded.withLock { $0 } }
}

/// In-memory store; tests touch it only from the main actor.
final class PathMemoryStore: BrightnessStoring, @unchecked Sendable {
  var values: [String: Double] = [:]
  func savedBrightness(for key: String) -> Double? { values[key] }
  func saveBrightness(_ value: Double, for key: String) { values[key] = value }
}

// MARK: - Harness

@MainActor
private final class Harness {
  static let displayID: CGDirectDisplayID = 7
  static let storageKey = "combinedBrightness.t"
  static let legacyKey = "brightness.t"

  let ddc: FakeDDC
  let native = FakeNativeApplier()
  let hdr: FakeHDR?
  let shade = FakeShade()
  let gamma = FakeGamma()
  let store = PathMemoryStore()
  // nonisolated(unsafe): accessed from the nonisolated deinit only for
  // cleanup; UserDefaults is documented thread-safe.
  nonisolated(unsafe) let defaults: UserDefaults
  let prefs: DisplayPrefs
  let controller: BrightnessController
  private(set) var submitted: [HardwareTarget] = []
  private nonisolated let suiteName: String

  init(
    ddcRead: (current: UInt16, max: UInt16)? = nil,
    withHDR: Bool = true,
    hdrSupported: Bool = true,
    hdrEnabled: Bool = false,
    settle: Duration = .seconds(2),
    seed: [String: Double] = [:],
    role: DisplayRole = .external,
    configure: (DisplayPrefs, UserDefaults) -> Void = { _, _ in },
    // Last (after the closure) so existing trailing-closure call sites keep
    // matching `configure` under the forward-scan rule.
    readNative: (@Sendable (CGDirectDisplayID) -> Float?)? = nil
  ) {
    suiteName = "com.rydersel.Candela.tests.path.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    prefs = DisplayPrefs(defaults: defaults, persistenceKey: "t")
    ddc = FakeDDC(readResult: ddcRead)
    hdr = withHDR ? FakeHDR(supports: hdrSupported, enabled: hdrEnabled) : nil
    for (key, value) in seed {
      store.values[key] = value
    }
    configure(prefs, defaults)
    controller = BrightnessController(
      writer: ddc,
      backends: BrightnessBackends(
        applierNative: native, hdr: hdr, shade: shade, gamma: gamma, readNative: readNative
      ),
      prefs: prefs,
      displayID: Self.displayID,
      role: role,
      store: store,
      storageKey: Self.storageKey,
      legacyKey: Self.legacyKey
    )
    controller.settleDelay = settle
    controller._onSubmit = { [weak self] target in self?.submitted.append(target) }
  }

  /// Makes the HDR caches deterministic: awaits the init-time refresh first so
  /// it cannot race a second refresh (both seeing `wasNative == false` would
  /// double-run the C1 clearing), then re-reads the fake's current state.
  func prime() async {
    await controller.initialHDRRefresh?.value
    await controller.noteHDRStateMayHaveChanged()
  }

  deinit {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

private func approx(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
  abs(a - b) <= tolerance
}

/// Polls until `condition` holds or ~1 s elapses. The HDR transition task runs
/// on the main actor, so each sleep suspension lets it make progress.
@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
  for _ in 0 ..< 200 {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(5))
  }
  return await condition()
}

// MARK: - Path routing (the 4-row fork contract, s = 0.5 defaults)

@MainActor
@Suite("Path selection")
struct PathSelectionTests {
  @Test func nativePathUnderHDRSubmitsNativeOnly() async {
    let h = Harness(hdrEnabled: true) { prefs, _ in prefs.hdrMode = .alwaysOn }
    await h.prime()
    h.controller.setBrightness(0.75)
    #expect(h.submitted == [.native(0.75)])
    await h.controller.waitForPendingWrites()
    #expect(h.native.targets() == [.native(0.75)])
    #expect(await h.ddc.recordedWrites().isEmpty)
    // The only gamma write is the C1 clearing when the cache flipped active.
    #expect(h.gamma.scales == [1.0])
  }

  @Test func forceSoftwareAppliesSoftwareOnlyFullRange() async {
    let h = Harness { prefs, _ in prefs.forceSoftware = true }
    h.controller.setBrightness(0.75)
    #expect(h.submitted.isEmpty)
    // sw = v = 0.75, transformed 0.75 * 0.85 + 0.15 = 0.7875
    #expect(h.gamma.scales.count == 1 && approx(h.gamma.scales[0], 0.7875))
  }

  @Test func combinedPathSplitsAcrossBothLegs() async {
    let h = Harness()
    h.controller.setBrightness(0.75)
    // (0.75 - 0.5) / 0.5 = 0.5 DDC portion -> raw 50; sw 1 -> gamma 1.0
    #expect(h.submitted == [.ddc(raw: 50)])
    #expect(h.gamma.scales.count == 1 && approx(h.gamma.scales[0], 1.0))
  }

  @Test func combinedDisabledIsPureDDCFullRange() async {
    let h = Harness { _, defaults in defaults.set(true, forKey: "disableCombinedBrightness") }
    h.controller.setBrightness(0.75)
    #expect(h.submitted == [.ddc(raw: 75)])
    #expect(h.gamma.scales.isEmpty)
    #expect(h.shade.alphaCalls.isEmpty)
  }

  @Test func avoidGammaRoutesSoftwareLegThroughShade() async {
    let h = Harness { prefs, _ in prefs.avoidGamma = true }
    h.controller.setBrightness(0.25)
    // sw 0.5 -> transformed 0.575 -> alpha 1 - 0.575^1.5
    let expectedAlpha = 1.0 - pow(0.575, 1.5)
    #expect(h.gamma.scales.isEmpty)
    #expect(h.shade.alphaCalls.count == 1 && approx(h.shade.alphaCalls[0].alpha, expectedAlpha))
    #expect(h.shade.alphaCalls[0].id == Harness.displayID)
  }

  /// Submit-level walk across the boundary (before the coalescer's own
  /// dedupe): every call produces a DDC submit; the sw leg dedupes on the
  /// last-applied value. The memo starts EMPTY on a fresh controller
  /// (in-memory, deliberately not pref-persisted — review M35).
  @Test func combinedBoundaryWalk() async {
    let h = Harness()
    for value in [1.0, 0.75, 0.5, 0.25, 0.0] {
      h.controller.setBrightness(value)
    }
    #expect(h.submitted == [.ddc(raw: 100), .ddc(raw: 50), .ddc(raw: 0), .ddc(raw: 0), .ddc(raw: 0)])
    // sw values 1 (applied), 1 (skip), 1 (skip), 0.5, 0 -> transformed 1.0, 0.575, 0.15
    #expect(h.gamma.scales.count == 3)
    #expect(approx(h.gamma.scales[0], 1.0))
    #expect(approx(h.gamma.scales[1], 0.575))
    #expect(approx(h.gamma.scales[2], 0.15))
  }

  @Test func softwareLegDedupesIdenticalValues() async {
    let h = Harness()
    h.controller.setBrightness(0.25)
    h.controller.setBrightness(0.25)
    #expect(h.gamma.scales.count == 1)
  }

  @Test func preGammaApplyHookFiresOnlyOnNonDeduplicatedGammaApplies() async {
    let h = Harness()
    var hookFires = 0
    h.controller.preGammaApplyHook = { hookFires += 1 }
    h.controller.setBrightness(0.25)
    h.controller.setBrightness(0.25) // deduped: no hook
    #expect(hookFires == 1)
    let shaded = Harness { prefs, _ in prefs.avoidGamma = true }
    var shadeHookFires = 0
    shaded.controller.preGammaApplyHook = { shadeHookFires += 1 }
    shaded.controller.setBrightness(0.25) // shade backend: no hook
    #expect(shadeHookFires == 0)
  }

  // MARK: C1 — native-entry clearing (MUST-HAVE)

  @Test func enteringAlwaysOnClearsSoftwareLegAndInvalidatesMemo() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    h.controller.setBrightness(0.25) // gamma dim active (0.575)
    #expect(h.gamma.scales.count == 1 && approx(h.gamma.scales[0], 0.575))
    await h.controller.setHDRMode(.alwaysOn)
    // C1: shade removed, gamma restored to 1.0.
    #expect(h.shade.removed.contains(Harness.displayID))
    #expect(approx(h.gamma.scales.last ?? -1, 1.0))
    let scalesAfterEntry = h.gamma.scales.count
    // Under HDR, brightness routes native with no software apply.
    h.controller.setBrightness(0.25)
    #expect(h.submitted.last == .native(0.25))
    #expect(h.gamma.scales.count == scalesAfterEntry)
    // Memo was invalidated at entry: after leaving HDR the same sw value
    // re-applies instead of being dedupe-skipped (the recovery C1 protects).
    await h.controller.setHDRMode(.off)
    #expect(approx(h.gamma.scales.last ?? -1, 0.575))
    #expect(await h.hdr!.recordedSetCalls() == [true, false])
  }

  /// Fix round 1, minor 3: the fourth door into the native path —
  /// `.off → .boost` while HDR is already externally live — must run the C1
  /// clearing too, or a stale scaled gamma table lingers installed under HDR.
  @Test func enteringBoostWithExternallyLiveHDRRunsNativeEntryClearing() async {
    let h = Harness(hdrEnabled: true) // hdrMode .off: external HDR, not native
    await h.prime()
    h.controller.setBrightness(0.25) // combined path: gamma dim active
    #expect(approx(h.gamma.scales.last ?? -1, 0.575))
    await h.controller.setHDRMode(.boost)
    #expect(approx(h.gamma.scales.last ?? -1, 1.0))
    #expect(h.shade.removed.contains(Harness.displayID))
  }

  @Test func externallyToggledHDRRunsNativeEntryClearing() async {
    let h = Harness { prefs, _ in prefs.hdrMode = .alwaysOn }
    await h.prime() // HDR off: combined path
    h.controller.setBrightness(0.25)
    #expect(h.gamma.scales.count == 1 && approx(h.gamma.scales[0], 0.575))
    await h.hdr!.setHDR(displayID: Harness.displayID, enabled: true) // external toggle
    await h.controller.noteHDRStateMayHaveChanged()
    #expect(approx(h.gamma.scales.last ?? -1, 1.0))
    #expect(h.shade.removed.contains(Harness.displayID))
  }

  // MARK: C2 — refreshFromHardware combined-domain mapping (MUST-HAVE)

  @Test func refreshMapsReadableDDCIntoCombinedDomain() async {
    let h = Harness(ddcRead: (current: 50, max: 100))
    await h.controller.refreshFromHardware()
    // v = s + (current/max)(1 - s) = 0.5 + 0.5 * 0.5 = 0.75
    #expect(approx(h.controller.brightness, 0.75))
    #expect(approx(h.store.values[Harness.storageKey] ?? -1, 0.75))
  }

  @Test func refreshKeepsSavedValueOnDDCZero() async {
    let h = Harness(ddcRead: (current: 0, max: 100))
    h.controller.setBrightness(0.3)
    await h.controller.refreshFromHardware()
    // DDC 0 is consistent with any software-zone value: keep the saved 0.3.
    #expect(approx(h.controller.brightness, 0.3))
    #expect(approx(h.store.values[Harness.storageKey] ?? -1, 0.3))
  }

  @Test func refreshAdoptsRawWhenCombinedDisabled() async {
    let h = Harness(ddcRead: (current: 50, max: 100)) { _, defaults in
      defaults.set(true, forKey: "disableCombinedBrightness")
    }
    await h.controller.refreshFromHardware()
    #expect(approx(h.controller.brightness, 0.5))
  }

  // MARK: Reconfigure

  @Test func reconfigureRecapturesAndReappliesSoftwareLeg() async {
    let h = Harness()
    h.controller.setBrightness(0.25)
    #expect(h.gamma.scales.count == 1)
    await h.controller.handleReconfigure()
    #expect(h.gamma.recaptured == [Harness.displayID])
    #expect(h.shade.repinCount == 1)
    // Memo invalidated + re-applied: same 0.575 lands again.
    #expect(h.gamma.scales.count == 2 && approx(h.gamma.scales[1], 0.575))
  }

  @Test func reconfigureSkipsSoftwareLegWhenNativeActive() async {
    let h = Harness(hdrEnabled: true) { prefs, _ in prefs.hdrMode = .alwaysOn }
    await h.prime()
    let scalesBefore = h.gamma.scales.count
    await h.controller.handleReconfigure()
    #expect(h.gamma.recaptured == [Harness.displayID])
    #expect(h.gamma.scales.count == scalesBefore) // no re-apply under native (C1)
  }

  // MARK: separateCombinedScale stepping (M39)

  @Test func separateCombinedScaleUsesCombinedChicletMath() async {
    let h = Harness { _, defaults in defaults.set(true, forKey: "separateCombinedScale") }
    h.controller.setBrightness(0.75)
    #expect(h.controller.step(isUp: false, isFine: false) == 0.71875)
  }

  @Test func plainStepKeepsM2ChicletMathOnCombinedPath() async {
    let h = Harness()
    h.controller.setBrightness(0.75)
    #expect(h.controller.step(isUp: false, isFine: false) == 0.6875) // M2 16-chiclet math
  }
}

// MARK: - HDR boost state machine

@MainActor
@Suite("HDR boost")
struct HDRBoostTests {
  @Test func engageFromFullBrightnessOnFreshPressUp() async {
    let h = Harness { prefs, _ in prefs.hdrMode = .boost }
    await h.prime()
    h.controller.setBrightness(1.0)
    let submittedBefore = h.submitted.count
    let returned = h.controller.step(isUp: true, isFine: false, isFresh: true)
    #expect(returned == 1.0)
    // I8: optimistic cache flip — the engaging press's HUD reads boost active.
    #expect(h.controller.hdrBoostActive)
    // I15: native-active only after the settle window (2 s default here).
    #expect(h.controller.isNativeActive() == false)
    // Expected-native slot written at press time.
    #expect(h.controller.expectedNative().value == 1.0)
    // No immediate hardware submit: the .native(1) re-assert is settle-deferred.
    #expect(h.submitted.count == submittedBefore)
    #expect(await eventually { await h.hdr!.recordedSetCalls() == [true] })
  }

  @Test func engageCompletesAfterSettle() async {
    let h = Harness(settle: .milliseconds(10)) { prefs, _ in prefs.hdrMode = .boost }
    await h.prime()
    h.controller.setBrightness(1.0)
    h.controller.step(isUp: true, isFine: false, isFresh: true)
    await h.controller.hdrTransitionTask?.value
    #expect(h.controller.isNativeActive())
    #expect(h.submitted.last == .native(1.0))
    #expect(h.controller.hdrBoostActive)
  }

  /// Fix round 1, important 1: a new HDR transition supersedes any in-flight
  /// settle task. Without the cancel, the orphaned engage task clears
  /// `settleInProgress` mid-exit-window and fires its deferred `.native(1.0)`
  /// after the state machine has already left the native path.
  @Test func exitBeforeSettleCancelsEngageTaskAndItsDeferredSubmit() async {
    let h = Harness { prefs, _ in prefs.hdrMode = .boost } // settle: 2 s default
    await h.prime()
    h.controller.setBrightness(1.0)
    h.controller.step(isUp: true, isFine: false, isFresh: true) // engage
    // Let the engage task finish its pre-settle phase (setHDR(true)) so the
    // stray submit could only be stopped by cancellation, not by luck.
    #expect(await eventually { await h.hdr!.recordedSetCalls() == [true] })
    h.controller.settleDelay = .milliseconds(10)
    await h.controller.setHDRMode(.off) // exits boost-engaged; supersedes the settle
    await h.controller.hdrTransitionTask?.value
    try? await Task.sleep(for: .milliseconds(50)) // give a stray task time to misfire
    #expect(!h.submitted.contains(.native(1.0)))
    #expect(h.controller.isNativeActive() == false)
    #expect(h.submitted.last == .ddc(raw: 100)) // exit re-applied via the normal path
  }

  @Test func keyRepeatNeverEngages() async {
    let h = Harness { prefs, _ in prefs.hdrMode = .boost }
    await h.prime()
    h.controller.setBrightness(1.0)
    _ = h.controller.step(isUp: true, isFine: false, isFresh: false)
    #expect(await h.hdr!.recordedSetCalls().isEmpty)
    #expect(h.controller.hdrBoostActive == false)
  }

  @Test func upBelowFullStepsNormally() async {
    let h = Harness { prefs, _ in prefs.hdrMode = .boost }
    await h.prime()
    h.controller.setBrightness(0.5)
    #expect(h.controller.step(isUp: true, isFine: false, isFresh: true) == 0.5625)
    #expect(await h.hdr!.recordedSetCalls().isEmpty)
  }

  @Test func engageRevertsWhenSetHDRFails() async {
    let h = Harness(settle: .milliseconds(5)) { prefs, _ in prefs.hdrMode = .boost }
    await h.prime()
    await h.hdr!.stubSetResult(false)
    h.controller.setBrightness(1.0)
    h.controller.step(isUp: true, isFine: false, isFresh: true)
    await h.controller.hdrTransitionTask?.value
    #expect(h.controller.hdrBoostActive == false)
    #expect(h.controller.isNativeActive() == false)
  }

  @Test func disengageAtZeroOnFreshPressDown() async {
    let h = Harness(hdrEnabled: true) { prefs, _ in prefs.hdrMode = .boost }
    await h.prime()
    h.controller.setBrightness(0.0) // native path: .native(0)
    let submittedBefore = h.submitted.count
    let resetsBefore = h.controller._duplicateResetCount()
    let returned = h.controller.step(isUp: false, isFine: false, isFresh: true)
    #expect(returned == 1.0)
    #expect(h.controller.brightness == 1.0)
    #expect(h.store.values[Harness.storageKey] == 1.0)
    // I10: hardware left HDR at its own level — the duplicate memo was reset.
    #expect(h.controller._duplicateResetCount() == resetsBefore + 1)
    // The DDC re-assert is settle-deferred: no immediate hardware submit.
    #expect(h.submitted.count == submittedBefore)
    #expect(await eventually { await h.hdr!.recordedSetCalls() == [false] })
  }

  @Test func keyRepeatAtZeroNeverDisengages() async {
    let h = Harness(hdrEnabled: true) { prefs, _ in prefs.hdrMode = .boost }
    await h.prime()
    h.controller.setBrightness(0.0)
    _ = h.controller.step(isUp: false, isFine: false, isFresh: false)
    #expect(h.controller.brightness == 0.0)
    #expect(await h.hdr!.recordedSetCalls().isEmpty)
  }

  @Test func disengageReassertsThroughNormalPathAfterSettle() async {
    let h = Harness(hdrEnabled: true, settle: .milliseconds(10)) { prefs, _ in prefs.hdrMode = .boost }
    await h.prime()
    h.controller.setBrightness(0.0)
    h.controller.step(isUp: false, isFine: false, isFresh: true)
    await h.controller.hdrTransitionTask?.value
    // Back on the combined path at 1.0: DDC raw 100.
    #expect(h.submitted.last == .ddc(raw: 100))
    #expect(h.controller.isNativeActive() == false)
  }
}

// MARK: - External adoption (echo slot, Task 7 contract)

@MainActor
@Suite("External adoption")
struct ExternalAdoptionTests {
  @Test func adoptEasesAsymptoticallyAndUpdatesSlot() async {
    let h = Harness()
    h.controller.setBrightness(0.5)
    let submittedBefore = h.submitted.count
    let generation = h.controller.expectedNative().generation
    h.controller.adoptExternal(0.9, generation: generation)
    // 0.5 + (0.9 - 0.5) / 3
    #expect(approx(h.controller.brightness, 0.5 + 0.4 / 3, tolerance: 1e-6))
    #expect(approx(h.store.values[Harness.storageKey] ?? -1, h.controller.brightness))
    #expect(h.controller.expectedNative().value == h.controller.brightness)
    #expect(h.controller.isConvergingFromExternal())
    // Adoption never submits hardware writes.
    #expect(h.submitted.count == submittedBefore)
    #expect(h.native.targets().isEmpty)
  }

  @Test func adoptSnapsWithinTolerance() async {
    let h = Harness()
    h.controller.setBrightness(0.5)
    let generation = h.controller.expectedNative().generation
    h.controller.adoptExternal(0.505, generation: generation)
    #expect(h.controller.brightness == 0.505)
    #expect(h.controller.isConvergingFromExternal() == false)
  }

  @Test func staleGenerationIsDiscardedEntirely() async {
    let h = Harness()
    h.controller.setBrightness(0.5)
    let generation = h.controller.expectedNative().generation
    h.controller.adoptExternal(0.9, generation: generation &+ 1)
    #expect(h.controller.brightness == 0.5)
    #expect(h.controller.expectedNative().value == nil)
    #expect(h.controller.isConvergingFromExternal() == false)
  }

  @Test func localNativeWriteBumpsGeneration() async {
    let h = Harness(hdrEnabled: true) { prefs, _ in prefs.hdrMode = .alwaysOn }
    await h.prime()
    let before = h.controller.expectedNative().generation
    h.controller.setBrightness(0.6)
    let after = h.controller.expectedNative()
    #expect(after.generation == before + 1)
    #expect(after.value == 0.6)
  }
}

// MARK: - Migration + first run (scope decision 4; I12/I13)

@MainActor
@Suite("Migration and first run")
struct MigrationTests {
  @Test func migratesLegacyKeyIntoCombinedDomain() async {
    let h = Harness(seed: [Harness.legacyKey: 0.6])
    // s + old * (1 - s) = 0.5 + 0.6 * 0.5 = 0.8, written to the M3 key once.
    #expect(approx(h.controller.brightness, 0.8))
    #expect(approx(h.store.values[Harness.storageKey] ?? -1, 0.8))
    #expect(h.store.values[Harness.legacyKey] == 0.6) // legacy key left, ignored
  }

  @Test func combinedKeyWinsOverLegacyKey() async {
    let h = Harness(seed: [Harness.storageKey: 0.7, Harness.legacyKey: 0.2])
    #expect(h.controller.brightness == 0.7)
    #expect(h.store.values[Harness.storageKey] == 0.7) // untouched
  }

  @Test func firstRunInitializesToFullBrightness() async {
    // I13: post-M3 a 0.5 default would mean "hardware minimum"; the fork's
    // fresh-display rule is s + convDDCToValue(100)(1 - s) = 1.0.
    let h = Harness()
    #expect(h.controller.brightness == 1.0)
  }

  @Test func valueBelowSwitchingPointParksAtBoundary() async {
    // I12: the termination hook removes dimming at quit, so a relaunch below
    // s would show un-dimmed glass with a low slider. Publish s; no write.
    let h = Harness(seed: [Harness.storageKey: 0.25])
    #expect(h.controller.brightness == 0.5)
    #expect(h.store.values[Harness.storageKey] == 0.25) // store untouched
  }

  @Test func parkAtBoundaryDoesNotApplyWhenCombinedDisabled() async {
    let h = Harness(seed: [Harness.storageKey: 0.25]) { _, defaults in
      defaults.set(true, forKey: "disableCombinedBrightness")
    }
    #expect(h.controller.brightness == 0.25)
  }
}

// MARK: - Built-in display role (Task 10)

@MainActor
@Suite("Built-in role")
struct BuiltInRoleTests {
  /// Role `.builtIn` short-circuits the four-way fork: ALWAYS the native leg,
  /// regardless of forceSoftware/combined/disableCombined prefs.
  @Test func builtInRoutesNativeRegardlessOfPrefs() async {
    let forced = Harness(role: .builtIn) { prefs, _ in prefs.forceSoftware = true }
    forced.controller.setBrightness(0.6)
    #expect(forced.submitted == [.native(0.6)])
    await forced.controller.waitForPendingWrites()
    #expect(forced.native.targets() == [.native(0.6)])
    #expect(await forced.ddc.recordedWrites().isEmpty)
    #expect(forced.gamma.scales.isEmpty)
    #expect(forced.shade.alphaCalls.isEmpty)

    let pureDDC = Harness(role: .builtIn) { _, defaults in
      defaults.set(true, forKey: "disableCombinedBrightness")
    }
    pureDDC.controller.setBrightness(0.6)
    #expect(pureDDC.submitted == [.native(0.6)])
    #expect(await pureDDC.ddc.recordedWrites().isEmpty)
  }

  /// `step` on the built-in never consults the boost gate: a fresh up-press
  /// at 100% (the external engage row) and a fresh down-press at 0 with HDR
  /// live (the external disengage row) both step normally — the fake
  /// HDRToggling is never called.
  @Test func builtInStepNeverConsultsBoostGate() async {
    let h = Harness(role: .builtIn) { prefs, _ in prefs.hdrMode = .boost }
    await h.prime()
    h.controller.setBrightness(1.0)
    let returned = h.controller.step(isUp: true, isFine: false, isFresh: true)
    #expect(returned == 1.0)
    #expect(h.controller.hdrBoostActive == false)
    #expect(await h.hdr!.recordedSetCalls().isEmpty)

    let low = Harness(hdrEnabled: true, role: .builtIn) { prefs, _ in prefs.hdrMode = .boost }
    await low.prime()
    low.controller.setBrightness(0.0)
    _ = low.controller.step(isUp: false, isFine: false, isFresh: true)
    #expect(low.controller.brightness == 0.0)
    #expect(await low.hdr!.recordedSetCalls().isEmpty)
  }

  /// Re-review T10-C: the migration/first-run/park-at-s block is bypassed
  /// entirely. A native read of 0.3 publishes 0.3 (an external role would
  /// park it at s = 0.5), the seeded store value is ignored, and nothing is
  /// ever written to the store.
  @Test func builtInSeedsFromNativeReadWithoutParkOrStoreWrite() async {
    let h = Harness(seed: [Harness.storageKey: 0.25], role: .builtIn, readNative: { _ in 0.3 })
    #expect(approx(h.controller.brightness, 0.3, tolerance: 1e-6))
    #expect(h.store.values == [Harness.storageKey: 0.25]) // untouched — no store write

    // Legacy-key migration is bypassed too (an external role would write the
    // combined value to the M3 key); with no native read the seed falls back
    // to 1.0.
    let legacy = Harness(seed: [Harness.legacyKey: 0.6], role: .builtIn)
    #expect(legacy.controller.brightness == 1.0)
    #expect(legacy.store.values == [Harness.legacyKey: 0.6])
  }

  /// `refreshFromHardware` reads via the injected `readNative` — never DDC
  /// (the harness's readable DDC (50, 100) would map to 0.75 under the
  /// external combined rule).
  @Test func builtInRefreshFromHardwareAdoptsInjectedNativeRead() async {
    let nativeValue = OSAllocatedUnfairLock<Float?>(initialState: 0.9)
    let h = Harness(
      ddcRead: (current: 50, max: 100), role: .builtIn,
      readNative: { _ in nativeValue.withLock { $0 } }
    )
    #expect(approx(h.controller.brightness, 0.9, tolerance: 1e-6))
    nativeValue.withLock { $0 = 0.42 }
    await h.controller.refreshFromHardware()
    #expect(approx(h.controller.brightness, 0.42, tolerance: 1e-6))
    #expect(h.store.values.isEmpty)
  }

  /// The poller gate is constitutively true for the built-in role — no HDR
  /// settle machinery ever runs, and the native path is always active.
  @Test func builtInIsNativeActiveConstitutively() async {
    let h = Harness(withHDR: false, role: .builtIn)
    #expect(h.controller.isNativeActive())
  }

  /// Re-review T10-D: the public stub writer always fails, so any DDC path
  /// reached by mistake degrades instead of touching hardware.
  @Test func noopDDCWriterAlwaysFails() async {
    let writer = NoopDDCWriter()
    #expect(await writer.write(command: VCP.brightness, value: 50) == false)
    #expect(await writer.read(command: VCP.brightness) == nil)
  }

  /// T10 fix round 1 (minor): `setHDRMode` is role-fenced — a public-API call
  /// on a built-in controller is a full no-op: no pref write under the builtIn
  /// key, no published-mode change, no HDR toggling.
  @Test func setHDRModeOnBuiltInIsNoOp() async {
    let h = Harness(role: .builtIn)
    await h.prime()
    await h.controller.setHDRMode(.alwaysOn)
    #expect(h.controller.hdrMode == .off)
    #expect(h.prefs.hdrMode == .off) // pref never written
    #expect(await h.hdr!.recordedSetCalls().isEmpty)
  }
}

// MARK: - alwaysOn engage failure (T8 carry-over, fixed in T10 round 1)

@MainActor
@Suite("HDR mode engage failure")
struct HDRModeEngageFailureTests {
  /// The `.alwaysOn` arm commits the mode optimistically before engaging; on
  /// `engaged == false` it must roll `hdrMode`/`prefs.hdrMode` back to the
  /// previous mode and re-apply the current value through the normal path —
  /// otherwise a display that can't engage HDR is stranded un-dimmed (the C1
  /// clearing already ran) with a lying `.alwaysOn` persisted across launches.
  @Test func alwaysOnEngageFailureRollsBackModeAndReappliesSoftwareLeg() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    await h.hdr!.stubSetResult(false)
    h.controller.setBrightness(0.25) // combined: gamma dim 0.575 active
    #expect(h.gamma.scales.count == 1 && approx(h.gamma.scales[0], 0.575))
    await h.controller.setHDRMode(.alwaysOn)
    // Mode and pref rolled back to the previous mode.
    #expect(h.controller.hdrMode == .off)
    #expect(h.prefs.hdrMode == .off)
    // C1 clearing ran (1.0), then the rollback re-applied the current value's
    // software leg (0.575 again) — the screen is not stranded un-dimmed.
    #expect(h.gamma.scales.count == 3)
    #expect(approx(h.gamma.scales[1], 1.0))
    #expect(approx(h.gamma.scales[2], 0.575))
    // Back on the combined path: the re-apply also submitted the DDC leg.
    #expect(h.submitted.last == .ddc(raw: 0))
    #expect(h.controller.isNativeActive() == false)
  }

  /// `supportsHDR` mirrors the async-refreshed capability cache (the panel
  /// disables the HDR menu on non-HDR displays with it).
  @Test func supportsHDRReflectsCachedCapability() async {
    let supported = Harness()
    await supported.prime()
    #expect(supported.controller.supportsHDR)
    let unsupported = Harness(hdrSupported: false)
    await unsupported.prime()
    #expect(unsupported.controller.supportsHDR == false)
  }

  /// Fix round 2 (Important): `setHDRMode`'s body is a bare async func — never
  /// stored in `hdrTransitionTask`, so `beginHDRTransition`'s cancel cannot
  /// reach it, and the panel spawns one unserialized Task per menu selection.
  /// A first `.alwaysOn` call parked on its engage await must NOT, when the
  /// engage finally fails, roll `hdrMode`/`prefs.hdrMode` back to its stale
  /// `previous` or fire `applyPaths` after a second call has retargeted — the
  /// newer transition owns the state (the orphaned-continuation clobber class
  /// T6 closed for the boost tasks).
  @Test func overlappingSetHDRModeFailedEngageDoesNotClobberNewerTransition() async {
    let suiteName = "com.rydersel.Candela.tests.path.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "t")
    prefs.hdrMode = .boost // a stale rollback would resurrect this
    let gated = GatedEngageHDR()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: gated, shade: FakeShade(), gamma: FakeGamma()
      ),
      prefs: prefs,
      displayID: 7
    )
    controller.settleDelay = .milliseconds(5)
    var submitted: [HardwareTarget] = []
    controller._onSubmit = { submitted.append($0) }
    await controller.initialHDRRefresh?.value
    controller.setBrightness(0.75)

    // First call commits .alwaysOn, then parks inside the gated engage.
    let first = Task { await controller.setHDRMode(.alwaysOn) }
    #expect(await eventually { await gated.engageCallCount() == 1 })
    #expect(controller.hdrMode == .alwaysOn)

    // Second call retargets while the first is parked (the exit arm's
    // setHDR(false) passes straight through the gate) and now owns the state.
    await controller.setHDRMode(.off)
    #expect(controller.hdrMode == .off)
    let submittedBeforeRelease = submitted.count

    // Let the first call's engage fail. Its rollback must observe the
    // retarget and bail: mode/prefs stay .off (not the stale .boost), and no
    // extra applyPaths fires against state the newer transition owns.
    await gated.release()
    await first.value
    #expect(controller.hdrMode == .off)
    #expect(prefs.hdrMode == .off)
    #expect(submitted.count == submittedBeforeRelease)
  }
}

/// HDRToggling fake whose ENGAGE calls (`enabled == true`) suspend until
/// `release()` and then fail; disengage calls pass straight through. Lets a
/// test park one `setHDRMode(.alwaysOn)` mid-engage while another call
/// retargets the controller.
actor GatedEngageHDR: HDRToggling {
  private var engageWaiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private var engageCalls = 0

  func supportsHDR(displayID _: CGDirectDisplayID) -> Bool { true }
  func isHDREnabled(displayID _: CGDirectDisplayID) -> Bool { false }

  @discardableResult
  func setHDR(displayID _: CGDirectDisplayID, enabled: Bool) async -> Bool {
    guard enabled else { return true }
    engageCalls += 1
    if !released {
      await withCheckedContinuation { engageWaiters.append($0) }
    }
    return false // the gated engage always fails once released
  }

  func displaysReconfigured() {}

  func engageCallCount() -> Int { engageCalls }

  func release() {
    released = true
    for waiter in engageWaiters {
      waiter.resume()
    }
    engageWaiters.removeAll()
  }
}
