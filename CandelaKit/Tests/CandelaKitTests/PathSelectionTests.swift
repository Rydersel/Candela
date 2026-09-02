import CoreGraphics
import Foundation
import os
import Testing
@testable import CandelaKit

// MARK: - Fakes

/// Scriptable HDR backend; records every `setHDR` call.
actor FakeHDR: HDRToggling {
  private(set) var setCalls: [Bool] = []
  private(set) var measuredReads = 0
  private var supports: Bool
  /// The panel itself.
  private var enabled: Bool
  /// What a CACHED read answers, which is a different fact and the whole reason
  /// `measuredHDREnabled` exists: the real backend caches for ~2 s, so a plain
  /// read can describe a display that has since moved. Only a measured read
  /// refreshes this, so a test asking for evidence has to go past the cache to
  /// get it rather than getting it by luck.
  private var cachedEnabled: Bool
  private var setResult = true
  private var achieves = true

  init(supports: Bool = true, enabled: Bool = false) {
    self.supports = supports
    self.enabled = enabled
    self.cachedEnabled = enabled
  }

  func supportsHDR(displayID _: CGDirectDisplayID) -> Bool { supports }
  func isHDREnabled(displayID _: CGDirectDisplayID) -> Bool { cachedEnabled }
  func measuredHDREnabled(displayID _: CGDirectDisplayID) -> Bool {
    measuredReads += 1
    cachedEnabled = enabled
    return enabled
  }

  @discardableResult
  func setHDR(displayID _: CGDirectDisplayID, enabled: Bool) -> Bool {
    setCalls.append(enabled)
    if setResult, achieves {
      self.enabled = enabled
      // A toggle this backend performed is one it knows about.
      cachedEnabled = enabled
    }
    return setResult
  }

  func displaysReconfigured() {}

  func stubSetResult(_ value: Bool) { setResult = value }
  /// The panel's HDR state changes with nothing telling the controller: a
  /// System Settings toggle whose reconfigure has not been delivered yet. The
  /// backend's own cache is deliberately NOT refreshed, because that is the
  /// state being modelled, and it is not reachable through `setHDR`, which this
  /// backend can see.
  func stubEnabled(_ value: Bool) { enabled = value }
  /// The panel that ACCEPTS the write and does not switch. A different fact from
  /// `stubSetResult(false)`, a write that was never issued, and the two were once
  /// indistinguishable to a controller that read only the return value.
  func stubAchieves(_ value: Bool) { achieves = value }
  func recordedSetCalls() -> [Bool] { setCalls }
  func recordedMeasuredReads() -> Int { measuredReads }
}

