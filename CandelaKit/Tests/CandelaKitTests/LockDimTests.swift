import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Lock dim, re-scoped from an overlay to a hardware dim on 2026-08-07.
///
/// The overlay could not do the job: a `CGShieldingWindowLevel()` window does
/// not render above the macOS lock screen, MEASURED, and it reports itself on
/// screen while it is covered. These tests pin the replacement's two halves:
/// the decision (which displays can be dimmed on the leg driving them) and the
/// mechanism (a multiplier that never touches the value the user set).
@Suite("Lock dim (hardware delivery)")
@MainActor
struct LockDimTests {
  // MARK: - Harness

  private static let storageKey = "combinedBrightness.lock"

  private struct Rig {
    let ddc: FakeDDC
    let native: FakeNativeApplier
    let store: PathMemoryStore
    let controller: BrightnessController
  }

  private func makeRig(
    hdrEnabled: Bool = false,
    configure: (DisplayPrefs, UserDefaults) -> Void = { _, _ in }
  ) -> Rig {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "lock")
    configure(prefs, defaults)
    let ddc = FakeDDC(readResult: nil)
    let native = FakeNativeApplier()
    let store = PathMemoryStore()
    let controller = BrightnessController(
      writer: ddc,
      backends: BrightnessBackends(
        applierNative: native,
        hdr: FakeHDR(supports: true, enabled: hdrEnabled),
        shade: RecordingShade(),
        gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      role: .external,
      store: store,
      storageKey: Self.storageKey
    )
    return Rig(ddc: ddc, native: native, store: store, controller: controller)
  }

  /// Pure DDC: `disableCombinedBrightness` app-wide, so the whole range is on
  /// the register and a write's raw value is readable straight off the wire.
  private func makeHardwareRig() -> Rig {
    makeRig { _, defaults in defaults.set(true, forKey: "disableCombinedBrightness") }
  }

  // MARK: - The decision

