import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// HDR that is off when the recovery asks for its licence and on when it asks
/// for its confirmation. The panel moves between the two MEASURED reads, which
/// is the only interleaving where the unmute goes out and is swallowed.
actor EngagesAfterFirstMeasureHDR: HDRToggling {
  private var measures = 0

  func supportsHDR(displayID _: CGDirectDisplayID) -> Bool { true }
  func isHDREnabled(displayID _: CGDirectDisplayID) -> Bool { false }

  func measuredHDREnabled(displayID _: CGDirectDisplayID) -> Bool {
    measures += 1
    return measures > 1
  }

  @discardableResult
  func setHDR(displayID _: CGDirectDisplayID, enabled _: Bool) -> Bool { true }
  func displaysReconfigured() {}
}

/// The banner recovery's ordering and its evidence rules (D29). The reset path's
/// equivalent lives in the app target and so has never had a test; this is the
/// same discipline expressed where it can be pinned.
@Suite("Stranded mute recovery (D29)")
@MainActor
struct StrandedMuteRecoveryTests {
  /// A muted volume queue on its own wire, plus the HDR owner whose measured
  /// read licenses the write. The two fakes are separate on purpose: the
  /// question every test here asks is what reached the VOLUME register, and a
  /// shared recorder would mix the brightness leg's traffic into the answer.
  @MainActor
  private final class Rig {
    let volumeDDC = FakeDDC(readResult: nil) // write-only, MAG parity
    let harness: Harness
    let volume: DDCValueController
    let store = PathMemoryStore()
    /// Recorded rather than asserted inline: the ORDER against the wire is the
    /// D29 rule, so the test needs both events on one timeline.
    private(set) var reopenedAtWriteCount: Int?

    init(hdrEnabled: Bool = false, muted: Bool = true, dedicatedMuteCommand: Bool = true) {
      var built: DDCValueController?
      let volumeDDC = volumeDDC
      let store = store
      harness = Harness(hdrEnabled: hdrEnabled) { prefs, _ in
        prefs.muted = muted
        prefs.enableMuteUnmute = dedicatedMuteCommand
      } wireSiblings: { prefs in
        let controller = DDCValueController(
          writer: volumeDDC, command: .volume, prefs: prefs,
          store: store, storageKey: "volume.t", panelIdentity: nil
        )
        controller.setMuteWireSupport { .supported }
        built = controller
        return [controller]
      }
      // Force-unwrapped rather than optional-chained through every test: the
      // closure above runs during the harness's own init, so nil here is a
      // harness change and not a state a test can reach.
      volume = built!
    }

    func prime() async { await harness.prime() }

    func recover() async -> StrandedMuteOutcome {
      await StrandedMuteRecovery.recover(
        volume: volume,
        hdrOwner: harness.controller,
        // Short enough that the unsettled case does not spend two seconds
        // proving it, long enough to be the same code path.
        settlePause: .milliseconds(5)
      ) { [self] in
        reopenedAtWriteCount = volumeDDC.landedWriteCount()
      }
    }

    func volumeWrites() async -> [(command: UInt8, value: UInt16)] {
      await volumeDDC.recordedWrites()
    }

    func muteWires() async -> [UInt16] {
      await volumeWrites().filter { $0.command == VCP.audioMuteScreenBlank }.map(\.value)
    }
  }

  @Test("the routes reopen before anything is sent, and before the HDR question")
  func theRoutesReopenFirst() async {
    let rig = Rig()
    await rig.prime()
    _ = await rig.recover()
    #expect(rig.reopenedAtWriteCount == 0)
  }

  @Test("the routes reopen even when HDR blocks the unmute (D29 rule 2)")
  func theRoutesReopenUnderLiveHDR() async {
    let rig = Rig(hdrEnabled: true)
    await rig.prime()
    let outcome = await rig.recover()
    #expect(outcome == .blockedByHDR)
    #expect(rig.reopenedAtWriteCount == 0)
  }

  /// The bug: DDC is dead under HDR, the panel keeps its silence, and the old
  /// path cleared `isMuted` anyway so the banner hid over a display that was
  /// still muted.
  @Test("live HDR sends no unmute and leaves the mute standing")
  func liveHDRLeavesTheMuteStanding() async {
    let rig = Rig(hdrEnabled: true)
    await rig.prime()
    let outcome = await rig.recover()
    #expect(outcome == .blockedByHDR)
    #expect(rig.volume.isMuted)
    #expect(rig.harness.prefs.muted)
    #expect(await rig.muteWires().isEmpty)
  }

  /// HDR the controller has not heard about yet: a System Settings toggle whose
  /// reconfiguration has not been delivered. The cached mirror still says off,
  /// so only a measured read can catch it.
  @Test("HDR engaged behind the mirror is still caught, because the read is measured")
  func hdrBehindTheMirrorIsCaught() async {
    let rig = Rig()
    await rig.prime()
    await rig.harness.hdr?.stubEnabled(true)
    #expect(rig.harness.controller.isHDREngaged == false) // the mirror is stale, which is the point
    let outcome = await rig.recover()
    #expect(outcome == .blockedByHDR)
    #expect(rig.volume.isMuted)
  }

  @Test("with HDR off and the wire settling, the unmute is sent and reported")
  func aSettledUnmuteIsReported() async {
    let rig = Rig()
    await rig.prime()
    let outcome = await rig.recover()
    #expect(outcome == .unmuted)
    #expect(rig.volume.isMuted == false)
    #expect(rig.harness.prefs.muted == false)
    #expect(await rig.muteWires() == [2])
  }