/// HDR backend whose MEASURED read suspends until released, and whose writes
/// never change the panel: it holds the physical answer at "HDR is off" while a
/// transition starts underneath the call waiting on it. Reproduces the door's two
/// race defects.
actor GatedMeasureHDR: HDRToggling {
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private var measureCalls = 0
  private(set) var setCalls: [Bool] = []

  func supportsHDR(displayID _: CGDirectDisplayID) -> Bool { true }
  func isHDREnabled(displayID _: CGDirectDisplayID) -> Bool { false }

  func measuredHDREnabled(displayID _: CGDirectDisplayID) async -> Bool {
    measureCalls += 1
    if !released {
      await withCheckedContinuation { waiters.append($0) }
    }
    return false
  }

  @discardableResult
  func setHDR(displayID _: CGDirectDisplayID, enabled: Bool) -> Bool {
    setCalls.append(enabled)
    return true
  }

  func displaysReconfigured() {}
  func measureCallCount() -> Int { measureCalls }
  func recordedSetCalls() -> [Bool] { setCalls }

  func release() {
    released = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

/// The interleaving where an exit's drop TAKES and a newer engage supersedes it
/// past a fence and then fails to engage. The disengage takes effect the instant
/// it is issued and only THEN parks, so the panel is out of HDR while the exit is
/// still suspended; engages are never issued (the documented case where the
/// MonitorPanel lock is busy), which is what sends the newer call into its
/// rollback arm.
actor DropTakesThenEngageFailsHDR: HDRToggling {
  private var enabled = true
  private var disengageWaiters: [CheckedContinuation<Void, Never>] = []
  private var disengageReleased = false
  private var disengageCalls = 0

  func supportsHDR(displayID _: CGDirectDisplayID) -> Bool { true }
  func isHDREnabled(displayID _: CGDirectDisplayID) -> Bool { enabled }
  func measuredHDREnabled(displayID _: CGDirectDisplayID) -> Bool { enabled }

  @discardableResult
  func setHDR(displayID _: CGDirectDisplayID, enabled: Bool) async -> Bool {
    guard !enabled else { return false }
    disengageCalls += 1
    self.enabled = false
    if !disengageReleased {
      await withCheckedContinuation { disengageWaiters.append($0) }
    }
    return true
  }

  func displaysReconfigured() {}
  func disengageCallCount() -> Int { disengageCalls }

  func releaseDisengage() {
    disengageReleased = true
    for waiter in disengageWaiters { waiter.resume() }
    disengageWaiters.removeAll()
  }
}

/// Records the one thing a sibling controller is handed to the disengage for.
@MainActor
final class MemoInvalidationRecorder: PendingWireDraining {
  private(set) var memoResets = 0
  func submissionMark() -> UInt64 { 0 }
  func resetWriteMemo() { memoResets += 1 }
  func drainPendingWrites() async -> Bool { true }
}

/// A DDC writer that holds every write until released, and records what the HDR
/// backend had been told at the moment it finally applied one. A shared
/// timeline rather than two independent counters, so "the write landed before
/// the re-engage" is pinned by content and not by scheduling luck.
actor GatedWriter: DDCWriting {
  private var hdr: FakeHDR?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private var applies = 0
  private(set) var setCallsWhenApplied: [Bool]?

  init(hdr: FakeHDR? = nil) { self.hdr = hdr }

  /// For the tests whose backend does not exist yet when the writer does: a
  /// queue that belongs to a controller's wire has to be built before the
  /// controller, and the harness makes the HDR fake with it. The timeline this
  /// records is read at APPLY time and every apply here is gated, so attaching
  /// before the release records the same thing as attaching at init.
  func attach(hdr: FakeHDR) { self.hdr = hdr }

  func write(command _: UInt8, value _: UInt16) async -> Bool {
    applies += 1
    if !released {
      await withCheckedContinuation { waiters.append($0) }
    }
    if let hdr { setCallsWhenApplied = await hdr.recordedSetCalls() }
    return true
  }

  func read(command _: UInt8) async -> (current: UInt16, max: UInt16)? { nil }

  func applyCount() -> Int { applies }

  func release() {
    released = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

/// Records every target applied through the native leg (post-coalescing).
/// Copies share the lock's heap storage, so the harness copy observes the
/// controller's writes.
struct FakeNativeApplier: BrightnessApplying {
  let accepts = HardwareTargetKind.native

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

/// Internal rather than file-private: `ApplierPairingTests` drives the same
/// controller through the same path table, and a second copy of this harness
/// would be a second answer to "how is a controller wired".
@MainActor
final class Harness {
  static let displayID: CGDirectDisplayID = 7
  static let storageKey = "combinedBrightness.t"
  static let legacyKey = "brightness.t"

  let ddc: FakeDDC
  let native = FakeNativeApplier()
  let hdr: FakeHDR?
  let shade = RecordingShade()
  let gamma = RecordingGamma()
  let store = PathMemoryStore()
  let defaults: UserDefaults
  let prefs: DisplayPrefs
  let controller: BrightnessController
  private(set) var submitted: [HardwareTarget] = []
  /// Each submit with the applier that carried it: `submitted` alone cannot see a
  /// target handed to the wrong endpoint.
  private(set) var submittedPairs: [(target: HardwareTarget, applier: any BrightnessApplying)] = []

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
    readNative: (@Sendable (CGDirectDisplayID) -> Float?)? = nil,
    // The other queues on the controller's wire, built from the SAME prefs the
    // controller gets (one prefs object per display), which is why this is
    // a closure and not a list: a real sibling has to exist before the
    // controller does, and it cannot be built before the harness has made the
    // prefs. Empty by default, so only the tests that are about the wire pay it.
    wireSiblings: (DisplayPrefs) -> [any PendingWireDraining] = { _ in [] }
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
      legacyKey: Self.legacyKey,
      wireSiblings: wireSiblings(prefs)
    )
    controller.settleDelay = settle
    controller._onSubmit = { [weak self] target, applier in
      self?.submitted.append(target)
      self?.submittedPairs.append((target, applier))
    }
  }

  /// Makes the HDR caches deterministic: awaits the init-time refresh first so
  /// it cannot race a second refresh (both seeing `wasNative == false` would
  /// double-run the restore-latch clearing), then re-reads the fake's current state.
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

/// The 0x8D traffic a recording writer saw, in order. On a write-only panel
/// which values reached the wire is the whole of the evidence about a mute.
private func muteWrites(_ writer: FakeDDC) async -> [UInt16] {
  await writer.recordedWrites()
    .filter { $0.command == VCP.audioMuteScreenBlank }
    .map(\.value)
}

// MARK: - Path routing (the 4-row fork contract, s = 0.5 defaults)

@MainActor
@Suite("Path selection")
struct PathSelectionTests {
  @Test func nativePathUnderHDRSubmitsNativeOnly() async {
    let h = Harness(hdrEnabled: true) { prefs, _ in prefs.hdrMode = .alwaysOn }
    await h.prime()
    h.controller.setBrightness(0.75)
    // `prime()` is itself a native entry (HDR already live at init), so it asserts
    // the restored value first.
    #expect(h.submitted == [.native(1.0), .native(0.75)])
    await h.controller.waitForPendingWrites()
    // Landed targets: the coalescer may drop the entry assert (latest-wins),
    // so assert the path, not the count.
    #expect(h.native.targets().last == .native(0.75))
    #expect(h.native.targets().allSatisfy { if case .native = $0 { true } else { false } })
    #expect(await h.ddc.recordedWrites().isEmpty)
    // The only gamma write is the restore-latch clearing when the cache flipped active.
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

  /// Submit-level walk across the boundary, before the coalescer's own dedupe:
  /// every call produces a DDC submit, and the sw leg dedupes on the last-applied
  /// value. The memo starts EMPTY on a fresh controller, in memory and deliberately
  /// not pref-persisted.
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

  // MARK: Native-entry clearing (MUST-HAVE)

  @Test func enteringAlwaysOnClearsSoftwareLegAndInvalidatesMemo() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    h.controller.setBrightness(0.25) // gamma dim active (0.575)
    #expect(h.gamma.scales.count == 1 && approx(h.gamma.scales[0], 0.575))
    await h.controller.setHDRMode(.alwaysOn)
    // The restore latch: shade removed, gamma restored to 1.0.
    #expect(h.shade.removed.contains(Harness.displayID))
    #expect(approx(h.gamma.scales.last ?? -1, 1.0))
    let scalesAfterEntry = h.gamma.scales.count
    // Under HDR, brightness routes native with no software apply.
    h.controller.setBrightness(0.25)
    #expect(h.submitted.last == .native(0.25))
    #expect(h.gamma.scales.count == scalesAfterEntry)
    // Memo was invalidated at entry: after leaving HDR the same sw value
    // re-applies instead of being dedupe-skipped (the recovery the restore latch protects).
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

  // MARK: The mirror-HDR exclusion's missing half

  /// A synthesized size is a mirror set standing on this display, and HDR takes
  /// the data cable away. The mirror-HDR exclusion refuses the engage in one direction; this is the
  /// other, and without it the panel ends up in HDR as a mirror slave with the
  /// pairing still up.
  @Test func alwaysOnIsRefusedWhileASynthesizedSizeIsShowing() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    h.controller.isShowingSynthesizedSize = { true }

    await h.controller.setHDRMode(.alwaysOn)

    #expect(await h.hdr!.recordedSetCalls().isEmpty)
    #expect(h.controller.hdrMode == .off)
    #expect(!h.controller.isHDREngaged)

    // The control: the same call on the same harness with nothing engaged.
    // Without it a refusal that fired unconditionally, or an engage arm broken
    // for an unrelated reason, would read identically to the assertion above.
    h.controller.isShowingSynthesizedSize = { false }
    await h.controller.setHDRMode(.alwaysOn)
    #expect(await h.hdr!.recordedSetCalls() == [true])
    #expect(h.controller.isHDREngaged)
  }

  /// The exit is never refused. It is the way OUT of the combination the
  /// refusal exists to prevent, so a size engaged over HDR that arrived from
  /// System Settings must still be droppable from inside the app.
  @Test func offIsNotRefusedWhileASynthesizedSizeIsShowing() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    await h.hdr!.setHDR(displayID: Harness.displayID, enabled: true) // System Settings
    await h.controller.noteHDRStateMayHaveChanged()
    h.controller.isShowingSynthesizedSize = { true }
    #expect(h.controller.isHDREngaged)

    await h.controller.setHDRMode(.off)

    #expect(!h.controller.isHDREngaged)
  }

  /// Refusing a request that would merely RECORD a state System Settings has
  /// already produced would leave the app's mirror lying about a display that
  /// is in HDR. The refusal is about preventing a transition, not about
  /// disagreeing with the hardware.
  @Test func alwaysOnOverAlreadyLiveHDRIsRecordedRatherThanRefused() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    await h.hdr!.setHDR(displayID: Harness.displayID, enabled: true) // System Settings
    await h.controller.noteHDRStateMayHaveChanged()
    h.controller.isShowingSynthesizedSize = { true }
    #expect(h.controller.hdrMode == .off) // Candela never set a mode

    await h.controller.setHDRMode(.alwaysOn)

    #expect(h.controller.hdrMode == .alwaysOn)
    #expect(h.controller.isHDREngaged)
  }

  /// `.off` must DISENGAGE HDR that Candela never engaged. The exit assumed
  /// Candela set it, so `mode != previous` returned early and nothing could drop
  /// HDR from inside the app. Ruling: Candela and System Settings stay in sync, so
  /// `.off` means the display leaves HDR whoever put it there.
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

  /// The mirror of the case above, reachable through the panel's state-sourced HDR
  /// button: HDR switched off in System Settings leaves a stale `.alwaysOn`, the
  /// button then reads "HDR Off" and offers `.alwaysOn`, and a mode-only guard
  /// would return early and leave that click dead.
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

  // MARK: Native-entry brightness assert

  /// Entering the native path by an EXTERNAL toggle must re-assert the published
  /// value on the native leg. Measured: with HDR toggled on outside the app the MAG
  /// came up at the DisplayServices register's leftover value because no entry door
  /// pushed.
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

  // MARK: Committing an engage on the achieved state and not the write

  /// A reported success that was never achieved, in the HDR path: the panel
  /// accepts the write, reports success, and does not switch. Choosing the arm
  /// from `setHDR`'s return persisted `.alwaysOn` across launches on a display
  /// that was never in HDR.
  @Test func anEngageThatIsAcceptedAndDoesNotSwitchRollsTheModeBack() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    await h.hdr!.stubAchieves(false)

    await h.controller.setHDRMode(.alwaysOn)

    #expect(await h.hdr!.recordedSetCalls() == [true], "the write is still issued")
    #expect(h.controller.hdrMode == .off, "the published mirror rolls back")
    #expect(h.prefs.hdrMode == .off, "and so does the pref, or it survives a relaunch")
    #expect(!h.controller.isHDREngaged)
  }

  /// The other half, so the fix cannot be "always roll back": a panel that does
  /// switch still commits.
  @Test func anEngageThatSwitchesStillCommits() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()

    await h.controller.setHDRMode(.alwaysOn)

    #expect(h.controller.hdrMode == .alwaysOn)
    #expect(h.prefs.hdrMode == .alwaysOn)
    #expect(h.controller.isHDREngaged)
  }

  // MARK: Putting back HDR a reset dropped and Candela never owned

  /// The ruling: a reset clears Candela's settings, and HDR the user engaged in
  /// System Settings was never one of them. It goes back, and no mode is
  /// recorded for it, or the reset would end by writing the very kind of thing
  /// it promises to clear.
  @Test func restoringExternalHDRReEngagesWithoutRecordingAMode() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()

    await h.controller.restoreExternalHDR()

    #expect(await h.hdr!.recordedSetCalls() == [true])
    #expect(h.controller.isHDREngaged)
    #expect(h.controller.hdrMode == .off, "the display's state, not Candela's opinion")
    #expect(h.prefs.hdrMode == .off, "and nothing persisted for the next launch")
  }

  /// A restore that does not take leaves the display where the disengage left
  /// it. What must NOT happen is the software leg staying down: the restore-latch clearing
  /// runs for an HDR entry that then did not happen, so without the recovery the
  /// screen sits at full brightness under a low slider.
  @Test func aRestoreThatDoesNotTakeStillGetsTheSoftwareLegBack() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    h.controller.setBrightness(0.25)
    #expect(approx(h.gamma.scales.last ?? -1, 0.575))
    await h.hdr!.stubAchieves(false)

    await h.controller.restoreExternalHDR()

    #expect(!h.controller.isHDREngaged)
    #expect(h.controller.hdrMode == .off)
    #expect(approx(h.gamma.scales.last ?? -1, 0.575), "the dim is back")
  }

  /// The same role fence `setHDRMode` carries: HDR is external-display
  /// machinery, and the built-in is constitutively native already.
  @Test func restoringExternalHDRIsANoOpOnTheBuiltIn() async {
    let h = Harness(settle: .milliseconds(5), role: .builtIn)
    await h.prime()

    await h.controller.restoreExternalHDR()

    #expect(await h.hdr!.recordedSetCalls().isEmpty)
  }

  /// The decision has to be taken from a read that goes past the backend's 2 s
  /// cache. Pinned structurally rather than by timing: the seed's TTL used to
  /// equal `settleDelay`, so the confirmation read sat exactly on the boundary
  /// of the window that would have handed the request back to itself, and a
  /// test written against the clock would pass or fail by scheduling luck.
  @Test func theCommitDecisionReadsPastTheCache() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    let before = await h.hdr!.recordedMeasuredReads()

    await h.controller.setHDRMode(.alwaysOn)

    #expect(await h.hdr!.recordedMeasuredReads() > before)
  }

  // MARK: The reset path's disengage, which answers to the panel and not to the pref

  /// The defect this door exists for. HDR is engaged in System Settings, the
  /// reconfigure that would refresh the mirror has not arrived, and Candela's
  /// stored mode was `.off` all along: every input the mode door consults says
  /// "already off", so it suppresses the transition and the register stays
  /// locked under the reset's own unmute. The reset asks the panel instead.
  @Test func theResetDisengageDropsHDRTheMirrorHasNotNoticedYet() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    await h.hdr!.stubEnabled(true) // System Settings, no reconfigure delivered
    #expect(!h.controller.isHDREngaged, "the mirror is stale, which is the setup")
    #expect(h.controller.hdrMode == .off)

    let outcome = await h.controller.disengageHDRForReset()

    #expect(await h.hdr!.recordedSetCalls() == [false], "the physical drop still went out")
    #expect(!h.controller.isHDREngaged)
    #expect(
      outcome == .disengaged(restoreAfterward: true),
      "the user engaged it elsewhere, so the reset puts it back"
    )
  }

  /// The scoping half: the mode door keeps deciding from what it knows, so
  /// ordinary pref-driven paths are untouched by the reset door's freshness
  /// read. Same stale mirror as above, and the request still evaporates,
  /// leaving no transition behind it either.
  @Test func theModeDoorStillDecidesFromTheMirror() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    await h.hdr!.stubEnabled(true)

    await h.controller.setHDRMode(.off)

    #expect(await h.hdr!.recordedSetCalls().isEmpty)
    #expect(h.controller.hdrMode == .off)
    #expect(!h.controller.isHDRSettling, "no transition was opened, so none is left open")
  }

  /// A reset must not re-mode every attached panel: a display measured out of
  /// HDR takes no transition, and asks for no restore.
  @Test func theResetDisengageIsANoOpOnADisplayThatIsNotInHDR() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()

    let outcome = await h.controller.disengageHDRForReset()

    #expect(await h.hdr!.recordedSetCalls().isEmpty)
    #expect(outcome == .disengaged(restoreAfterward: false))
  }

  /// HDR that Candela engaged is a Candela setting: it goes off, the stored
  /// mode goes with it, and nothing puts it back.
  @Test func theResetDisengageClearsCandelasOwnHDRWithoutRestoringIt() async {
    let h = Harness(hdrEnabled: true, settle: .milliseconds(5)) { prefs, _ in
      prefs.hdrMode = .alwaysOn
    }
    await h.prime()

    let outcome = await h.controller.disengageHDRForReset()

    #expect(await h.hdr!.recordedSetCalls() == [false])
    #expect(outcome == .disengaged(restoreAfterward: false))
    #expect(h.controller.hdrMode == .off)
    #expect(h.prefs.hdrMode == .off, "and it does not come back on the next launch")
  }

  /// A stale `.alwaysOn` over a display that is not in HDR: nothing to drop,
  /// but the reset still clears the opinion it is there to clear.
  @Test func theResetDisengageClearsAStaleAlwaysOnWithoutAReMode() async {
    let h = Harness(settle: .milliseconds(5)) { prefs, _ in prefs.hdrMode = .alwaysOn }
    await h.prime()

    let outcome = await h.controller.disengageHDRForReset()

    #expect(await h.hdr!.recordedSetCalls().isEmpty)
    #expect(outcome == .disengaged(restoreAfterward: false))
    #expect(h.controller.hdrMode == .off)
    #expect(h.prefs.hdrMode == .off)
  }

  /// The decision is taken from a read that goes past the backend's cache, for
  /// the reason every achieved-state check here does: a cached answer filled
  /// during a transition reports that transition's own optimism.
  @Test func theResetDisengageDecidesFromAMeasuredRead() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    let before = await h.hdr!.recordedMeasuredReads()

    _ = await h.controller.disengageHDRForReset()

    #expect(await h.hdr!.recordedMeasuredReads() > before)
  }

  /// HDR machinery is external-display machinery; the built-in is
  /// constitutively native already.
  @Test func theResetDisengageIsANoOpOnTheBuiltIn() async {
    let h = Harness(hdrEnabled: true, settle: .milliseconds(5), role: .builtIn)
    await h.prime()

    let outcome = await h.controller.disengageHDRForReset()

    #expect(await h.hdr!.recordedSetCalls().isEmpty)
    #expect(outcome == .disengaged(restoreAfterward: false))
  }

  /// Every queue on this display forgets what it believes is in the register,
  /// because a write ACKed during an HDR window was swallowed by the panel and
  /// the memo cannot tell those apart. Without this the reset's own unmute can
  /// be skipped as a duplicate of a write that never arrived, and the skip is
  /// then reported as applied. Unconditional, including on a display that turns
  /// out not to be in HDR: what makes a memo untrustworthy is the window it was
  /// built through, which is already in the past.
  @Test func theResetDisengageDropsTheOtherQueuesMemos() async {
    let volume = MemoInvalidationRecorder()
    let contrast = MemoInvalidationRecorder()
    let h = Harness(settle: .milliseconds(5), wireSiblings: { _ in [volume, contrast] })
    await h.prime()

    _ = await h.controller.disengageHDRForReset()

    #expect(volume.memoResets == 1)
    #expect(contrast.memoResets == 1)
  }

  /// The arm above measures the display OUT of HDR, so the sweep is the only
  /// rule that fires and one drop is the whole story. On a display that IS in
  /// HDR three separate rules each answer for the same memos: the exit's own
  /// drop before its re-apply, the confirming refresh's edge under it, and this
  /// door's unconditional sweep. Pinned so that dropping any one of them shows
  /// up here rather than only on a panel nobody can read back.
  @Test func theResetDisengageOnALiveDisplayDropsThroughEveryRule() async {
    let volume = MemoInvalidationRecorder()
    let h = Harness(
      hdrEnabled: true, settle: .milliseconds(5),
      configure: { prefs, _ in prefs.hdrMode = .alwaysOn },
      wireSiblings: { _ in [volume] }
    )
    await h.prime()

    let outcome = await h.controller.disengageHDRForReset()

    #expect(outcome == .disengaged(restoreAfterward: false))
    #expect(volume.memoResets == 3)
  }

  // MARK: The ordinary exit, which closes the same window the reset door does

  /// The defect at the wire, and the reason the invalidation belongs to the exit
  /// rather than to one careful caller: the panel ACKs a write it swallowed
  /// while the register was locked, so the memo comes out of an HDR window
  /// naming a value the register never took. Here the swallowed value is the
  /// unmute wire, and the display is left silent behind a skip the queue reports
  /// as applied.
  @Test func anOrdinaryHDRExitLetsTheSameMuteWireValueGoOutAgain() async {
    let wire = FakeDDC(readResult: nil)
    let store = PathMemoryStore()
    store.values["volume.t"] = 0.5
    var built: DDCValueController?
    let h = Harness(
      hdrEnabled: true, settle: .milliseconds(5),
      configure: { prefs, _ in
        prefs.hdrMode = .alwaysOn
        prefs.enableMuteUnmute = true
        prefs.muted = true
      },
      wireSiblings: { prefs in
        let volume = DDCValueController(
          writer: wire, command: .volume, prefs: prefs, store: store, storageKey: "volume.t"
        )
        built = volume
        return [volume]
      }
    )
    let volume = built!
    await h.prime()
    // Under HDR: the wire value goes out, the panel ACKs it, and the register
    // stays muted. Nothing here can tell the difference, which is the premise.
    _ = volume.toggleMute()
    await volume.waitForPendingWrites()
    #expect(await muteWrites(wire) == [2])

    await h.controller.setHDRMode(.off)

    // The app re-asserting what it believes: unmuted, on a panel that is not.
    volume.restoreToHardware()
    await volume.waitForPendingWrites()
    #expect(
      await muteWrites(wire) == [2, 2],
      "the value the panel swallowed has to be allowed onto the wire again"
    )
  }

  /// Both queues, from the wire the controller holds: the exit owns the rule for
  /// every route out of HDR, so a caller cannot forget it and a new exit route
  /// cannot miss it.
  ///
  /// Twice, not once, and that is the shape rather than an accident: the exit
  /// drops the memos before its own re-apply, and the confirming refresh under
  /// it then sees the mirror go true-to-false and drops them again. A memo
  /// dropped twice costs one redundant write; the alternative orderings each
  /// leave a real write skipped.
  @Test func anOrdinaryHDRExitDropsEveryOtherQueuesMemo() async {
    let volume = MemoInvalidationRecorder()
    let contrast = MemoInvalidationRecorder()
    let h = Harness(
      hdrEnabled: true, settle: .milliseconds(5),
      configure: { prefs, _ in prefs.hdrMode = .alwaysOn },
      wireSiblings: { _ in [volume, contrast] }
    )
    await h.prime()

    await h.controller.setHDRMode(.off)

    #expect(volume.memoResets == 2)
    #expect(contrast.memoResets == 2)
  }

  /// Below the fences, which is why the invalidation is a statement in the
  /// completed path and not a `defer`. A superseded exit establishes nothing,
  /// including that the HDR window is over, so it leaves the sibling memos
  /// exactly as it found them: the same belief as the assume-locked mirror it
  /// restores one line up. The known cost of that rule is written at the
  /// invalidation site.
  @Test func aSupersededExitDropsNoMemos() async {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "t")
    prefs.hdrMode = .alwaysOn
    let gated = GatedTransitionHDR()
    let volume = MemoInvalidationRecorder()
    let contrast = MemoInvalidationRecorder()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: gated,
        shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      wireSiblings: [volume, contrast]
    )
    controller.settleDelay = .milliseconds(5)
    await controller.initialHDRRefresh?.value

    // The exit parks inside its own disengage.
    let exit = Task { await controller.setHDRMode(.off) }
    #expect(await eventually { await gated.disengageCallCount() == 1 })
    // A newer transition takes the display: the token moves while the exit is
    // still parked, so it resumes into a bail.
    let engage = Task { await controller.setHDRMode(.alwaysOn) }
    #expect(await eventually { await gated.engageCallCount() == 1 })

    await gated.releaseDisengage()
    await exit.value

    #expect(volume.memoResets == 0)
    #expect(contrast.memoResets == 0)

    await gated.releaseEngage()
    await engage.value
  }

  /// The other strip of the same rule. The test above parks the exit inside its
  /// own disengage, so it catches an invalidation hoisted above the FIRST fence
  /// and nothing else: one placed between the two fences would survive it. Here
  /// the drop has already returned and the exit is asleep in its settle window
  /// when the newer transition takes the display, so the pair of them covers
  /// both places the call could drift to.
  @Test func anExitSupersededDuringItsSettleDropsNoMemos() async {
    let volume = MemoInvalidationRecorder()
    let contrast = MemoInvalidationRecorder()
    // Sized against the poll below, which returns within a few milliseconds of
    // the drop being issued: the supersession lands inside the settle window by
    // construction rather than by scheduling luck.
    let h = Harness(
      hdrEnabled: true, settle: .milliseconds(150),
      configure: { prefs, _ in prefs.hdrMode = .alwaysOn },
      wireSiblings: { _ in [volume, contrast] }
    )
    await h.prime()

    let exit = Task { await h.controller.setHDRMode(.off) }
    #expect(await eventually { await h.hdr!.recordedSetCalls() == [false] })
    let engage = Task { await h.controller.setHDRMode(.alwaysOn) }
    await exit.value

    #expect(volume.memoResets == 0)
    #expect(contrast.memoResets == 0)

    await engage.value
  }

  /// The scoping half. A door that decides there is nothing to do opened no HDR
  /// window and closed none, so it must not drop a memo either: the suppression
  /// that keeps ordinary pref paths from re-moding every panel keeps them out of
  /// the sibling queues too.
  @Test func aSuppressedModeDoorDropsNoMemos() async {
    let volume = MemoInvalidationRecorder()
    let h = Harness(settle: .milliseconds(5), wireSiblings: { _ in [volume] })
    await h.prime()

    await h.controller.setHDRMode(.off)

    #expect(await h.hdr!.recordedSetCalls().isEmpty)
    #expect(volume.memoResets == 0)
  }

  // MARK: The observed edge, which covers the routes with no door of ours in them

  /// HDR dropped OUTSIDE the app. No door of Candela's runs, so there is no
  /// caller anywhere on this path to hand the wire to: the app learns the
  /// display left HDR the way it learns about any reconfiguration, and the
  /// memos built while the register was locked are still standing when the next
  /// re-assert goes out. Here the swallowed value is the unmute wire, and the
  /// display is left silent behind a skip the queue reports as applied.
  ///
  /// What this does NOT discriminate is which flag the edge reads: no transition
  /// runs on this route, so `observedHDRActive` and `cachedHDRActive` move
  /// together and either would pass. The test that separates them is
  /// `anOrdinaryHDRExitDropsEveryOtherQueuesMemo`, whose second drop exists only
  /// because the edge reads the observed flag rather than the optimistic mirror.
  @Test func hdrDroppedOutsideTheAppLetsTheSameMuteWireValueGoOutAgain() async {
    let wire = FakeDDC(readResult: nil)
    let store = PathMemoryStore()
    store.values["volume.t"] = 0.5
    var built: DDCValueController?
    let h = Harness(
      hdrEnabled: true, settle: .milliseconds(5),
      // Candela's mode stays `.off` on purpose: HDR engaged in System Settings
      // is HDR the app has no opinion about, which is the whole route.
      configure: { prefs, _ in
        prefs.enableMuteUnmute = true
        prefs.muted = true
      },
      wireSiblings: { prefs in
        let volume = DDCValueController(
          writer: wire, command: .volume, prefs: prefs, store: store, storageKey: "volume.t"
        )
        built = volume
        return [volume]
      }
    )
    let volume = built!
    await h.prime()
    // Under HDR: the wire value goes out, the panel ACKs it, and the register
    // stays muted. Nothing here can tell the difference, which is the premise.
    _ = volume.toggleMute()
    await volume.waitForPendingWrites()
    #expect(await muteWrites(wire) == [2])

    await h.hdr!.setHDR(displayID: Harness.displayID, enabled: false) // System Settings
    await h.controller.noteHDRStateMayHaveChanged() // the reconfigure lands
    #expect(
      await h.hdr!.recordedSetCalls() == [false],
      "the only drop is the one this test made: no exit of Candela's ran"
    )

    // The app re-asserting what it believes: unmuted, on a panel that is not.
    volume.restoreToHardware()
    await volume.waitForPendingWrites()
    #expect(
      await muteWrites(wire) == [2, 2],
      "the value the panel swallowed has to be allowed onto the wire again"
    )
  }

  /// The negative control, and what makes the test above evidence rather than a
  /// coincidence: the drop is keyed to an HDR window closing, not to a refresh
  /// happening. A display that was never in HDR gets its re-assert skipped as a
  /// duplicate exactly as before, so a check that cannot fail is not what is
  /// being asserted up there.
  @Test func aRefreshOnADisplayThatWasNeverInHDRDropsNothing() async {
    let wire = FakeDDC(readResult: nil)
    let store = PathMemoryStore()
    store.values["volume.t"] = 0.5
    var built: DDCValueController?
    let h = Harness(
      settle: .milliseconds(5),
      configure: { prefs, _ in
        prefs.enableMuteUnmute = true
        prefs.muted = true
      },
      wireSiblings: { prefs in
        let volume = DDCValueController(
          writer: wire, command: .volume, prefs: prefs, store: store, storageKey: "volume.t"
        )
        built = volume
        return [volume]
      }
    )
    let volume = built!
    await h.prime()
    _ = volume.toggleMute()
    await volume.waitForPendingWrites()
    #expect(await muteWrites(wire) == [2])

    await h.controller.noteHDRStateMayHaveChanged()

    volume.restoreToHardware()
    await volume.waitForPendingWrites()
    #expect(await muteWrites(wire) == [2], "nothing locked the register, so nothing is suspect")
  }

  /// The other direction of the same scoping: HDR going ON is not a window
  /// closing. An entry that dropped the memos would cost a redundant write on
  /// every external toggle and, worse, would make the rule look like "refresh
  /// drops memos" to the next person reading it.
  @Test func anEntryEdgeDropsNoMemos() async {
    let volume = MemoInvalidationRecorder()
    let h = Harness(settle: .milliseconds(5), wireSiblings: { _ in [volume] })
    await h.prime() // HDR off

    await h.hdr!.setHDR(displayID: Harness.displayID, enabled: true) // System Settings
    await h.controller.noteHDRStateMayHaveChanged()

    #expect(h.controller.isHDREngaged)
    #expect(volume.memoResets == 0)
  }

  /// The cell the shared exit cannot reach, and the second route this edge
  /// covers: an exit whose drop TAKES, superseded past its own fences by an
  /// engage that then fails to engage. The display is out of HDR with memos
  /// built while the register was locked; the exit bails without dropping them
  /// (correctly, since it established nothing), and the engage's rollback arm
  /// does not drop them either. What sees it is the rollback's refresh
  /// observing the mirror go true-to-false.
  @Test func anExitSupersededByAnEngageThatFailsStillDropsTheMemos() async {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "t")
    prefs.hdrMode = .alwaysOn
    let gated = DropTakesThenEngageFailsHDR()
    let volume = MemoInvalidationRecorder()
    let contrast = MemoInvalidationRecorder()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: gated,
        shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      wireSiblings: [volume, contrast]
    )
    controller.settleDelay = .milliseconds(5)
    await controller.initialHDRRefresh?.value // the mirror observes HDR live

    // The exit's drop has taken, and the exit is parked below it.
    let exit = Task { await controller.setHDRMode(.off) }
    #expect(await eventually { await gated.disengageCallCount() == 1 })
    // The second click: it supersedes the parked exit and then fails to engage.
    await controller.setHDRMode(.alwaysOn)

    #expect(controller.hdrMode == .off, "the engage rolled back")
    #expect(volume.memoResets == 1)
    #expect(contrast.memoResets == 1)

    await gated.releaseDisengage()
    await exit.value
    #expect(volume.memoResets == 1, "and the superseded exit still asserts nothing itself")
  }

  /// A drop that is ISSUED and does not take is not a disengage, whatever the
  /// optimistic mirror says on the way through. Before the exit reported its own
  /// completion this could not even be detected: the mirror was set to false at
  /// the top and the caller read that as evidence.
  @Test func aDropThatDoesNotTakeIsReportedAsUnknown() async {
    let h = Harness(hdrEnabled: true, settle: .milliseconds(5))
    await h.prime()
    await h.hdr!.stubAchieves(false) // accepted, and the display stays in HDR

    let outcome = await h.controller.disengageHDRForReset()

    #expect(await h.hdr!.recordedSetCalls() == [false], "the write was issued")
    #expect(outcome == .unknown, "and issuing it is not the same as it working")
  }

  /// The ordering the reset's recovery depends on, measured as a defect on
  /// hardware: a DDC submit rides a coalescer and reaches the wire on its own
  /// task, so the unmute is merely QUEUED when the reset moves on. Re-engaging
  /// HDR locks the register the moment it lands, and on a write-only panel a
  /// swallowed unmute reports success and strands the display silent. So the
  /// restore settles the wire, and that belongs to the restore rather than to
  /// each caller that must remember it.
  ///
  /// The write here is genuinely in flight: the writer is held mid-apply, so a
  /// restore that waited on the completion COUNTER rather than on the wire
  /// would sail past it.
  @Test func theRestoreWaitsForAnInFlightWriteBeforeReEngagingHDR() async {
    let gate = GatedWriter()
    var built: DDCValueController?
    let h = Harness(settle: .milliseconds(5), wireSiblings: { prefs in
      let volume = DDCValueController(writer: gate, command: .volume, prefs: prefs)
      built = volume
      return [volume]
    })
    let volume = built!
    await gate.attach(hdr: h.hdr!)
    await h.prime()
    await h.hdr!.stubEnabled(true)
    #expect(await h.controller.disengageHDRForReset() == .disengaged(restoreAfterward: true))

    volume.setValue(0.5) // queued, and the writer is holding it

    let restore = Task { await h.controller.restoreExternalHDR() }
    while await gate.applyCount() == 0 { await Task.yield() }
    #expect(
      await h.hdr!.recordedSetCalls() == [false],
      "still holding the wire, so the engage has not gone out"
    )
    await gate.release()
    await restore.value

    #expect(await gate.setCallsWhenApplied == [false], "the write landed before the engage")
    #expect(await h.hdr!.recordedSetCalls() == [false, true])
    #expect(h.controller.isHDREngaged)
  }

  /// The failure this mechanism exists for, and the reason a completion counter
  /// is not evidence: the epoch gate SKIPS a write stamped before a display
  /// reconfiguration, then completes its generation anyway. A drain that
  /// believed the counter would report a queue that put nothing on the panel.
  @Test func aWriteTheEpochGateSkippedIsNotReportedAsLanded() async {
    let h = Harness()
    let gateOpen = OSAllocatedUnfairLock(initialState: false)
    h.controller.setEpochProvider({ 1 }, isCurrent: { _ in gateOpen.withLock { $0 } })
    h.controller.setBrightness(0.75)

    #expect(await h.controller.drainPendingWrites() == false, "skipped is not applied")
    #expect(await h.ddc.recordedWrites().isEmpty, "and nothing reached the panel")

    gateOpen.withLock { $0 = true }

    #expect(await h.controller.drainPendingWrites(), "the re-submit lands once the gate opens")
    #expect(!(await h.ddc.recordedWrites().isEmpty))
  }

  /// The drain waits on a SNAPSHOT of its own counter. Anything submitted while
  /// it is suspended belongs to whoever submitted it, and comparing against a
  /// re-read counter would call that a failure, retry a write nobody was owed,
  /// and hand the settle loop a false reason to decline the restore.
  @Test func aSubmitLandingDuringTheDrainsOwnWaitIsNotMistakenForAFailure() async {
    let gate = GatedWriter()
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "t")
    let controller = BrightnessController(
      writer: gate,
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: nil,
        shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      wireSiblings: []
    )
    let wireOpen = OSAllocatedUnfairLock(initialState: true)
    controller.setEpochProvider({ 1 }, isCurrent: { _ in wireOpen.withLock { $0 } })
    var submits = 0
    controller._onSubmit = { _, _ in submits += 1 }
    controller.setBrightness(0.75) // parked in the writer, mid-apply
    while await gate.applyCount() == 0 { await Task.yield() }
    let drain = Task { await controller.drainPendingWrites() }
    await Task.yield() // let it take its snapshot and park on the wait
    // Submitted while the drain is suspended, and into a closed window so it
    // cannot land: the drain must judge itself on what IT was waiting for, not
    // on a counter this moved.
    wireOpen.withLock { $0 = false }
    controller.setBrightness(0.5)
    await gate.release()

    #expect(await drain.value, "the write it waited for did land")
    #expect(submits == 2, "the two the test made, and no retry of a write that landed")
  }

  /// A rebind hands out a fresh service, so the write the drain was holding for
  /// a retry names a wire that no longer exists. It is dropped with the
  /// duplicate memo the rebind already clears, rather than replayed onto the new
  /// panel: the drain reports the failure instead, and the reset declines to
  /// re-engage rather than writing blind.
  @Test func aRebindBetweenTheSubmitAndTheDrainDoesNotReplayTheOldWrite() async {
    let h = Harness()
    let wireOpen = OSAllocatedUnfairLock(initialState: false)
    h.controller.setEpochProvider({ 1 }, isCurrent: { _ in wireOpen.withLock { $0 } })
    h.controller.setBrightness(0.75)
    await h.controller.waitForPendingWrites() // the skip has already happened
    let fresh = FakeDDC(readResult: nil)
    h.controller.rebind(writer: fresh, panelIdentity: "a different panel")
    // Open again, so nothing but the dropped target stops a replay.
    wireOpen.withLock { $0 = true }

    #expect(await h.controller.drainPendingWrites() == false)
    #expect(await fresh.recordedWrites().isEmpty, "nothing stale went onto the new wire")
  }

  /// And what the reset does with that: a wire it cannot settle means the
  /// re-engage does NOT happen. Leaving a display out of HDR is visible and one
  /// click from fixed; locking the register over a write nobody can see fail is
  /// the silent strand.
  @Test func aWireThatCannotBeSettledSkipsTheReEngage() async {
    let h = Harness(settle: .milliseconds(5))
    h.controller.wireSettlePause = .milliseconds(1)
    await h.prime()
    await h.hdr!.stubEnabled(true)
    #expect(await h.controller.disengageHDRForReset() == .disengaged(restoreAfterward: true))
    // Closed for good: every submit from here is completed without landing.
    h.controller.setEpochProvider({ 1 }, isCurrent: { _ in false })
    h.controller.setBrightness(0.75)

    await h.controller.restoreExternalHDR()

    #expect(await h.hdr!.recordedSetCalls() == [false], "no engage on an unsettled wire")
    #expect(!h.controller.isHDREngaged)
  }

  /// A transition landing in the door's measured-read window, from the review
  /// probe that reproduced it. The panel measures OFF throughout, so there are
  /// two ways to get this wrong and both were: asking the caller to re-engage
  /// HDR on a display that was never in it (the race was being counted as
  /// liveness), and skipping the mode clear because the mode was read before
  /// the await and the racing transition wrote it afterwards.
  @Test func aTransitionDuringTheMeasuredReadNeitherInventsHDRNorSparesTheMode() async {
    let hdr = GatedMeasureHDR()
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "t")
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: hdr,
        shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      wireSiblings: []
    )
    controller.settleDelay = .milliseconds(5)
    await controller.initialHDRRefresh?.value
    #expect(!controller.isHDREngaged)
    #expect(controller.hdrMode == .off)

    let door = Task { await controller.disengageHDRForReset() }
    while await hdr.measureCallCount() == 0 { await Task.yield() }
    let other = Task { await controller.setHDRMode(.alwaysOn) }
    while !controller.isHDRSettling { await Task.yield() }
    await hdr.release()
    let outcome = await door.value
    await other.value

    #expect(
      outcome == .unknown,
      "a display another transition owns is not a display this call can vouch for"
    )
    #expect(prefs.hdrMode == .off, "and the reset clears the mode whatever raced it")
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
    #expect(h.gamma.scales.count == scalesBefore) // no re-apply under native (the restore latch)
  }

  // MARK: separateCombinedScale stepping

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

  /// HDR Boost is cut: a fresh press at either end of the range is just a step, and
  /// no key path may touch a display's HDR state.
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

