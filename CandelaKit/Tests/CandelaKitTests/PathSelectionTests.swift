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
  private(set) var repinCount = 0

  @discardableResult
  func setShadeAlpha(_ alpha: Double, on displayID: CGDirectDisplayID) -> Bool {
    alphaCalls.append((alpha, displayID))
    return true
  }

  func removeShade(for displayID: CGDirectDisplayID) { removed.append(displayID) }
  func removeAllShades() {}
  func repinFrames() { repinCount += 1 }
}

@MainActor
final class FakeGamma: GammaApplying {
  private(set) var scales: [Double] = []
  private(set) var recaptured: [CGDirectDisplayID] = []

  @discardableResult
  func applyGammaScale(
    _ scale: Double, on _: CGDirectDisplayID, enforcerOn _: CGDirectDisplayID
  ) -> Bool {
    scales.append(scale)
    return true
  }

  func verifyTableIntact(on _: CGDirectDisplayID) -> Bool { true }
  func recaptureDefaultTable(on displayID: CGDirectDisplayID) { recaptured.append(displayID) }
  func resetAllGamma() {}
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
  let defaults: UserDefaults
  let prefs: DisplayPrefs
  let controller: BrightnessController
  private(set) var submitted: [HardwareTarget] = []

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
    defaults = InMemoryDefaults()
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
    // `prime()` is itself a native entry (HDR already live at init), so it
    // asserts the restored value first — hardware round 1's H3.
    #expect(h.submitted == [.native(1.0), .native(0.75)])
    await h.controller.waitForPendingWrites()
    // Landed targets: the coalescer may drop the entry assert (latest-wins),
    // so assert the path, not the count.
    #expect(h.native.targets().last == .native(0.75))
    #expect(h.native.targets().allSatisfy { if case .native = $0 { true } else { false } })
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

  /// #83. `.off` must DISENGAGE HDR that Candela never engaged. The engage arm
  /// already handles the mirror case (an externally live HDR with mode `.off`);
  /// the exit assumed Candela set it, so `mode != previous` returned early and
  /// nothing could drop HDR from inside the app. Ruling: Candela and System
  /// Settings stay in sync, so `.off` means the display leaves HDR whoever put
  /// it there.
  @Test func offDisengagesHDRThatWasEngagedOutsideCandela() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    await h.hdr!.setHDR(displayID: Harness.displayID, enabled: true) // external toggle
    await h.controller.noteHDRStateMayHaveChanged()
    #expect(h.controller.hdrMode == .off) // Candela never set a mode
    #expect(h.controller.isHDREngaged)

    await h.controller.setHDRMode(.off)