  @Test func everyLiveLegAcceptsALockDim() {
    for path in [BrightnessPath.hardware,
                 .native,
                 .combined(switchingValue: 0.25, backend: .gamma),
                 .software(.gamma)] {
      #expect(
        LockDimPolicy.decide(path: path, brightness: 0.8, factor: 0.5)
          == .dim(factor: 0.5),
        "\(path) should dim"
      )
    }
  }

  /// The HDR case, stated as its own test because it is the one the ruling
  /// turns on: live HDR locks the DDC brightness register, so the path is
  /// `.native` and the dim rides DisplayServices instead of being skipped.
  /// Lock dim uses exactly the leg the user's own slider uses, so it cannot be
  /// deader than the slider.
  @Test func hdrDisplaysDimOnTheNativeLegRatherThanBeingSkipped() async {
    let rig = makeRig(hdrEnabled: true)
    await rig.controller.initialHDRRefresh?.value
    await rig.controller.noteHDRStateMayHaveChanged()
    #expect(rig.controller.brightnessPath == .native)
    rig.controller.setBrightness(0.8)
    rig.controller.beginTemporaryDim(factor: 0.5)
    await rig.controller.waitForPendingWrites()
    let natives = rig.native.targets().compactMap { target -> Float? in
      if case let .native(value) = target { return value }
      return nil
    }
    #expect(natives.last == 0.4)
    #expect(await rig.ddc.recordedWrites().isEmpty)
  }

  @Test func aDisplayNothingDrivesIsSkippedRatherThanReportedDimmed() {
    #expect(
      LockDimPolicy.decide(
        path: .unavailable(.ddcTurnedOffWithNoSoftwareLeg), brightness: 0.8, factor: 0.5
      ) == .skip(.nothingDrivesBrightness)
    )
  }

  /// Combined mode with its DDC half turned off holds the software leg flat at
  /// 1 above the band, so a dim that stays above it is accepted and changes
  /// nothing. That is the accept-and-ignore class, and it gets a skip.
  @Test func aDimThatWouldStayAboveTheSoftwareBandIsSkipped() {
    let path = BrightnessPath.softwareOnly(
      backend: .gamma, reason: .ddcTurnedOff, dimsBelow: 0.25
    )
    #expect(
      LockDimPolicy.decide(path: path, brightness: 0.9, factor: 0.5)
        == .skip(.outsideSoftwareBand)
    )
    // Same display, a value whose dim DOES cross into the band.
    #expect(
      LockDimPolicy.decide(path: path, brightness: 0.4, factor: 0.5)
        == .dim(factor: 0.5)
    )
  }

  @Test func aDisplayAlreadyAtZeroHasNothingToDim() {
    #expect(
      LockDimPolicy.decide(path: .hardware, brightness: 0, factor: 0.5)
        == .skip(.alreadyAtTarget)
    )
    #expect(
      LockDimPolicy.decide(path: .hardware, brightness: 0.5, factor: 1)
        == .skip(.alreadyAtTarget)
    )
  }

  /// Ruling D (locking never brightens) is arithmetic here rather than a
  /// comparison someone has to remember: the dim is a fraction of whatever the
  /// user set, so a dark display gets darker and never lighter.
  @Test func theDimIsAFractionOfTheUsersValueSoItCannotBrighten() {
    let factor = LockDimPolicy.factor(forBrightness: 0.5)
    for brightness in stride(from: 0.05, through: 1.0, by: 0.05) {
      #expect(brightness * factor <= brightness)
    }
    // The setting is HOW BRIGHT to leave the display (2026-08-07), so the
    // number and the multiplier are the same: 10% is DARKEST, 90% is mildest.
    // Before the flip this returned the complement, and the two directions are
    // pinned here so a regression cannot pass by reading plausibly.
    #expect(abs(LockDimPolicy.factor(forBrightness: 0.1) - 0.1) < 1e-9)
    #expect(abs(LockDimPolicy.factor(forBrightness: 0.9) - 0.9) < 1e-9)
    // Out-of-range values are clamped to the same window the config accepts,
    // so no caller can produce a factor of 0 (a display turned off) or 1.
    #expect(abs(LockDimPolicy.factor(forBrightness: 5) - 0.9) < 1e-9)
    #expect(abs(LockDimPolicy.factor(forBrightness: -5) - 0.1) < 1e-9)
  }

  // MARK: - The mechanism

  @Test func lockingDimsTheWire() async {
    let rig = makeHardwareRig()
    rig.controller.setBrightness(0.8)
    await rig.controller.waitForPendingWrites()
    rig.controller.beginTemporaryDim(factor: 0.5)
    await rig.controller.waitForPendingWrites()
    #expect(await rig.ddc.recordedWrites().last?.value == 40)
  }

  /// Asserted as the whole SEQUENCE, not just the final value: an engine that
  /// never dimmed at all would end on 80 too, so a last-write check cannot fail
  /// for the reason it claims.
  @Test func unlockingRestoresTheExactValue() async {
    let rig = makeHardwareRig()
    rig.controller.setBrightness(0.8)
    await rig.controller.waitForPendingWrites()
    rig.controller.beginTemporaryDim(factor: 0.5)
    await rig.controller.waitForPendingWrites()
    rig.controller.endTemporaryDim()
    await rig.controller.waitForPendingWrites()
    #expect(await rig.ddc.recordedWrites().map(\.value) == [80, 40, 80])
    #expect(rig.controller.temporaryDimFactor == nil)
  }

  /// The published value and the persisted store are the user's, never the
  /// dim's. This is what makes the restore exact on a write-only panel (the
  /// MAG answers no DDC read, so last-written IS the truth) and what keeps a
  /// process that dies mid-dim from reopening dim forever.
  @Test func theDimNeverTouchesThePublishedValueOrTheStore() async {
    let rig = makeHardwareRig()
    rig.controller.setBrightness(0.8)
    rig.controller.beginTemporaryDim(factor: 0.5)
    await rig.controller.waitForPendingWrites()
    #expect(rig.controller.brightness == 0.8)
    #expect(rig.store.values[Self.storageKey] == 0.8)
  }

  /// A readback that lands mid-dim reads OUR OWN write. Adopting it folds the
  /// dim into the user's value and persists it, so the corruption survives the
  /// quit and `endTemporaryDim` "restores" to the corrupted number. The path is
  /// not hypothetical: `AppModel.performRefresh`'s kept branch calls
  /// `refreshFromHardware` on every reconfiguration, and a lock dim outlasts
  /// one. Only a panel that ANSWERS reads can be hit (the Dell here; the MAG
  /// answers nothing), which is why this is pinned rather than left to the
  /// hardware pass.
  @Test func aReadbackDuringTheDimAdoptsNothing() async {
    let rig = makeHardwareRig()
    rig.controller.setBrightness(0.8)
    await rig.controller.waitForPendingWrites()
    rig.controller.beginTemporaryDim(factor: 0.5)
    await rig.controller.waitForPendingWrites()
    // What the panel would now answer: the register carries the dimmed value.
    await rig.ddc.setReadResult((current: 40, max: 100))
    await rig.controller.refreshFromHardware()
    #expect(rig.controller.brightness == 0.8)
    #expect(rig.store.values[Self.storageKey] == 0.8)
    // And the restore is still the user's value, not the read one.
    rig.controller.endTemporaryDim()
    await rig.controller.waitForPendingWrites()
    #expect(await rig.ddc.recordedWrites().map(\.value) == [80, 40, 80])
  }

  /// A slider moved while the screen is locked composes with the dim instead of
  /// fighting it: the wire follows the new value scaled, and the unlock
  /// restores the NEW value. Nothing has to notice the collision, because the
  /// dim is a multiplier on the way out rather than a value someone stored.
  @Test func aBrightnessChangeDuringTheDimIsWhatGetsRestored() async {
    let rig = makeHardwareRig()
    rig.controller.setBrightness(0.8)
    rig.controller.beginTemporaryDim(factor: 0.5)
    await rig.controller.waitForPendingWrites()
    rig.controller.setBrightness(0.6)
    await rig.controller.waitForPendingWrites()
    #expect(await rig.ddc.recordedWrites().last?.value == 30)
    rig.controller.endTemporaryDim()
    await rig.controller.waitForPendingWrites()
    #expect(await rig.ddc.recordedWrites().last?.value == 60)
    #expect(rig.controller.brightness == 0.6)
  }

  /// A reconfiguration mid-lock (a replug, a sibling display's HDR flip, a bus
  /// drop) re-runs the SOFTWARE leg for the current value. It must re-run it
  /// dimmed: an undimmed software leg over a hardware leg still holding the dim
  /// is a partially lifted dim on a locked screen, and the coordinator's
  /// per-tick re-assert cannot repair it, because `beginTemporaryDim` no-ops on
  /// an unchanged factor.
  @Test func aReconfigurationDuringTheDimReAppliesTheSoftwareLegDimmed() async {
    // Combined path: the software leg carries everything below the switching
    // point, so a dim that lands there is visible in the gamma scale.
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "lock")
    let gamma = RecordingGamma()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: FakeHDR(supports: false, enabled: false),
        shade: RecordingShade(), gamma: gamma
      ),
      prefs: prefs,
      displayID: 7,
      role: .external,
      store: PathMemoryStore(),
      storageKey: Self.storageKey
    )
    controller.setBrightness(0.2)
    controller.beginTemporaryDim(factor: 0.5)
    await controller.waitForPendingWrites()
    let dimmed = gamma.scales.last
    await controller.handleReconfigure(recapture: false)
    #expect(gamma.scales.last == dimmed)
  }

  /// Teardown restore: the quit path writes the register's full-range
  /// equivalent of the PUBLISHED value, so a quit while lock-dimmed hands the
  /// panel back rather than leaving it dark with nobody left to restore it.
  @Test func quittingWhileDimmedWritesTheUndimmedValue() async {
    let rig = makeHardwareRig()
    rig.controller.setBrightness(0.8)
    await rig.controller.waitForPendingWrites()
    rig.controller.beginTemporaryDim(factor: 0.5)
    await rig.controller.waitForPendingWrites()
    #expect(await rig.ddc.recordedWrites().map(\.value) == [80, 40])
    rig.controller.endTemporaryDim() // what the coordinator does at termination
    rig.controller.restoreFullRangeDDC()
    await rig.controller.waitForPendingWrites()
    // Three writes, not four: the quit path's two restores are the same value
    // and the coalescer is latest-wins, so they land as one. What matters is
    // that the panel is left at the user's 80 rather than the dim's 40.
    #expect(await rig.ddc.recordedWrites().map(\.value) == [80, 40, 80])
  }

  /// Ending a dim nobody started is a no-op, which is what lets every teardown
  /// path (unlock, departure, reset, quit) call it unconditionally instead of
  /// each keeping its own record of whether one is outstanding.
  @Test func endingADimThatWasNeverStartedWritesNothing() async {
    let rig = makeHardwareRig()
    rig.controller.setBrightness(0.8)
    await rig.controller.waitForPendingWrites()
    let before = await rig.ddc.recordedWrites().count
    rig.controller.endTemporaryDim()
    await rig.controller.waitForPendingWrites()
    #expect(await rig.ddc.recordedWrites().count == before)
  }

  // MARK: - The dim-in ramp

  @Test func theRampDescendsMonotonicallyAndLandsExactlyOnTheTarget() {
    let factors = LockDimRamp.factors(to: 0.5)
    #expect(factors.count == LockDimRamp.steps)
    #expect(factors.last == 0.5)
    #expect(factors.first! < 1)          // the first step is a real change
    #expect(factors.first! > factors.last!)
    for (previous, next) in zip(factors, factors.dropFirst()) {
      #expect(next < previous, "the fade must never brighten")
    }
    // Nothing to fade to is an EMPTY sequence, so no caller can walk a ramp
    // that ends brighter than it started.
    #expect(LockDimRamp.factors(to: 1).isEmpty)
    #expect(LockDimRamp.factors(to: 1.5).isEmpty)
    #expect(LockDimRamp.duration == .milliseconds(1200))
  }

  @Test func theRampWritesADescendingSequenceEndingAtTheTarget() async {
    let rig = makeHardwareRig()
    rig.controller.lockDimRampInterval = .milliseconds(1)
    rig.controller.setBrightness(1.0)
    await rig.controller.waitForPendingWrites()
    await rig.controller.rampTemporaryDim(to: 0.5).value
    await rig.controller.waitForPendingWrites()
    let written = await rig.ddc.recordedWrites().map(\.value)
    #expect(written.first == 100)
    #expect(written.last == 50)
    // Latest-wins coalescing may drop intermediate steps at a 1 ms test
    // interval, so this asserts the SHAPE the user sees rather than a count:
    // never brighter than the step before, and it arrives at the target.
    for (previous, next) in zip(written, written.dropFirst()) {
      #expect(next <= previous)
    }
    #expect(written.count > 2, "a ramp, not a jump")
  }

  /// The lift has to work MID-ramp, not just after it. Two properties, and the
  /// second is the one a cancel alone would not give: the restore is exact, and
  /// no step that was already suspended when the user unlocked lands afterwards
  /// and re-dims the screen they just came back to.
  @Test func cancellingMidRampRestoresTheExactValueAndNoLaterStepLands() async {
    let rig = makeHardwareRig()
    rig.controller.lockDimRampInterval = .milliseconds(20)
    rig.controller.setBrightness(0.8)
    await rig.controller.waitForPendingWrites()
    let ramp = rig.controller.rampTemporaryDim(to: 0.1)
    try? await Task.sleep(for: .milliseconds(50)) // a few steps in, not finished
    let midRamp = rig.controller.temporaryDimFactor
    #expect(midRamp != nil && midRamp! < 1 && midRamp! > 0.1, "should be mid-fade")

    rig.controller.endTemporaryDim() // what the unlock and the input lift do
    await rig.controller.waitForPendingWrites()
    #expect(rig.controller.temporaryDimFactor == nil)
    #expect(await rig.ddc.recordedWrites().last?.value == 80)

    // Deliberately NOT cancelled: the token has to be what stops it, so let the
    // remaining steps run out and confirm none of them reached the wire.
    _ = await ramp.value
    await rig.controller.waitForPendingWrites()
    #expect(rig.controller.temporaryDimFactor == nil)
    #expect(await rig.ddc.recordedWrites().last?.value == 80)
  }

  /// The lift promise is 100 ms, and a lock dim raises no overlay, so the
  /// cadence has to count it as a dim that is up. It did not: the wire-
  /// delivered dim ticked every 2 s, which is what the user typing their
  /// password would have waited for the brightness to come back.
  @Test func aLockDimHoldsTheFastCadenceEvenThoughItRaisesNoOverlay() {
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: false, anyLockDimEngaged: true, verificationPending: false
      ) == OledCareCadence.fast
    )
    // The other terms still stand on their own, and nothing wanted is slow.
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: true, anyLockDimEngaged: false, verificationPending: false
      ) == OledCareCadence.fast
    )
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: false, anyLockDimEngaged: false, verificationPending: true
      ) == OledCareCadence.fast
    )
    #expect(
      OledCareCadence.interval(
        anyOverlayUp: false, anyLockDimEngaged: false, verificationPending: false
      ) == OledCareCadence.slow
    )
    #expect(OledCareCadence.fast == .milliseconds(100))
  }

  /// The engine can no longer ask for a lock-dim OVERLAY at all. The delivery
  /// ruling is structural rather than a convention the coordinator honours.
  @Test func theOverlayLayerCannotProduceALockDim() {
    let engine = IdleDimmingEngine(config: OledDimConfig(
      idleDimSeconds: 300, idleDimBrightness: 0.2, lockDim: true,
      blackoutEnabled: false, blackoutSeconds: 1200,
      unfocusedDimEnabled: false, unfocusedDimSeconds: 600, unfocusedDimBrightness: 0.7
    ))
    #expect(engine.alpha(for: .lockDim) == nil)
    // Asymmetric on purpose: at 0.5 the flip is invisible because the value is
    // its own complement, which is exactly how an inverted mapping ships. A
    // dim TO 20% brightness is an 80% opaque overlay.
    #expect(abs(engine.alpha(for: .idleDim)! - 0.8) < 1e-9)
    #expect(abs(engine.lockDimFactor - 0.2) < 1e-9)
  }
}