// MARK: - Settings re-apply

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
    #expect(h.controller.brightness == 0.4) // the value is preserved, never slammed to 1.0
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
    // register write, software leg only, and on the COMBINED SPLIT value rather
    // than the raw one, which is what the 0.83 below pins. Ruling R-A gave the
    // state its own case instead of a guard inside the combined branch; the
    // behaviour is unchanged, which is the point of the row.
    let h = Harness()
    h.controller.setBrightness(0.4)
    #expect(h.submitted == [.ddc(raw: 0)])

    var tuning = h.prefs.tuning(for: .brightness)
    tuning.unavailableDDC = true
    h.prefs.setTuning(tuning, for: .brightness)
    h.controller.reapplyAfterPrefChange()

    // Nothing new on the wire, and the silence is deliberate:
    // `handBackDDCLegIfAbandoned` skips a command the display has declared
    // unsupported or the user has switched off, exactly as `restoreFullRangeDDC`
    // does, so the register stays at the combined floor. Undoing that belongs in
    // the tuning grid's own Off switch (the unmute-before-persist shape: undo the disabling
    // effect before persisting the value that disables it), not in a write to a
    // command just declared unavailable.
    #expect(h.submitted == [.ddc(raw: 0)])
    #expect(h.gamma.scales.count == 2 && approx(h.gamma.scales[1], 0.83)) // re-asserted
  }

  /// The corner where combined mode has BOTH legs dead: the brightness
  /// command's DDC leg is turned off AND the switching point is −8, so
  /// `combinedSplit`'s hardware branch always wins and the software band has
  /// zero width. Nothing moves the display at all.
  ///
  /// State (B) of the collapse recorded on
  /// `BrightnessController.softwareBackendChoice`. Answering `.gamma` and
  /// re-applying `sw == 1` and answering `.none` with the backend torn down are
  /// equivalent only by arithmetic, `swTransform(1, allowZero: false) == 1`, and an
  /// arithmetic coincidence nobody asserts is a regression waiting for the next
  /// reader who "simplifies" one side of it.
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