  /// The race the second read exists for: the write is queued, HDR engages
  /// while it is in flight, and the panel swallows it while the applier reports
  /// success. Nothing in the ACK can see this.
  ///
  /// Built from the read counter rather than from a sleep: "engaged between the
  /// two reads" IS the window, and timing it against the settle would be a bet
  /// on a duration nobody measured.
  @Test("HDR that engages while the unmute is in flight leaves the mute standing")
  func hdrEngagingMidFlightIsUnconfirmed() async {
    let hdr = EngagesAfterFirstMeasureHDR()
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "t")
    prefs.muted = true
    prefs.enableMuteUnmute = true
    let volumeDDC = FakeDDC(readResult: nil)
    let volume = DDCValueController(
      writer: volumeDDC, command: .volume, prefs: prefs,
      store: PathMemoryStore(), storageKey: "volume.t", panelIdentity: nil
    )
    volume.setMuteWireSupport { .supported }
    let controller = BrightnessController(
      writer: FakeDDC(readResult: nil),
      backends: BrightnessBackends(
        applierNative: FakeNativeApplier(), hdr: hdr,
        shade: RecordingShade(), gamma: RecordingGamma()
      ),
      prefs: prefs, displayID: 7, role: .external,
      store: PathMemoryStore(), storageKey: "combinedBrightness.t", legacyKey: "brightness.t",
      wireSiblings: [volume]
    )
    await controller.initialHDRRefresh?.value

    let outcome = await StrandedMuteRecovery.recover(
      volume: volume, hdrOwner: controller, settlePause: .milliseconds(5)
    ) {}
    #expect(outcome == .unconfirmed)
    #expect(volume.isMuted)
    #expect(prefs.muted)
    // The unmute DID go out: this is the case where the app has to say it
    // cannot vouch for a write it made, not one where it declined to write.
    #expect(await volumeDDC.recordedWrites().contains { $0.command == VCP.audioMuteScreenBlank })
  }

  @Test("a wire that cannot be settled leaves the mute standing")
  func anUnsettledWireIsUnconfirmed() async {
    let rig = Rig()
    await rig.prime()
    await rig.volumeDDC.setWritesSucceed(false)
    let outcome = await rig.recover()
    #expect(outcome == .unconfirmed)
    #expect(rig.volume.isMuted)
    #expect(rig.harness.prefs.muted)
  }

  /// The contract's own failure mode: a caller whose `reopenRoutes` does not
  /// open them leaves `toggleMute` refusing silently, and an empty queue settles
  /// perfectly. Reporting `.unmuted` off that would be this bug again.
  @Test("an unmute that never reached the wire is not reported as done")
  func aRefusedUnmuteIsNotReportedAsDone() async {
    let rig = Rig()
    rig.harness.prefs.forceSoftware = true // the routes stay shut
    await rig.prime()
    let outcome = await StrandedMuteRecovery.recover(
      volume: rig.volume, hdrOwner: rig.harness.controller, settlePause: .milliseconds(5)
    ) {}
    #expect(outcome == .unconfirmed)
    #expect(rig.volume.isMuted)
    #expect(await rig.muteWires().isEmpty)
  }

  @Test("an unmuted display is not written to")
  func anUnmutedDisplayIsUntouched() async {
    let rig = Rig(muted: false)
    await rig.prime()
    let outcome = await rig.recover()
    #expect(outcome == .notMuted)
    #expect(await rig.volumeWrites().isEmpty)
  }

  /// Re-entry while the first recovery is still awaiting its settle. The second
  /// call must not drive a second unmute pair onto the wire.
  @Test("a second click during the settle sends nothing more")
  func aSecondClickDuringTheSettleIsInert() async {
    let rig = Rig()
    await rig.prime()
    async let first = rig.recover()
    async let second = rig.recover()
    _ = await (first, second)
    #expect(await rig.muteWires() == [2])
  }
}

@Suite("Unconfirmed-mute reassertion")
@MainActor
struct ReassertUnconfirmedMuteTests {
  private func makeVolume(muted: Bool) -> (DDCValueController, FakeDDC, DisplayPrefs) {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
    prefs.muted = muted
    let fake = FakeDDC(readResult: nil)
    let controller = DDCValueController(
      writer: fake, command: .volume, prefs: prefs,
      store: PathMemoryStore(), storageKey: "volume.pk", panelIdentity: nil
    )
    return (controller, fake, prefs)
  }

  /// A second write would be a second unconfirmed write rather than evidence,
  /// and on a locked register it is also how a memo gets poisoned.
  @Test("reasserting the mute touches no register")
  func reassertingWritesNothing() async {
    let (volume, fake, prefs) = makeVolume(muted: true)
    _ = volume.toggleMute()
    await volume.waitForPendingWrites()
    let before = await fake.recordedWrites().count
    #expect(volume.reassertUnconfirmedMute())
    await volume.waitForPendingWrites()
    #expect(await fake.recordedWrites().count == before)
    #expect(volume.isMuted)
    #expect(prefs.muted)
  }

  /// Both halves move together: the persisted flag is what survives a relaunch,
  /// and the live one is what keeps the recovery affordance on screen.
  @Test("an already-muted controller is left alone")
  func anAlreadyMutedControllerIsUntouched() {
    let (volume, _, _) = makeVolume(muted: true)
    #expect(volume.isMuted)
    #expect(volume.reassertUnconfirmedMute() == false)
  }

  @Test("a non-volume command has no mute to reassert")
  func aNonVolumeCommandIsUntouched() {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
    let contrast = DDCValueController(
      writer: FakeDDC(readResult: nil), command: .contrast, prefs: prefs,
      store: PathMemoryStore(), storageKey: "contrast.pk", panelIdentity: nil
    )
    #expect(contrast.reassertUnconfirmedMute() == false)
    #expect(prefs.muted == false)
  }
}