    #expect(await h.hdr!.recordedSetCalls() == [true, false])
    #expect(!h.controller.isHDREngaged)
  }

  /// The mirror of the case above, and the one the panel's state-sourced HDR
  /// button (#84) makes reachable: HDR switched off in System Settings leaves a
  /// stale `.alwaysOn`, the button then reads "HDR Off" and offers `.alwaysOn`,
  /// and a mode-only guard would return early and leave that click dead.
  @Test func alwaysOnReEngagesHDRSwitchedOffOutsideCandela() async {
    let h = Harness(hdrEnabled: true, settle: .milliseconds(5)) { prefs, _ in
      prefs.hdrMode = .alwaysOn
    }
    await h.prime()
    await h.hdr!.setHDR(displayID: Harness.displayID, enabled: false) // external
    await h.controller.noteHDRStateMayHaveChanged()
    #expect(!h.controller.isHDREngaged)
    #expect(h.controller.hdrMode == .alwaysOn) // the mode is now stale

    await h.controller.setHDRMode(.alwaysOn)

    #expect(await h.hdr!.recordedSetCalls() == [false, true])
    #expect(h.controller.isHDREngaged)
  }

  /// The early return still has to hold for the case it exists for: `.off` on a
  /// display that is genuinely not in HDR must not run a transition, or every
  /// reset would drive a pointless re-mode across every attached panel.
  @Test func offOnADisplayAlreadyOutOfHDRStaysANoOp() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    await h.controller.setHDRMode(.off)
    #expect(await h.hdr!.recordedSetCalls().isEmpty)
  }

  // MARK: Native-entry brightness assert (hardware round 1)

  /// Entering the native path by an EXTERNAL toggle must re-assert the
  /// published value on the native leg. Hardware round 1: with HDR toggled on
  /// outside the app the MAG came up at the DisplayServices register's leftover
  /// value (0.5 from an earlier probe run) because no entry door pushed.
  @Test func externallyToggledHDREntryReassertsBrightnessOnNativeLeg() async {
    let h = Harness { prefs, _ in prefs.hdrMode = .alwaysOn }
    await h.prime() // HDR off: combined path
    h.controller.setBrightness(0.25)
    await h.hdr!.setHDR(displayID: Harness.displayID, enabled: true) // external toggle
    await h.controller.noteHDRStateMayHaveChanged()
    // Clearing first, assert last — the native leg carries the current value.
    #expect(approx(h.gamma.scales.last ?? -1, 1.0))
    #expect(h.submitted.last == .native(0.25))
    #expect(h.controller.expectedNative().value == 0.25) // echo slot written
  }

  /// The `.alwaysOn` success arm asserts after the settle window: a write
  /// during the ~2 s re-mode is lost, so the assert is the post-settle step.
  @Test func alwaysOnEntryReassertsBrightnessAfterSettle() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    h.controller.setBrightness(0.25)
    await h.controller.setHDRMode(.alwaysOn)
    #expect(h.submitted.last == .native(0.25))
    #expect(h.controller.isNativeActive())
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

  /// HDR Boost removed (Ryder, 2026-07-30): a fresh press at either end of the
  /// range is now just a step. No key path may touch a display's HDR state.
  @Test func stepAtRangeEndsNeverTogglesHDR() async {
    let top = Harness()
    await top.prime()
    top.controller.setBrightness(1.0)
    #expect(top.controller.step(isUp: true, isFine: false) == 1.0)
    #expect(await top.hdr!.recordedSetCalls().isEmpty)
    #expect(top.controller.hdrMode == .off)

    let bottom = Harness(hdrEnabled: true) { prefs, _ in prefs.hdrMode = .alwaysOn }
    await bottom.prime()
    bottom.controller.setBrightness(0.0)
    #expect(bottom.controller.step(isUp: false, isFine: false) == 0.0)
    #expect(await bottom.hdr!.recordedSetCalls().isEmpty)
    #expect(bottom.controller.hdrMode == .alwaysOn)
  }
}

// MARK: - Settings re-apply (D28)

@MainActor
@Suite("Re-apply after a pref change")
struct ReapplyAfterPrefChangeTests {
  @Test func leavingCombinedModeRewritesTheDDCLegAndHandsBackTheGammaTable() async {
    // The bug this exists to prevent: `handleReconfigure` re-runs the SOFTWARE
    // leg only and returns early in pure-DDC mode, so toggling combined
    // dimming off at 40% left the register at its combined floor with the
    // gamma table still scaled — near-black, surviving menu cycles until a
    // replug.
    let h = Harness()
    h.controller.setBrightness(0.4)
    // combined, s = 0.5: ddc portion 0 -> raw 0; sw 0.8 -> gamma 0.8*0.85+0.15
    #expect(h.submitted == [.ddc(raw: 0)])
    #expect(h.gamma.scales.count == 1 && approx(h.gamma.scales[0], 0.83))

    h.prefs.disableCombinedBrightness = true
    h.controller.reapplyAfterPrefChange()

    // Pure DDC now: full-range raw 40, and NO software leg at all — so the
    // gamma table goes back to the OS baseline.
    #expect(h.submitted == [.ddc(raw: 0), .ddc(raw: 40)])
    #expect(h.gamma.scales.count == 2 && approx(h.gamma.scales[1], 1.0))
    #expect(h.controller.brightness == 0.4) // D4: the value is preserved, never slammed to 1.0
  }

