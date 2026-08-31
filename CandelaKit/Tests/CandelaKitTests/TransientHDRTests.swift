import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// Polls until `condition` holds or ~1 s elapses. Its own copy rather than a
/// shared one: the transition runs on the main actor, so each suspension is
/// what lets it make progress, and the sibling suite's version is private.
@MainActor
private func settles(_ condition: @MainActor () async -> Bool) async -> Bool {
  for _ in 0 ..< 1000 {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return false
}

@Suite("Transient HDR (the link bounce's leg)") @MainActor
struct TransientHDRTests {
  private struct Rig {
    let controller: BrightnessController
    let hdr: FakeHDR
    let volume: MemoInvalidationRecorder
    let contrast: MemoInvalidationRecorder
    let prefs: DisplayPrefs
  }

  private func rig(role: DisplayRole = .external, enabled: Bool = false) async -> Rig {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "transient")
    let hdr = FakeHDR(enabled: enabled)
    let volume = MemoInvalidationRecorder()
    let contrast = MemoInvalidationRecorder()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: hdr,
        shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      role: role,
      wireSiblings: [volume, contrast]
    )
    controller.settleDelay = .milliseconds(1)
    await controller.initialHDRRefresh?.value
    return Rig(controller: controller, hdr: hdr, volume: volume, contrast: contrast, prefs: prefs)
  }

  /// The happy round trip, and the two things it must NOT do: write a pref, and
  /// leave the settle flag raised.
  @Test func aRoundTripReportsTheMeasuredStateAndWritesNoPref() async {
    let rig = await rig()

    let wentOn = await rig.controller.setTransientHDR(true)
    #expect(wentOn)
    #expect(rig.controller.isHDREngaged)
    #expect(!rig.controller.isHDRSettling)

    let cameOff = await rig.controller.setTransientHDR(false)
    #expect(cameOff)
    #expect(!rig.controller.isHDREngaged)
    #expect(!rig.controller.isHDRSettling)

    #expect(await rig.hdr.recordedSetCalls() == [true, false])
    // A link renegotiation is not a preference. Left standing, `hdrMode` would
    // survive a relaunch and re-engage HDR on a display nobody asked to be in
    // it.
    #expect(rig.prefs.hdrMode == .off)
    #expect(rig.controller.hdrMode == .off)
  }

  /// The memo drop fires on BOTH legs, unconditionally. `refreshHDRCaches`'s
  /// true-to-false edge only sees a window some refresh caught live, and a
  /// bounce can open and close between two refreshes, leaving every value
  /// written into a locked register recorded as landed and skipped next time.
  @Test func bothLegsDropTheWiresDuplicateMemos() async {
    let rig = await rig()
    // Baselined AFTER construction, so nothing the init refresh happened to do
    // can stand in for what the legs do.
    let baseline = rig.volume.memoResets

    await rig.controller.setTransientHDR(true)
    let afterOn = rig.volume.memoResets
    #expect(afterOn > baseline, "the entry leg drops them too, which the observed edge never does")

    await rig.controller.setTransientHDR(false)
    #expect(rig.volume.memoResets > afterOn)
    #expect(rig.contrast.memoResets == rig.volume.memoResets, "every queue on the wire, not just one")
  }

  /// The optimistic mirror is written BEFORE the await, which is the half that
  /// keeps DDC off the wire: the brightness legs have to stop treating the
  /// register as reachable while the display enters HDR, not after it has.
  @Test func thePathMirrorMovesBeforeTheWriteIsAwaited() async {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "transient-gated")
    let gated = GatedTransitionHDR()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: gated,
        shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      wireSiblings: []
    )
    controller.settleDelay = .milliseconds(1)
    await controller.initialHDRRefresh?.value

    let leg = Task { await controller.setTransientHDR(true) }
    #expect(await settles { await gated.engageCallCount() == 1 })

    // Parked inside the backend's write, and the controller already answers
    // native: `brightnessPath` is what `applyPaths` acts on, so a DDC write
    // issued in this window would go into a locked register.
    #expect(controller.isHDREngaged)
    #expect(controller.isHDRSettling)

    await gated.releaseEngage()
    _ = await leg.value
  }

  /// A superseded call establishes NOTHING, so it must not claim its leg
  /// landed, and it must leave the mirror assuming the register is locked. The
  /// alternative wrong answer licenses DDC and gamma writes onto a display that
  /// may be in HDR; this one costs a write that goes nowhere.
  @Test func aSupersededLegReportsFalseAndAssumesTheRegisterIsLocked() async {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "transient-superseded")
    let gated = GatedTransitionHDR()
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: gated,
        shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs,
      displayID: 7,
      wireSiblings: []
    )
    controller.settleDelay = .milliseconds(1)
    await controller.initialHDRRefresh?.value

    let leg = Task { await controller.setTransientHDR(false) }
    #expect(await settles { await gated.disengageCallCount() == 1 })
    // A newer transition takes the display while this leg is parked.
    let newer = Task { await controller.setHDRMode(.alwaysOn) }
    #expect(await settles { await gated.engageCallCount() == 1 })

    await gated.releaseDisengage()
    #expect(await leg.value == false)
    #expect(controller.isHDREngaged, "assume locked: the leg learned nothing about the panel")

    await gated.releaseEngage()
    await newer.value
  }

  /// The write is ACCEPTED and the display does not switch, which is a
  /// different fact from a write that was never issued. The leg reports the
  /// measured answer, never the ACK.
  @Test func aWriteTheDisplayDoesNotHonourReportsFalse() async {
    let rig = await rig()
    await rig.hdr.stubAchieves(false)

    let wentOn = await rig.controller.setTransientHDR(true)

    #expect(!wentOn)
    #expect(await rig.hdr.recordedSetCalls() == [true])
    #expect(!rig.controller.isHDREngaged)
  }

  /// The role fence. The built-in takes no DDC at all, so there is no register
  /// to unlock and nothing to renegotiate; `setHDRMode` returns early on the
  /// same test.
  @Test func theBuiltInTakesNoTransientHDRAtAll() async {
    let rig = await rig(role: .builtIn)

    #expect(await rig.controller.setTransientHDR(true) == false)
    #expect(await rig.hdr.recordedSetCalls().isEmpty)
  }

  /// The caller's settle, not the controller's: six legs of a link bounce pay
  /// this window six times inside one gate claim, so the caller is the one that
  /// has to state its own worst case.
  @Test func theSettleWindowIsTheCallersToName() async {
    let rig = await rig()
    rig.controller.settleDelay = .seconds(60)

    // Would take a minute on the controller's own window; returns immediately
    // on the caller's.
    let started = ContinuousClock.now
    await rig.controller.setTransientHDR(true, settle: .milliseconds(1))
    #expect(ContinuousClock.now - started < .seconds(5))
  }
}