// MARK: - Handing the DDC leg back when a pref abandons it

/// Achieved output for a register value under a gamma scale, on a panel that
/// still emits `floor` of its maximum at register 0. Everything below is
/// asserted for SEVERAL floors, because the panel's real curve is unknown (the
/// MAG answers no reads at all) and the ordering claim must not depend on it:
/// the only property used is that the curve is monotone increasing.
private func achieved(ddc raw: UInt16, gamma: Double, floor: Double) -> Double {
  (floor + (1 - floor) * Double(raw) / 100) * gamma
}

private let panelFloors = [0.0, 0.1, 0.2, 0.5]

private extension HardwareTarget {
  var isDDC: Bool { if case .ddc = self { true } else { false } }
}

@MainActor
@Suite("Handing the DDC leg back")
struct DDCLegHandBackTests {
  /// The hardware measurement as an engine test: the MAG at 40% combined is
  /// register 0 with the table at 0.83, and turning hardware control off used to
  /// write no register value at all, leaving software dimming to run on top of a
  /// panel already at its hardware minimum.
  @Test func turningHardwareControlOffParksTheRegisterAtFullRange() async {
    let h = Harness()
    h.controller.setBrightness(0.4)
    #expect(h.submitted == [.ddc(raw: 0)])
    #expect(h.gamma.scales.count == 1 && approx(h.gamma.scales[0], 0.83))

    // The ordering probe: what had reached the wire at the instant the new
    // mode's gamma write went out.
    var wireAtGammaTime: [HardwareTarget] = []
    h.controller.preGammaApplyHook = { [weak h] in wireAtGammaTime = h?.submitted ?? [] }

    h.prefs.forceSoftware = true
    h.controller.reapplyAfterPrefChange()

    // Full-range register, and the software leg on the raw value: swTransform(0.4).
    #expect(h.submitted == [.ddc(raw: 0), .ddc(raw: 100)])
    #expect(h.gamma.scales.count == 2 && approx(h.gamma.scales[1], 0.49))
    #expect(h.controller.brightness == 0.4) // the value is preserved
    // ORDERING: the table was already at its new value before the register rose.
    #expect(wireAtGammaTime == [.ddc(raw: 0)])
  }