  @Test func switchingSoftwareBackendTearsDownTheAbandonedOne() async {
    // `applySoftware` writes ONE backend and never clears the other, so
    // toggling `avoidGamma` used to leave the gamma table scaled while the
    // shade also dimmed — the display dropped to roughly the product.
    let h = Harness { prefs, _ in prefs.forceSoftware = true }
    h.controller.setBrightness(0.4)
    #expect(h.gamma.scales.count == 1 && approx(h.gamma.scales[0], 0.49)) // 0.4*0.85+0.15
    #expect(h.shade.alphaCalls.isEmpty)

    h.prefs.avoidGamma = true
    h.controller.reapplyAfterPrefChange()

    // Teardown runs BEFORE the re-apply (guaranteed by construction in
    // `reapplyAfterPrefChange`), so the gamma table is neutral by the time the
    // shade takes over — no double-dim, no lurch.
    #expect(h.gamma.scales.count == 2 && approx(h.gamma.scales[1], 1.0))
    #expect(h.shade.alphaCalls.count == 1)
    #expect(approx(h.shade.alphaCalls[0].alpha, DimmingMath.shadeAlpha(fromValue: 0.49)))
    #expect(h.shade.removed.isEmpty) // the CHOSEN backend is never torn down

    // ...and back the other way: the shade is removed, gamma resumes.
    h.prefs.avoidGamma = false
    h.controller.reapplyAfterPrefChange()
    #expect(h.shade.removed == [Harness.displayID])
    #expect(h.gamma.scales.count == 3 && approx(h.gamma.scales[2], 0.49))
  }

  @Test func anUnchangedDDCTargetStillReachesTheWire() async {
    // A tuning edit can leave the raw target identical (e.g. re-applying after
    // a pref that only affects the software leg). Without the duplicate-memo
    // reset the coalescer suppresses it and the "re-apply" does nothing.
    let h = Harness { _, defaults in defaults.set(true, forKey: "disableCombinedBrightness") }
    h.controller.setBrightness(0.4)
    await h.controller.waitForPendingWrites()
    #expect(await h.ddc.recordedWrites().count == 1)

    h.controller.reapplyAfterPrefChange()
    await h.controller.waitForPendingWrites()
    let writes = await h.ddc.recordedWrites()
    #expect(writes.count == 2)
    #expect(writes.allSatisfy { $0.command == VCP.brightness && $0.value == 40 })
  }

  @Test func minAndMaxOverridesTakeEffectWithoutTouchingTheSlider() async {
    // The tuning grid's whole point: an override must move the hardware NOW,
    // not on the user's next drag.
    let h = Harness { _, defaults in defaults.set(true, forKey: "disableCombinedBrightness") }
    h.controller.setBrightness(1.0)
    #expect(h.submitted == [.ddc(raw: 100)])

    var tuning = h.prefs.tuning(for: .brightness)
    tuning.maxDDCOverride = 80
    h.prefs.setTuning(tuning, for: .brightness)
    h.controller.reapplyAfterPrefChange()
    #expect(h.submitted == [.ddc(raw: 100), .ddc(raw: 80)])
  }

  @Test func underTheNativePathTheSoftwareLegIsClearedAndNoDDCIsWritten() async {
    let h = Harness(hdrEnabled: true) { prefs, _ in prefs.hdrMode = .alwaysOn }
    await h.prime()
    h.controller.setBrightness(0.75)
    h.controller.reapplyAfterPrefChange()
    #expect(h.submitted.last == .native(0.75))
    #expect(h.submitted.allSatisfy { if case .native = $0 { true } else { false } })
    await h.controller.waitForPendingWrites()
    #expect(await h.ddc.recordedWrites().isEmpty) // DDC is dead under HDR
    #expect(h.shade.removed.contains(Harness.displayID))
    #expect(h.gamma.scales.last == 1.0)
  }

  @Test func aDisabledBrightnessCommandWritesNoDDCButStillFixesTheSoftwareLeg() async {
    // `unavailableDDC.brightness` routes to `BrightnessPath.softwareOnly`: no
    // register write, software leg only — and on the COMBINED SPLIT value, not
    // the raw one, which is what the 0.83 below pins. (It used to route through
    // an `if !tuning.unavailableDDC` guard inside the combined branch; ruling
    // R-A gave the state its own case. The BEHAVIOUR asserted here is
    // unchanged — that is the point of the row.)
    let h = Harness()
    h.controller.setBrightness(0.4)
    #expect(h.submitted == [.ddc(raw: 0)])

    var tuning = h.prefs.tuning(for: .brightness)
    tuning.unavailableDDC = true
    h.prefs.setTuning(tuning, for: .brightness)
    h.controller.reapplyAfterPrefChange()

    #expect(h.submitted == [.ddc(raw: 0)]) // nothing new on the wire
    #expect(h.gamma.scales.count == 2 && approx(h.gamma.scales[1], 0.83)) // re-asserted
  }

  /// The corner where combined mode has BOTH legs dead: the brightness
  /// command's DDC leg is turned off AND the switching point is −8, so
  /// `combinedSplit`'s hardware branch always wins and the software band has
  /// zero width. Nothing moves the display at all.
  ///
  /// This is state (B) of the collapse recorded on
  /// `BrightnessController.softwareBackendChoice`. Before path selection moved
  /// into `BrightnessPathPolicy` it answered `.gamma` here and re-applied
  /// `sw == 1`; it now answers `.none` and tears the backend down instead.
  /// Pinned because the two are equivalent only by arithmetic —
  /// `swTransform(1, allowZero: false) == 1` — and an arithmetic coincidence
  /// nobody asserts is a regression waiting for the next reader who
  /// "simplifies" one side of it.
  @Test func combinedWithDDCOffAndAZeroWidthBandLeavesNoDimmingBehind() {
    let h = Harness { prefs, _ in
      prefs.combinedSwitchingPoint = -8 // s == 0: the software band has no width
      var tuning = prefs.tuning(for: .brightness)
      tuning.unavailableDDC = true
      prefs.setTuning(tuning, for: .brightness)
    }
    h.controller.setBrightness(0.4)
    #expect(h.submitted.isEmpty) // no register write: the DDC leg is off
    #expect(h.gamma.scales.isEmpty) // and no software write: the band is empty

    h.controller.reapplyAfterPrefChange()
    #expect(h.submitted.isEmpty)
    // The same screen the pre-refactor `applySoftware(1)` produced, reached by
    // the other route: the table is handed back at 1.0 and no shade is drawn.
    #expect(h.gamma.scales == [1.0])
    #expect(h.shade.removed == [Harness.displayID])
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

  @Test func adoptReturnsThePublishedDelta() async {
    let h = Harness()
    h.controller.setBrightness(0.5)
    let generation = h.controller.expectedNative().generation
    let delta = h.controller.adoptExternal(0.9, generation: generation)
    #expect(approx(delta, 0.4 / 3, tolerance: 1e-6))
    #expect(approx(delta, h.controller.brightness - 0.5, tolerance: 1e-9))
  }

  @Test func adoptReturnsTheSnappedDelta() async {
    let h = Harness()
    h.controller.setBrightness(0.5)
    let generation = h.controller.expectedNative().generation
    let delta = h.controller.adoptExternal(0.505, generation: generation)
    #expect(approx(delta, 0.005, tolerance: 1e-9))
  }

  @Test func staleAdoptionReturnsZeroDelta() async {
    let h = Harness()
    h.controller.setBrightness(0.5)
    let generation = h.controller.expectedNative().generation
    let delta = h.controller.adoptExternal(0.9, generation: generation &+ 1)
    #expect(delta == 0)
  }
}

// MARK: - Cross-display sync fan-out (Task 11; fork AppDelegate.swift:238-253)

@MainActor
@Suite("Brightness sync fan-out")
struct BrightnessSyncTests {
  /// Source + a combined-path external + a built-in, mirroring the app's
  /// `displays + [builtIn]` iteration.
  private func makeTrio() -> (source: Harness, external: Harness, builtIn: Harness) {
    (
      Harness(),
      Harness(),
      Harness(withHDR: false, role: .builtIn, readNative: { _ in 0.6 })
    )
  }

  @Test func deltaStepsEveryOtherControllerWhenSyncIsOn() async {
    let (source, external, builtIn) = makeTrio()
    source.controller.setBrightness(0.5)
    external.controller.setBrightness(0.75)
    builtIn.controller.setBrightness(0.6)
    let controllers = [source.controller, external.controller, builtIn.controller]

    BrightnessSync.fanOut(delta: 0.05, from: source.controller, to: controllers, isEnabled: true)

    #expect(source.controller.brightness == 0.5) // never steps itself
    #expect(approx(external.controller.brightness, 0.8))
    #expect(approx(builtIn.controller.brightness, 0.65))
  }

  @Test func syncOffStepsNoOne() async {
    let (source, external, builtIn) = makeTrio()
    source.controller.setBrightness(0.5)
    external.controller.setBrightness(0.75)
    builtIn.controller.setBrightness(0.6)

    BrightnessSync.fanOut(
      delta: 0.05,
      from: source.controller,
      to: [source.controller, external.controller, builtIn.controller],
      isEnabled: false
    )

    #expect(external.controller.brightness == 0.75)
    #expect(builtIn.controller.brightness == 0.6)
  }