  /// The invariant the ordering exists for, at both sides of the switching
  /// point: the transient never overshoots the brighter of the two endpoints, and
  /// the reversed ordering always would. At 0.9 reversing it is a flash to 100%.
  @Test func theTransientNeverOvershootsEitherEndpoint() async {
    for (value, ddcBefore, gammaBefore, gammaAfter) in [
      (0.4, UInt16(0), 0.83, 0.49), // software zone: register already at the floor
      (0.9, UInt16(80), 1.0, 0.915), // hardware zone: register high, table neutral
    ] {
      let h = Harness()
      h.controller.setBrightness(value)
      #expect(h.submitted == [.ddc(raw: ddcBefore)])
      #expect(approx(h.gamma.scales.last ?? .nan, gammaBefore))

      var wireAtGammaTime: [HardwareTarget] = []
      h.controller.preGammaApplyHook = { [weak h] in wireAtGammaTime = h?.submitted ?? [] }

      h.prefs.forceSoftware = true
      h.controller.reapplyAfterPrefChange()

      #expect(h.submitted == [.ddc(raw: ddcBefore), .ddc(raw: 100)])
      #expect(approx(h.gamma.scales.last ?? .nan, gammaAfter))
      // The register had NOT yet risen when the table dropped, which is what
      // makes the transient computable below.
      #expect(wireAtGammaTime == [.ddc(raw: ddcBefore)])

      for floor in panelFloors {
        let start = achieved(ddc: ddcBefore, gamma: gammaBefore, floor: floor)
        let end = achieved(ddc: 100, gamma: gammaAfter, floor: floor)
        let transient = achieved(ddc: ddcBefore, gamma: gammaAfter, floor: floor)
        // No flash: the in-between state is never brighter than either endpoint.
        #expect(transient <= max(start, end) + 1e-12)
        // And it is the ORDER that buys that, not luck. Raising the register
        // first would put a full-range panel under the old table, which
        // overshoots both endpoints for every curve.
        let reversed = achieved(ddc: 100, gamma: gammaBefore, floor: floor)
        #expect(reversed > max(start, end))
        // The register ends where software dimming assumes it is: full range,
        // so the software leg alone accounts for the whole difference.
        #expect(approx(end, gammaAfter))
      }
    }
  }