  @Test func zeroDeltaStepsNoOne() async {
    let (source, external, builtIn) = makeTrio()
    external.controller.setBrightness(0.75)
    builtIn.controller.setBrightness(0.6)

    BrightnessSync.fanOut(
      delta: 0,
      from: source.controller,
      to: [source.controller, external.controller, builtIn.controller],
      isEnabled: true
    )

    #expect(external.controller.brightness == 0.75)
    #expect(builtIn.controller.brightness == 0.6)
  }

  /// Fork-faithful: the replicated step goes through each target's own funnel,
  /// so a combined-path display writes DDC and the built-in writes native.
  @Test func eachTargetAppliesTheStepThroughItsOwnPath() async {
    let (source, external, builtIn) = makeTrio()
    external.controller.setBrightness(0.75)
    builtIn.controller.setBrightness(0.6)
    let externalBefore = external.submitted.count
    let builtInBefore = builtIn.submitted.count

    BrightnessSync.fanOut(
      delta: 0.05,
      from: source.controller,
      to: [source.controller, external.controller, builtIn.controller],
      isEnabled: true
    )

    // 0.8 combined -> (0.8 - 0.5) / 0.5 = 0.6 of the DDC band.
    #expect(external.submitted.count == externalBefore + 1)
    #expect(external.submitted.last == .ddc(raw: 60))
    #expect(builtIn.submitted.count == builtInBefore + 1)
    #expect(builtIn.submitted.last == .native(0.65))
  }

  /// No feedback loop by construction: a native target records the replicated
  /// write in its expected-echo slot, so the poller reads it back as an echo.
  @Test func nativeTargetRecordsTheReplicatedWriteAsAnEcho() async {
    let (source, _, builtIn) = makeTrio()
    builtIn.controller.setBrightness(0.6)
    let before = builtIn.controller.expectedNative().generation

    BrightnessSync.fanOut(
      delta: 0.05,
      from: source.controller,
      to: [source.controller, builtIn.controller],
      isEnabled: true
    )

    let slot = builtIn.controller.expectedNative()
    #expect(slot.value.map { approx($0, 0.65) } == true)
    #expect(slot.generation == before + 1)
  }

  @Test func deltaIsClampedByTheTargetFunnel() async {
    let (source, external, _) = makeTrio()
    external.controller.setBrightness(0.98)

    BrightnessSync.fanOut(
      delta: 0.05,
      from: source.controller,
      to: [source.controller, external.controller],
      isEnabled: true
    )

    #expect(external.controller.brightness == 1.0)
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

  /// The panel's badge reports LIVE HDR, not the mode pref (hardware round 1:
  /// an externally toggled HDR read as "HDR Off" with no badge), so
  /// `isHDREngaged` must follow the cache even while the mode is `.off`.
  @Test func isHDREngagedReflectsLiveHDRRegardlessOfMode() async {
    let live = Harness(hdrEnabled: true) // externally toggled; mode stays .off
    await live.prime()
    #expect(live.controller.hdrMode == .off)
    #expect(live.controller.isHDREngaged)
    let dark = Harness()
    await dark.prime()
    #expect(dark.controller.isHDREngaged == false)
  }

  /// Fix round 2 (Important): `setHDRMode`'s body is a bare async func and the
  /// panel spawns one unserialized Task per mode change, so nothing serializes
  /// overlapping calls but the generation token.
  /// A first `.alwaysOn` call parked on its engage await must NOT, when the
  /// engage finally fails, roll `hdrMode`/`prefs.hdrMode` back to its stale
  /// `previous` or fire `applyPaths` after a second call has retargeted — the
  /// newer transition owns the state.
  ///
  /// With only two modes left, A's `previous` and B's committed mode are both
  /// `.off`, so the submit count carries the assertion: a stale rollback's
  /// `applyPaths` is the observable. (The ABA row below still discriminates on
  /// the mode itself.)
  @Test func overlappingSetHDRModeFailedEngageDoesNotClobberNewerTransition() async {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "t")
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
    // retarget and bail: no extra applyPaths fires against state the newer
    // transition owns.
    await gated.release()
    await first.value
    #expect(controller.hdrMode == .off)
    #expect(prefs.hdrMode == .off)
    #expect(submitted.count == submittedBeforeRelease)
  }

  /// Final wave: the supersession token must be a MONOTONIC GENERATION, not
  /// the mode. `hdrMode` is ABA-prone — a parked `.alwaysOn` call resumes to
  /// find the mode back at `.alwaysOn` after an `.off` → `.alwaysOn` round
  /// trip, so a `hdrMode == mode` comparison waves its stale rollback through
  /// and the THIRD transition's committed mode/prefs are clobbered by the
  /// first's `previous`.
  @Test func overlappingSetHDRModeABADoesNotClobberThirdTransition() async {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "t")
    // Only the FIRST engage is gated (and fails); the third transition's
    // engage passes straight through and succeeds.
    let gated = GatedEngageHDR(gateFirstEngageOnly: true)
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

    // A: commits .alwaysOn, then parks inside the gated engage.
    let first = Task { await controller.setHDRMode(.alwaysOn) }
    #expect(await eventually { await gated.engageCallCount() == 1 })
    #expect(controller.hdrMode == .alwaysOn)

    // B then C: the mode leaves .alwaysOn and comes back — the ABA a mode
    // comparison cannot see. C completes normally (its engage succeeds).
    await controller.setHDRMode(.off)
    await controller.setHDRMode(.alwaysOn)
    #expect(await gated.engageCallCount() == 2)
    #expect(controller.hdrMode == .alwaysOn)
    #expect(prefs.hdrMode == .alwaysOn)
    let submittedBeforeRelease = submitted.count

    // A's engage now fails. Its generation is two transitions stale, so the
    // rollback must not run: C's mode/prefs survive and no applyPaths fires.
    await gated.release()
    await first.value
    #expect(controller.hdrMode == .alwaysOn)
    #expect(prefs.hdrMode == .alwaysOn)
    #expect(submitted.count == submittedBeforeRelease)
  }

  /// Final wave: the EXIT arm has the same bare-async-func exposure as the
  /// engage arm (T10 round 2 flagged it and left it out of scope). A `.off`
  /// transition parked on its disengage must not, once it resumes, clear the
  /// settle flag of the transition that retargeted past it or fire its
  /// `applyPaths` against state that transition owns.
  @Test func overlappingSetHDRModeExitArmDoesNotClobberNewerTransition() async {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "t")
    prefs.hdrMode = .alwaysOn
    let gated = GatedTransitionHDR()
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

    // A: leaves the native path and parks inside the gated disengage.
    let first = Task { await controller.setHDRMode(.off) }
    #expect(await eventually { await gated.disengageCallCount() == 1 })
    #expect(controller.hdrMode == .off)

    // B: retargets back to .alwaysOn and parks inside its own engage, so its
    // settle window is still open (settleInProgress true, poller gate shut)
    // when A resumes.
    let second = Task { await controller.setHDRMode(.alwaysOn) }
    #expect(await eventually { await gated.engageCallCount() == 1 })
    #expect(controller.hdrMode == .alwaysOn)
    #expect(controller.isNativeActive() == false)
    let submittedBeforeRelease = submitted.count

    await gated.releaseDisengage()
    await first.value
    // A's post-sleep block belongs to a superseded transition: no applyPaths,
    // and B's settle flag survives (the fake keeps reporting HDR live, so a
    // stale `settleInProgress = false` + cache refresh would re-open the
    // poller gate mid-transition).
    #expect(submitted.count == submittedBeforeRelease)
    #expect(controller.isNativeActive() == false)

    await gated.releaseEngage()
    await second.value
  }
}