  /// Turning hardware control back ON puts exactly one register write on the
  /// wire, at the combined value, with no full-range write on the way through.
  ///
  /// The WIRE is what this pins. The ordering suite below owns when the table moves
  /// relative to the write, so the await here is load-bearing rather than decorative.
  @Test func turningHardwareControlBackOnWritesOneRegisterValue() async {
    let h = Harness { prefs, _ in prefs.forceSoftware = true }
    h.controller.setBrightness(0.4)
    #expect(h.submitted.isEmpty)
    #expect(h.gamma.scales.count == 1 && approx(h.gamma.scales[0], 0.49))

    h.prefs.forceSoftware = false
    h.controller.reapplyAfterPrefChange()
    await h.controller.heldSoftwareLeg?.value

    #expect(h.submitted == [.ddc(raw: 0)])
    #expect(h.gamma.scales.count == 2 && approx(h.gamma.scales[1], 0.83))
  }

  /// A register Candela has never written is one the user set with the
  /// monitor's own buttons. A pref change that touches only the software leg
  /// must not seize it.
  @Test func aRegisterCandelaNeverDroveIsLeftAlone() async {
    let h = Harness { prefs, _ in prefs.forceSoftware = true }
    h.controller.setBrightness(0.4)

    h.prefs.avoidGamma = true
    h.controller.reapplyAfterPrefChange()

    #expect(h.submitted.isEmpty)
    #expect(h.shade.alphaCalls.count == 1)
  }