/// HDRToggling fake whose ENGAGE calls (`enabled == true`) suspend until
/// `release()` and then fail; disengage calls pass straight through. Lets a
/// test park one `setHDRMode(.alwaysOn)` mid-engage while another call
/// retargets the controller.
///
/// With `gateFirstEngageOnly`, only the FIRST engage is gated; later engages
/// succeed immediately — that lets a test park one call while two further
/// transitions run to completion (the ABA case).
actor GatedEngageHDR: HDRToggling {
  private var engageWaiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private var engageCalls = 0
  private var enabledState = false
  private let gateFirstEngageOnly: Bool

  init(gateFirstEngageOnly: Bool = false) {
    self.gateFirstEngageOnly = gateFirstEngageOnly
  }

  func supportsHDR(displayID _: CGDirectDisplayID) -> Bool { true }
  func isHDREnabled(displayID _: CGDirectDisplayID) -> Bool { enabledState }

  @discardableResult
  func setHDR(displayID _: CGDirectDisplayID, enabled: Bool) async -> Bool {
    guard enabled else {
      enabledState = false
      return true
    }
    engageCalls += 1
    if gateFirstEngageOnly, engageCalls > 1 {
      enabledState = true
      return true
    }
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

// MARK: - M4 backlog trio (#1, #4, #8)

/// Backlog #1 fixture: fails the first engage, then parks the rollback's
/// `refreshHDRCaches` inside `supportsHDR` so a newer transition can start
/// while the failure arm is suspended.
actor GatedRollbackHDR: HDRToggling {
  private var failNextSet = true
  private var enabled = false
  private var gateArmed = false
  private var parked: CheckedContinuation<Void, Never>?

  func armGate() { gateArmed = true }
  func hasParked() -> Bool { parked != nil }
  func release() {
    parked?.resume()
    parked = nil
  }

  func supportsHDR(displayID _: CGDirectDisplayID) async -> Bool {
    if gateArmed {
      gateArmed = false
      await withCheckedContinuation { parked = $0 }
    }
    return true
  }

  func isHDREnabled(displayID _: CGDirectDisplayID) -> Bool { enabled }

  @discardableResult
  func setHDR(displayID _: CGDirectDisplayID, enabled: Bool) -> Bool {
    if enabled, failNextSet {
      failNextSet = false
      return false
    }
    self.enabled = enabled
    return true
  }

  func displaysReconfigured() {}
}

@MainActor
@Suite("Backlog #1 — engage-failure re-guard")
struct EngageFailureReguardTests {
  @Test func staleRollbackDoesNotReapplyAfterSupersession() async {
    let defaults = InMemoryDefaults()
    let gated = GatedRollbackHDR()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: gated, shade: nil, gamma: nil
      ),
      prefs: DisplayPrefs(defaults: defaults, persistenceKey: "rg"),
      displayID: 11
    )
    controller.settleDelay = .milliseconds(10)
    nonisolated(unsafe) var submitCount = 0
    controller._onSubmit = { _ in submitCount += 1 }
    await controller.initialHDRRefresh?.value

    await gated.armGate()
    let first = Task { await controller.setHDRMode(.alwaysOn) } // engage FAILS → rollback parks in refreshHDRCaches
    #expect(await eventually { await gated.hasParked() })
    #expect(controller.hdrMode == .off) // rollback already committed pre-park

    // A newer transition supersedes the parked rollback and runs to completion.
    await controller.setHDRMode(.alwaysOn)
    #expect(controller.hdrMode == .alwaysOn)
    #expect(controller.isHDREngaged)

    let countBeforeRelease = submitCount
    await gated.release()
    await first.value
    // Without the re-guard, the stale rollback fires one more applyPaths —
    // an extra submit against state the newer transition owns.
    #expect(submitCount == countBeforeRelease)
  }
}

@MainActor
@Suite("Backlog #4 — park-at-s exemption")
struct ParkExemptionTests {
  @Test func forceSoftwareDisplayIsExemptFromParkAtS() {
    // A forceSoftware display's whole [0,1] range is the software leg — the
    // quit teardown argument for parking does not apply, and parking silently
    // raises its brightness every launch.
    let h = Harness(seed: [Harness.storageKey: 0.3]) { prefs, _ in prefs.forceSoftware = true }
    #expect(h.controller.brightness == 0.3)
  }

  @Test func combinedDisplayStillParksAtS() {
    let h = Harness(seed: [Harness.storageKey: 0.3])
    #expect(h.controller.brightness == 0.5)
  }
}

@MainActor
@Suite("Backlog #8 — settle skipped when HDR already externally live")
struct AlreadyLiveEngageTests {
  @Test func alwaysOnWithHDRAlreadyLiveSkipsSetHDRAndSettle() async {
    let h = Harness(hdrEnabled: true, settle: .milliseconds(50))
    await h.prime() // mode .off + HDR live: NOT native yet (policy off), no entry work
    await h.controller.setHDRMode(.alwaysOn)
    #expect(h.controller.hdrMode == .alwaysOn)
    #expect(h.controller.isHDREngaged)
    // The already-live door: no redundant setHDR(true), no transition window.
    #expect(await h.hdr?.recordedSetCalls().isEmpty == true)
    #expect(h.controller.isNativeActive())
    // Entry assert fired through applyPaths → a native submit of the current value.
    #expect(h.submitted.last == .native(1.0))
  }

  @Test func alwaysOnWithAStaleLiveCacheFallsThroughToTheRealEngage() async {
    // Concurrency F3 / review R3: the door trusts cachedHDRActive, but the
    // user can toggle HDR off in System Settings and click Always On before
    // the reconfigure-driven cache refresh lands. Committing `.alwaysOn`
    // without engaging (and with no rollback) would persist a lying mode —
    // the door must re-check after refreshHDRCaches and fall through to the
    // normal engage arm.
    let h = Harness(hdrEnabled: true, settle: .milliseconds(10))
    await h.prime() // cache: HDR live
    // External toggle the controller has NOT observed — the cache is now stale.
    await h.hdr?.setHDR(displayID: Harness.displayID, enabled: false)
    await h.controller.setHDRMode(.alwaysOn)
    #expect(h.controller.hdrMode == .alwaysOn)
    #expect(h.controller.isHDREngaged)
    #expect(h.controller.isNativeActive())
    // The fall-through ran the REAL engage: the test's own disable call,
    // then the controller's setHDR(true).
    #expect(await h.hdr?.recordedSetCalls() == [false, true])
  }
}

/// `isHDRSettling` is the settle window's only public reader: OLED care defers
/// dim entry while the display blanks and re-modes. Gated so the "true" half is
/// pinned by the transition being parked, not by a sleep racing an assertion.
@MainActor
@Suite("HDR settle window is publicly readable")
struct HDRSettleAccessorTests {
  @Test func settlingIsTrueDuringATransitionAndFalseAfterIt() async {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "t")
    prefs.hdrMode = .alwaysOn
    let gated = GatedTransitionHDR()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: gated, shade: FakeShade(), gamma: FakeGamma()
      ),
      prefs: prefs,
      displayID: 7
    )
    controller.settleDelay = .milliseconds(5)
    await controller.initialHDRRefresh?.value
    #expect(controller.isHDRSettling == false)

    let exit = Task { await controller.setHDRMode(.off) }
    // Parked inside the disengage: `beginHDRTransition()` has run, so the
    // settle window is open and stays open until the gate is released.
    #expect(await eventually { await gated.disengageCallCount() == 1 })
    #expect(controller.isHDRSettling)

    await gated.releaseDisengage()
    await exit.value
    #expect(controller.isHDRSettling == false)
  }
}

/// HDRToggling fake with an independently released gate on EACH direction, so
/// a test can park an exit transition on its disengage while a later
/// transition parks on its engage (holding its settle window open).
/// `isHDREnabled` stays true throughout — a display whose readback still
/// reports HDR live mid-transition, which is exactly why the settle window
/// exists and what makes a stale `settleInProgress = false` observable through
/// the poller gate.
actor GatedTransitionHDR: HDRToggling {
  private var engageWaiters: [CheckedContinuation<Void, Never>] = []
  private var disengageWaiters: [CheckedContinuation<Void, Never>] = []
  private var engageReleased = false
  private var disengageReleased = false
  private var engageCalls = 0
  private var disengageCalls = 0

  func supportsHDR(displayID _: CGDirectDisplayID) -> Bool { true }
  func isHDREnabled(displayID _: CGDirectDisplayID) -> Bool { true }

  @discardableResult
  func setHDR(displayID _: CGDirectDisplayID, enabled: Bool) async -> Bool {
    if enabled {
      engageCalls += 1
      if !engageReleased {
        await withCheckedContinuation { engageWaiters.append($0) }
      }
    } else {
      disengageCalls += 1
      if !disengageReleased {
        await withCheckedContinuation { disengageWaiters.append($0) }
      }
    }
    return true
  }

  func displaysReconfigured() {}

  func engageCallCount() -> Int { engageCalls }
  func disengageCallCount() -> Int { disengageCalls }

  func releaseEngage() {
    engageReleased = true
    for waiter in engageWaiters { waiter.resume() }
    engageWaiters.removeAll()
  }

  func releaseDisengage() {
    disengageReleased = true
    for waiter in disengageWaiters { waiter.resume() }
    disengageWaiters.removeAll()
  }
}