  /// At 100% combined the register is already at full range, so abandoning the
  /// leg has nothing to hand back and puts no extra write on a write-only bus.
  @Test func aRegisterAlreadyAtFullRangeIsNotRewritten() async {
    let h = Harness()
    h.controller.setBrightness(1.0)
    #expect(h.submitted == [.ddc(raw: 100)])

    h.prefs.forceSoftware = true
    h.controller.reapplyAfterPrefChange()

    #expect(h.submitted == [.ddc(raw: 100)])
  }

  /// Under live HDR the DDC register is dead, so a register left below full
  /// range stays there: the native path is not an abandonment this can repair,
  /// and reaching for the wire to prove otherwise is the write that cannot land.
  @Test func theNativePathIsNeverHandedBackOverDDC() async {
    let h = Harness(settle: .milliseconds(5))
    await h.prime()
    h.controller.setBrightness(0.4) // combined: the register goes to its floor
    #expect(h.submitted == [.ddc(raw: 0)])
    await h.controller.setHDRMode(.alwaysOn)

    h.prefs.forceSoftware = true
    h.controller.reapplyAfterPrefChange()

    #expect(h.submitted.filter(\.isDDC) == [.ddc(raw: 0)])
    await h.controller.waitForPendingWrites()
    #expect(await h.ddc.recordedWrites().count == 1)
  }

  /// The min/max overrides move what "full range" MEANS, and the hand-back is
  /// stated in the portion domain so it follows them: portion 1 is the
  /// brightest the display is configured to go, not a hard-coded 100.
  @Test func theHandBackRespectsAMaxOverride() async {
    let h = Harness()
    var tuning = h.prefs.tuning(for: .brightness)
    tuning.maxDDCOverride = 80
    h.prefs.setTuning(tuning, for: .brightness)
    h.controller.setBrightness(0.4)
    #expect(h.submitted == [.ddc(raw: 0)])

    h.prefs.forceSoftware = true
    h.controller.reapplyAfterPrefChange()

    #expect(h.submitted == [.ddc(raw: 0), .ddc(raw: 80)])
  }
}

// MARK: - Ordering a pref change that DROPS the register

/// The other direction of the hand-back ordering rule, and the flash it left behind.
///
/// Turning hardware control back ON at a value the combined split puts at the
/// register's floor lowers the register (100 to 0 on the MAG at 0.375) while
/// raising the table (0.4688 to 0.7875). The software side is inline and the
/// register write drains off-actor, so writing both at once composed a frame
/// from the OLD register under the NEW table: brighter than either endpoint,
/// for the ~17 ms the write was in flight, seen by eye on the MAG.
///
/// One rule covers both directions: the leg that goes DOWN goes first. When the
/// register rises that costs nothing (the software side is inline and already
/// first); when it drops, the software side has to WAIT for the write.
@MainActor
@Suite("Ordering a pref change that drops the register")
struct RegisterDropOrderingTests {
  /// The measured state: software-only at `value`, with the register handed back at
  /// full range.
  private func softwareOnlyAfterHandBack(at value: Double) async -> Harness {
    let h = Harness()
    h.controller.setBrightness(value)
    h.prefs.forceSoftware = true
    h.controller.reapplyAfterPrefChange()
    await h.controller.waitForPendingWrites()
    return h
  }

  /// The hardware measurement as an engine test.
  @Test func turningHardwareControlBackOnHoldsTheTableUntilTheRegisterLands() async {
    let h = await softwareOnlyAfterHandBack(at: 0.375)
    // Software-only at 0.375: register handed back at full range, table at
    // swTransform(0.375).
    #expect(h.submitted == [.ddc(raw: 0), .ddc(raw: 100)])
    #expect(h.gamma.scales.count == 2 && approx(h.gamma.scales[1], 0.46875))

    // The ordering probe: how many writes had LANDED at the instant the table
    // moved. Submits are not enough here: the defect was entirely in the gap
    // between submitting the write and its landing.
    //
    // Counted as a DELTA against the settled count, never as an absolute: the
    // coalescer is latest-wins, so whether the two setup writes both reached the
    // wire or the first was superseded is a scheduling race and not this test's
    // subject. One more write than had landed before is the whole claim.
    let landedBefore = h.ddc.landedWriteCount()
    var landedAtGammaTime = -1
    h.controller.preGammaApplyHook = { [weak h] in
      landedAtGammaTime = h?.ddc.landedWriteCount() ?? -1
    }

    h.prefs.forceSoftware = false
    h.controller.reapplyAfterPrefChange()

    // The register write is out and the table has NOT moved: the display is
    // still rendering the state it was already in.
    #expect(h.submitted == [.ddc(raw: 0), .ddc(raw: 100), .ddc(raw: 0)])
    #expect(h.gamma.scales.count == 2)

    await h.controller.heldSoftwareLeg?.value

    #expect(h.gamma.scales.count == 3 && approx(h.gamma.scales[2], 0.7875))
    #expect(landedAtGammaTime == landedBefore + 1) // the drop was already on the wire
    #expect(h.controller.brightness == 0.375) // the value is preserved
  }

  /// The invariant the hold exists for, at both sides of the switching point,
  /// against every panel floor: the in-between frame never overshoots the
  /// brighter endpoint, and releasing the table first always would.
  @Test func theTransientNeverOvershootsEitherEndpoint() async {
    for (value, ddcBefore, gammaBefore, ddcAfter, gammaAfter) in [
      // Software zone: the register goes to its floor.
      (0.375, UInt16(0), 0.46875, UInt16(0), 0.7875),
      // Hardware zone: the register drops from full range to the combined split.
      (0.875, UInt16(75), 0.89375, UInt16(75), 1.0),
    ] {
      let h = await softwareOnlyAfterHandBack(at: value)
      #expect(h.submitted == [.ddc(raw: ddcBefore), .ddc(raw: 100)])
      #expect(approx(h.gamma.scales.last ?? .nan, gammaBefore))

      h.prefs.forceSoftware = false
      h.controller.reapplyAfterPrefChange()
      await h.controller.heldSoftwareLeg?.value

      #expect(h.submitted.last == .ddc(raw: ddcAfter))
      #expect(approx(h.gamma.scales.last ?? .nan, gammaAfter))

      for floor in panelFloors {
        let start = achieved(ddc: 100, gamma: gammaBefore, floor: floor)
        let end = achieved(ddc: ddcAfter, gamma: gammaAfter, floor: floor)
        // What the hold renders in between: the new register under the table
        // that was already installed.
        let transient = achieved(ddc: ddcAfter, gamma: gammaBefore, floor: floor)
        #expect(transient <= max(start, end) + 1e-12)
        // And it is the ORDER that buys that. Releasing the table first leaves
        // the old, high register under the new, brighter table, which overshoots
        // both endpoints for every curve. That is the flash.
        let reversed = achieved(ddc: 100, gamma: gammaAfter, floor: floor)
        #expect(reversed > max(start, end))
      }
    }
  }

  /// The other direction is untouched: when the register RISES the software side
  /// still runs inline, because it is the leg going down and therefore already
  /// first. Nothing is held, so nothing waits on a DDC round trip it did not need.
  @Test func aPrefChangeThatRaisesTheRegisterKeepsTheSoftwareLegInline() async {
    let h = Harness()
    h.controller.setBrightness(0.4)

    h.prefs.forceSoftware = true
    h.controller.reapplyAfterPrefChange()

    #expect(h.controller.heldSoftwareLeg == nil)
    #expect(h.gamma.scales.count == 2 && approx(h.gamma.scales[1], 0.49))
    #expect(h.submitted == [.ddc(raw: 0), .ddc(raw: 100)])
  }

  /// A pref that moves only the software leg leaves the register where it is,
  /// so there is nothing to wait for and the edit takes effect at once.
  @Test func aPrefChangeThatLeavesTheRegisterAloneKeepsTheSoftwareLegInline() async {
    let h = Harness()
    h.controller.setBrightness(0.4)
    #expect(h.submitted == [.ddc(raw: 0)])

    h.prefs.avoidGamma = true
    h.controller.reapplyAfterPrefChange()

    #expect(h.controller.heldSoftwareLeg == nil)
    #expect(h.shade.alphaCalls.count == 1)
    #expect(approx(h.shade.alphaCalls[0].alpha, DimmingMath.shadeAlpha(fromValue: 0.83)))
  }

  /// The teardown is inside the hold, not before it. Abandoning the software leg
  /// altogether hands the table back at 1.0, which is itself a brightening, so
  /// holding only the re-apply would move the flash rather than remove it.
  ///
  /// Reaching `.hardware` from software-only takes two prefs, which the settings
  /// window writes one at a time. The state is still reachable (a `defaults
  /// write` of the advanced key, or a reset) and the invariant is about the
  /// ordering, not about how the state was arrived at.
  @Test func abandoningTheSoftwareLegEntirelyIsHeldToo() async {
    let h = await softwareOnlyAfterHandBack(at: 0.4)
    #expect(h.gamma.scales.count == 2 && approx(h.gamma.scales[1], 0.49))

    h.prefs.forceSoftware = false
    h.prefs.disableCombinedBrightness = true
    h.controller.reapplyAfterPrefChange()

    // Pure DDC at 0.4 is register 40, below the full range it was parked at.
    #expect(h.submitted.last == .ddc(raw: 40))
    #expect(h.gamma.scales.count == 2) // the table has not been handed back yet

    await h.controller.heldSoftwareLeg?.value
    #expect(h.gamma.scales.count == 3 && h.gamma.scales[2] == 1.0)
  }

  /// A held software side is superseded by anything that moves the display
  /// afterwards. Without the token the hold would resume onto a value the user
  /// has already left, re-dimming the display behind them.
  @Test func aLaterBrightnessChangeSupersedesAHeldSoftwareLeg() async {
    let h = await softwareOnlyAfterHandBack(at: 0.375)
    h.prefs.forceSoftware = false
    h.controller.reapplyAfterPrefChange()

    h.controller.setBrightness(0.9) // combined: ddc 0.8, sw 1
    await h.controller.heldSoftwareLeg?.value

    // The held 0.7875 never lands: the last word is the newer value's.
    #expect(h.gamma.scales.count == 3 && h.gamma.scales[2] == 1.0)
    #expect(h.submitted.last == .ddc(raw: 80))
  }

  /// A monitor that refuses the write must not strand the software side parked
  /// forever: a write ACK is evidence of nothing, and so is its absence. The
  /// coalescer completes every dequeued generation, failures included, and the
  /// display ends in the state the prefs ask for either way.
  @Test func aRefusedRegisterWriteStillReleasesTheSoftwareLeg() async {
    let h = await softwareOnlyAfterHandBack(at: 0.375)
    await h.ddc.setWritesSucceed(false)

    h.prefs.forceSoftware = false
    h.controller.reapplyAfterPrefChange()
    await h.controller.heldSoftwareLeg?.value

    #expect(h.gamma.scales.count == 3 && approx(h.gamma.scales[2], 0.7875))
  }
}

// MARK: - External adoption (echo slot)

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

// MARK: - Cross-display sync fan-out (fork parity: AppDelegate's fan-out)

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

// MARK: - Migration + first run (I12/I13)

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

// MARK: - Built-in display role

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

  /// The migration/first-run/park-at-s block is bypassed entirely. A native read of
  /// 0.3 publishes 0.3 (an external role would park it at s = 0.5), the seeded
  /// store value is ignored, and nothing is ever written to the store.
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

  /// The poller gate is constitutively true for the built-in role: no HDR settle
  /// machinery ever runs, and the native path is always active.
  @Test func builtInIsNativeActiveConstitutively() async {
    let h = Harness(withHDR: false, role: .builtIn)
    #expect(h.controller.isNativeActive())
  }

  /// The public stub writer always fails, so any DDC path reached by mistake
  /// degrades instead of touching hardware.
  @Test func noopDDCWriterAlwaysFails() async {
    let writer = NoopDDCWriter()
    #expect(await writer.write(command: VCP.brightness, value: 50) == false)
    #expect(await writer.read(command: VCP.brightness) == nil)
  }

  /// `setHDRMode` is role-fenced: a public-API call on a built-in controller is a
  /// full no-op, with no pref write under the builtIn key, no published-mode
  /// change, and no HDR toggling.
  @Test func setHDRModeOnBuiltInIsNoOp() async {
    let h = Harness(role: .builtIn)
    await h.prime()
    await h.controller.setHDRMode(.alwaysOn)
    #expect(h.controller.hdrMode == .off)
    #expect(h.prefs.hdrMode == .off) // pref never written
    #expect(await h.hdr!.recordedSetCalls().isEmpty)
  }
}

// MARK: - alwaysOn engage failure

@MainActor
@Suite("HDR mode engage failure")
struct HDRModeEngageFailureTests {
  /// The `.alwaysOn` arm commits the mode optimistically before engaging. On
  /// `engaged == false` it must roll `hdrMode`/`prefs.hdrMode` back and re-apply the
  /// current value through the normal path, or a display that cannot engage HDR is
  /// stranded un-dimmed (the restore-latch clearing already ran) with a lying `.alwaysOn`
  /// persisted across launches.
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
    // The restore-latch clearing ran (1.0), then the rollback re-applied the current value's
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

  /// The panel's badge reports LIVE HDR, not the mode pref: an externally toggled
  /// HDR once read as "HDR Off" with no badge, so `isHDREngaged` must follow the
  /// cache even while the mode is `.off`.
  @Test func isHDREngagedReflectsLiveHDRRegardlessOfMode() async {
    let live = Harness(hdrEnabled: true) // externally toggled; mode stays .off
    await live.prime()
    #expect(live.controller.hdrMode == .off)
    #expect(live.controller.isHDREngaged)
    let dark = Harness()
    await dark.prime()
    #expect(dark.controller.isHDREngaged == false)
  }

  /// `setHDRMode`'s body is a bare async func and the panel spawns one unserialized
  /// Task per mode change, so nothing serializes overlapping calls but the
  /// generation token. A first `.alwaysOn` call parked on its engage await must NOT,
  /// when the engage finally fails, roll `hdrMode`/`prefs.hdrMode` back to its stale
  /// `previous` or fire `applyPaths` after a second call has retargeted: the newer
  /// transition owns the state.
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
        applierNative: FakeNativeApplier(), hdr: gated, shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      wireSiblings: []
    )
    controller.settleDelay = .milliseconds(5)
    var submitted: [HardwareTarget] = []
    controller._onSubmit = { target, _ in submitted.append(target) }
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

  /// The supersession token must be a MONOTONIC GENERATION, not the mode. `hdrMode`
  /// is ABA-prone: a parked `.alwaysOn` call resumes to find the mode back at
  /// `.alwaysOn` after an `.off` to `.alwaysOn` round trip, so a `hdrMode == mode`
  /// comparison waves its stale rollback through and the THIRD transition's
  /// committed mode and prefs are clobbered by the first's `previous`.
  @Test func overlappingSetHDRModeABADoesNotClobberThirdTransition() async {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "t")
    // Only the FIRST engage is gated (and fails); the third transition's
    // engage passes straight through and succeeds.
    let gated = GatedEngageHDR(gateFirstEngageOnly: true)
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: gated, shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      wireSiblings: []
    )
    controller.settleDelay = .milliseconds(5)
    var submitted: [HardwareTarget] = []
    controller._onSubmit = { target, _ in submitted.append(target) }
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

  /// The EXIT arm has the same bare-async-func exposure as the engage arm. A `.off`
  /// transition parked on its disengage must not, once it resumes, clear the settle
  /// flag of the transition that retargeted past it, or fire its `applyPaths`
  /// against state that transition owns.
  @Test func overlappingSetHDRModeExitArmDoesNotClobberNewerTransition() async {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "t")
    prefs.hdrMode = .alwaysOn
    let gated = GatedTransitionHDR()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: gated, shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      wireSiblings: []
    )
    controller.settleDelay = .milliseconds(5)
    var submitted: [HardwareTarget] = []
    controller._onSubmit = { target, _ in submitted.append(target) }
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
/// With `gateFirstEngageOnly`, only the FIRST engage is gated and later engages
/// succeed immediately, so a test can park one call while two further transitions
/// run to completion (the ABA case).
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
  func measuredHDREnabled(displayID _: CGDirectDisplayID) -> Bool { enabledState }

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

// MARK: - Backlog trio

/// Fails the first engage, then parks the rollback's `refreshHDRCaches` inside
/// `supportsHDR` so a newer transition can start while the failure arm is
/// suspended.
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
  func measuredHDREnabled(displayID _: CGDirectDisplayID) -> Bool { enabled }

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
@Suite("Engage-failure re-guard")
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
      displayID: 11,
      wireSiblings: []
    )
    controller.settleDelay = .milliseconds(10)
    nonisolated(unsafe) var submitCount = 0
    controller._onSubmit = { _, _ in submitCount += 1 }
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
@Suite("Park-at-s exemption")
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
@Suite("Settle skipped when HDR already externally live")
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
    // The door trusts cachedHDRActive, but the user can toggle HDR off in System
    // Settings and click Always On before the reconfigure-driven cache refresh
    // lands. Committing `.alwaysOn` without engaging, and with no rollback, would
    // persist a lying mode, so the door re-checks after refreshHDRCaches and falls
    // through to the normal engage arm.
    let h = Harness(hdrEnabled: true, settle: .milliseconds(10))
    await h.prime() // cache: HDR live
    // External toggle the controller has NOT observed: the cache is now stale.
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
        applierNative: FakeNativeApplier(), hdr: gated, shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      wireSiblings: []
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
  func measuredHDREnabled(displayID _: CGDirectDisplayID) -> Bool { true }

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
