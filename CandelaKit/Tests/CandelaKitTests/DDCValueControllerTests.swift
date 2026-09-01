import Foundation
import os
import Testing
@testable import CandelaKit

@Suite("DDCValueController")
@MainActor
struct DDCValueControllerTests {
  /// Per-test throwaway defaults and memory store; never .standard.
  @MainActor
  private final class Harness {
    let defaults: UserDefaults
    let prefs: DisplayPrefs
    let fake = FakeDDC(readResult: nil) // write-only panel by default (MAG parity)
    let store = PathMemoryStore()
    let controller: DDCValueController
    /// The display's own VCP 0x8D verdict from the capabilities probe. A var,
    /// not an init constant: the probe lands mid-session and the gate reads it live.
    var muteWireSupport: VCPSupport = .unknown
    /// The same, one register over: the verdict about the register this command
    /// writes (VCP 0x62 on volume). A var for the same reason.
    var valueWireSupport: VCPSupport = .unknown

    init(
      command: DDCCommand, savedValue: Double? = nil,
      writer: (any DDCWriting)? = nil, // e.g. ScriptedDDC for retry/failure tests
      panelIdentity: String? = nil, // only the rebind tests care which panel this is
      muteWireSupport: VCPSupport = .unknown,
      valueWireSupport: VCPSupport = .unknown,
      configure: (DisplayPrefs) -> Void = { _ in }
    ) {
      defaults = InMemoryDefaults()
      prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      configure(prefs)
      let storageKey = "\(command.rawValue).pk"
      if let savedValue { store.saveBrightness(savedValue, for: storageKey) }
      controller = DDCValueController(
        writer: writer ?? fake, command: command, prefs: prefs,
        store: store, storageKey: storageKey, panelIdentity: panelIdentity
      )
      self.muteWireSupport = muteWireSupport
      self.valueWireSupport = valueWireSupport
      controller.setMuteWireSupport { [weak self] in self?.muteWireSupport ?? .unknown }
      controller.setValueWireSupport { [weak self] in self?.valueWireSupport ?? .unknown }
    }

    func drainedWrites() async -> [(command: UInt8, value: UInt16)] {
      await controller.waitForPendingWrites()
      return await fake.recordedWrites()
    }
  }

  /// The constant-result `FakeDDC` cannot observe the retry loop (test-design F7)
  /// or a failed transaction (F8), so reads and write results are scripted here.
  private actor ScriptedDDC: DDCWriting {
    private(set) var readCount = 0
    private var reads: [(current: UInt16, max: UInt16)?]
    private var writeResults: [Bool]
    private(set) var writes: [(command: UInt8, value: UInt16)] = []
    /// Fires DURING the nth read, not between reads: that lands user input inside
    /// `refreshFromHardware`'s value loop, which is the F2 mute-generation pin.
    /// Firing between reads never reaches the case.
    private var hookAfterRead: Int?
    private var hook: (@Sendable () async -> Void)?

    init(
      reads: [(current: UInt16, max: UInt16)?] = [], writeResults: [Bool] = [],
      hookAfterRead: Int? = nil
    ) {
      self.reads = reads
      self.writeResults = writeResults
      self.hookAfterRead = hookAfterRead
    }

    func setHook(_ hook: @escaping @Sendable () async -> Void) { self.hook = hook }

    func write(command: UInt8, value: UInt16) async -> Bool {
      writes.append((command, value))
      return writeResults.isEmpty ? true : writeResults.removeFirst()
    }

    func read(command _: UInt8) async -> (current: UInt16, max: UInt16)? {
      readCount += 1
      let result = reads.isEmpty ? nil : reads.removeFirst()
      if readCount == hookAfterRead, let hook { await hook() }
      return result
    }

    func recordedWrites() -> [(command: UInt8, value: UInt16)] { writes }
  }

  // MARK: - Seeding

  @Test func volumeSeedsTheForkDefaultOfTwelvePointFivePercent() {
    #expect(Harness(command: .volume).controller.value == 0.125)
  }

  @Test func contrastSeedsTheForkDefaultOfSeventyFivePercent() {
    #expect(Harness(command: .contrast).controller.value == 0.75)
  }

  @Test func savedValueWinsOverTheDefault() {
    #expect(Harness(command: .volume, savedValue: 0.5).controller.value == 0.5)
  }

  @Test func mutedFlagSeedsFromPrefs() {
    let harness = Harness(command: .volume) { $0.muted = true }
    #expect(harness.controller.isMuted)
    #expect(Harness(command: .contrast) { $0.muted = true }.controller.isMuted == false)
  }

  // MARK: - setValue / step → wire

  @Test func setValueWritesTheConvertedRawOnTheCommandCode() async {
    let harness = Harness(command: .contrast)
    harness.controller.setValue(0.5)
    let writes = await harness.drainedWrites()
    #expect(writes.last?.command == VCP.contrast)
    #expect(writes.last?.value == 50)
    #expect(harness.controller.value == 0.5)
    #expect(harness.store.savedBrightness(for: "contrast.pk") == 0.5)
  }

  @Test func stepWalksOneChicletAndPersists() async {
    let harness = Harness(command: .contrast, savedValue: 0.5)
    let next = harness.controller.step(isUp: true, isFine: false)
    #expect(next == 0.5625)
    let writes = await harness.drainedWrites()
    #expect(writes.last?.value == 56) // truncating valueToDDC
    #expect(harness.store.savedBrightness(for: "contrast.pk") == 0.5625)
  }

  @Test func fineStepIsFlatPointZeroOne() {
    let harness = Harness(command: .volume, savedValue: 0.5)
    #expect(harness.controller.step(isUp: false, isFine: true) == 0.49)
  }

  @Test func volumeFloorsNonZeroRawToOne() async {
    let harness = Harness(command: .volume, savedValue: 0.0)
    harness.controller.setValue(0.004)
    let writes = await harness.drainedWrites()
    #expect(writes.last?.command == VCP.audioSpeakerVolume)
    #expect(writes.last?.value == 1) // never accidental digital 0
  }

  @Test func tuningShapesTheWire() async {
    let harness = Harness(command: .contrast) { prefs in
      var tuning = prefs.tuning(for: .contrast)
      tuning.minDDCOverride = 20
      tuning.maxDDCOverride = 80
      tuning.curveIndex = 7 // 1.5
      prefs.setTuning(tuning, for: .contrast)
    }
    harness.controller.setValue(0.5)
    // invert off: pow(0.5, 1.5) ≈ 0.35355 → (80-20)*0.35355+20 ≈ 41.2 → 41
    let writes = await harness.drainedWrites()
    #expect(writes.last?.value == 41)
  }

  @Test func invertFlipsTheRange() async {
    // Seeded at 0.5 because a fresh contrast controller seeds 0.75, and
    // setValue(0.75) would be value-deduped before it reached the wire.
    let harness = Harness(command: .contrast, savedValue: 0.5) { prefs in
      var tuning = prefs.tuning(for: .contrast)
      tuning.invert = true
      prefs.setTuning(tuning, for: .contrast)
    }
    harness.controller.setValue(0.75)
    #expect(await harness.drainedWrites().last?.value == 25)
  }

  @Test func remapFansOutAndReplacesTheCode() async {
    let harness = Harness(command: .contrast) { prefs in
      var tuning = prefs.tuning(for: .contrast)
      tuning.remapCodes = [0x10, 0x2F]
      prefs.setTuning(tuning, for: .contrast)
    }
    harness.controller.setValue(1.0)
    let writes = await harness.drainedWrites()
    #expect(writes.map(\.command) == [0x10, 0x2F])
  }

  @Test func disabledCommandNoOpsEverywhere() async {
    let harness = Harness(command: .volume, savedValue: 0.5) { prefs in
      var tuning = prefs.tuning(for: .volume)
      tuning.unavailableDDC = true
      prefs.setTuning(tuning, for: .volume)
    }
    #expect(harness.controller.isAvailable == false)
    #expect(harness.controller.step(isUp: true, isFine: false) == nil)
    harness.controller.setValue(0.9)
    _ = harness.controller.toggleMute(isFresh: true)
    harness.controller.restoreToHardware()
    #expect(await harness.drainedWrites().isEmpty)
    #expect(harness.controller.value == 0.5) // untouched
  }

  @Test func forceSoftwareDisplayNoOpsEverywhere() async {
    // Fork isSw() parity: forceSoftware means the DDC wire is broken, so the
    // volume/contrast surface must not keep writing to it on any path.
    let harness = Harness(command: .volume, savedValue: 0.5) { prefs in
      prefs.forceSoftware = true
      prefs.startupAction = .read
    }
    #expect(harness.controller.isAvailable == false)
    #expect(harness.controller.step(isUp: true, isFine: false) == nil)
    harness.controller.setValue(0.9)
    _ = harness.controller.toggleMute(isFresh: true)
    harness.controller.restoreToHardware()
    await harness.fake.setReadResult((current: 30, max: 100))
    await harness.controller.refreshFromHardware()
    #expect(await harness.drainedWrites().isEmpty)
    #expect(harness.controller.value == 0.5) // untouched, no read adoption either
  }

  @Test func unchangedValueSkipsTheWriteButRepeatRailPressesStillReturn() async {
    let harness = Harness(command: .volume, savedValue: 1.0)
    // At the top rail, stepping up returns 1.0 (HUD still flashes) but writes nothing.
    #expect(harness.controller.step(isUp: true, isFine: false) == 1.0)
    #expect(await harness.drainedWrites().isEmpty)
  }

  // MARK: - Mute (D3 semantics)

  @Test func muteDefaultStrategyWritesVolumeZeroAndPersistsTheFlag() async {
    let harness = Harness(command: .volume, savedValue: 0.5)
    let muted = harness.controller.toggleMute(isFresh: true)
    #expect(muted)
    #expect(harness.controller.isMuted)
    #expect(harness.prefs.muted) // logical flag persists in BOTH strategies
    let writes = await harness.drainedWrites()
    // Tuple arrays are not Equatable, so allSatisfy stands in for a comparison:
    // every write rode 0x62, no 0x8D traffic.
    #expect(writes.allSatisfy { $0.command == VCP.audioSpeakerVolume })
    #expect(writes.last?.value == 0)
    #expect(harness.controller.value == 0.5) // stored volume untouched — unmute restores it
  }

  @Test func muteWithEnableMuteUnmuteWritesWireOneAndNoVolume() async {
    let harness = Harness(command: .volume, savedValue: 0.5) { $0.enableMuteUnmute = true }
    _ = harness.controller.toggleMute(isFresh: true)
    let writes = await harness.drainedWrites()
    #expect(writes.count == 1)
    #expect(writes[0].command == VCP.audioMuteScreenBlank)
    #expect(writes[0].value == 1) // 1 = mute
  }

  @Test func unmuteWritesWireTwoThenRestoresTheSavedVolume() async {
    let harness = Harness(command: .volume, savedValue: 0.5) { prefs in
      prefs.enableMuteUnmute = true
      prefs.muted = true
    }
    let muted = harness.controller.toggleMute(isFresh: true)
    #expect(muted == false)
    let writes = await harness.drainedWrites()
    #expect(writes.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 2 })
    #expect(writes.contains { $0.command == VCP.audioSpeakerVolume && $0.value == 50 })
  }

  @Test func unmuteAtStoredZeroRestoresOneChiclet() async {
    let harness = Harness(command: .volume, savedValue: 0.0) { $0.muted = true }
    _ = harness.controller.toggleMute(isFresh: true)
    #expect(harness.controller.value == 1.0 / 16.0)
    #expect(harness.store.savedBrightness(for: "volume.pk") == 1.0 / 16.0)
    let writes = await harness.drainedWrites()
    #expect(writes.last?.command == VCP.audioSpeakerVolume)
    #expect(writes.last?.value == 6) // 6.25 truncates
  }

  @Test func muteTogglesOnFreshPressOnly() {
    let harness = Harness(command: .volume, savedValue: 0.5)
    #expect(harness.controller.toggleMute(isFresh: false) == false) // key-repeat: no toggle
    #expect(harness.controller.isMuted == false)
  }

  @Test func steppingToZeroMutesAndSteppingUpUnmutes() async {
    let harness = Harness(command: .volume, savedValue: 1.0 / 16.0) { $0.enableMuteUnmute = true }
    _ = harness.controller.step(isUp: false, isFine: false) // → 0
    #expect(harness.controller.isMuted)
    var writes = await harness.drainedWrites()
    // enableMuteUnmute: mute is 0x8D's job; volume 0 is never written.
    #expect(writes.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 1 })
    #expect(!writes.contains { $0.command == VCP.audioSpeakerVolume && $0.value == 0 })
    _ = harness.controller.step(isUp: true, isFine: false) // → 1/16, unmutes
    #expect(harness.controller.isMuted == false)
    writes = await harness.drainedWrites()
    #expect(writes.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 2 })
  }

  @Test func unmuteBySettingTheSameValueStillRewritesTheRegister() async {
    // Concurrency F5: muted under the default strategy, the register holds 0 while
    // `value` keeps the stored level. A click landing exactly on the stored value
    // must still rewrite, or the `changed` guard leaves the panel silent.
    let harness = Harness(command: .volume, savedValue: 0.5) { $0.muted = true }
    harness.controller.setValue(0.5)
    #expect(harness.controller.isMuted == false)
    let writes = await harness.drainedWrites()
    #expect(writes.last?.command == VCP.audioSpeakerVolume)
    #expect(writes.last?.value == 50)
  }

  // MARK: - Mute strategy switched mid-session (test-design F4; D2 supports live pref flips)

  @Test func strategySwitchToWireModeUnmutesWithWireTwoAndVolumeRestore() async {
    // Muted under the default strategy, then enableMuteUnmute flipped on: both the
    // wire-2 companion and the volume rewrite must go out, since the register
    // still holds the old strategy's 0.
    let harness = Harness(command: .volume, savedValue: 0.5)
    _ = harness.controller.toggleMute(isFresh: true) // volume-0 mute
    _ = await harness.drainedWrites()
    harness.prefs.enableMuteUnmute = true // live flip mid-session
    _ = harness.controller.toggleMute(isFresh: true)
    let writes = await harness.drainedWrites()
    #expect(writes.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 2 })
    #expect(writes.contains { $0.command == VCP.audioSpeakerVolume && $0.value == 50 })
  }

  @Test func strategySwitchToVolumeZeroModeUnmutesThroughTheVolumeWriteOnly() async {
    // Muted over 0x8D, pref flipped off, then unmute: the default strategy sends
    // no 0x8D, so the volume rewrite is the whole unmute. Hazard: the panel can
    // stay hardware-muted, which is why D29 rule 1 unmutes before the pref flip.
    let harness = Harness(command: .volume, savedValue: 0.5) { $0.enableMuteUnmute = true }
    _ = harness.controller.toggleMute(isFresh: true) // wire-1 mute
    _ = await harness.drainedWrites()
    harness.prefs.enableMuteUnmute = false
    _ = harness.controller.toggleMute(isFresh: true)
    let writes = await harness.drainedWrites()
    #expect(!writes.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 2 })
    #expect(writes.last?.command == VCP.audioSpeakerVolume)
    #expect(writes.last?.value == 50)
  }

  // MARK: - The display's own denial of VCP 0x8D (D24, one register over)

  @Test func dragToZeroOnADisplayThatDeniesTheMuteCommandWritesNoMuteWire() async {
    // The defect: the mute companion wrote 0x8D on the value-crossing path without
    // consulting the verdict, so a display listing no 0x8D got a refused write,
    // a persisted mute, and a muted HUD for silence nobody achieved.
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unsupported
    ) { $0.enableMuteUnmute = true }
    harness.controller.setValue(0)
    let writes = await harness.drainedWrites()
    #expect(!writes.contains { $0.command == VCP.audioMuteScreenBlank })
    // Degraded, not suppressed: the silence lands on the register the display
    // does advertise, which is also the one the drag pointed at.
    #expect(writes.count == 1)
    #expect(writes.first?.command == VCP.audioSpeakerVolume)
    #expect(writes.first?.value == 0)
    #expect(harness.controller.isMuted) // D3: the logical flag persists either way
    #expect(harness.prefs.muted)
  }

  @Test func steppingDownToZeroUnderTheDenialDegradesToTheVolumeRegister() async {
    let harness = Harness(
      command: .volume, savedValue: 1.0 / 16.0, muteWireSupport: .unsupported
    ) { $0.enableMuteUnmute = true }
    _ = harness.controller.step(isUp: false, isFine: false)
    #expect(harness.controller.isMuted)
    let writes = await harness.drainedWrites()
    #expect(!writes.contains { $0.command == VCP.audioMuteScreenBlank })
    #expect(writes.last?.command == VCP.audioSpeakerVolume)
    #expect(writes.last?.value == 0)
  }

  @Test func theMuteToggleDegradesToVolumeZeroWhereTheCommandIsDenied() async {
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unsupported
    ) { $0.enableMuteUnmute = true }
    #expect(harness.controller.toggleMute(isFresh: true))
    let writes = await harness.drainedWrites()
    #expect(!writes.contains { $0.command == VCP.audioMuteScreenBlank })
    #expect(writes.last?.command == VCP.audioSpeakerVolume)
    #expect(writes.last?.value == 0)
    #expect(harness.controller.value == 0.5) // stored level survives, as in the default strategy
  }

  @Test func unmutingIsNeverGatedByTheDisplaysDenial() async {
    // D29 rule 3, and why the gate is one-directional: the verdict can arrive
    // after a 0x8D mute was sent under `.unknown`, so the route back (toggle
    // and value crossing, both checked here) must not consult it.
    let toggled = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unsupported
    ) { prefs in
      prefs.enableMuteUnmute = true
      prefs.muted = true
    }
    #expect(toggled.controller.toggleMute(isFresh: true) == false)
    let toggleWrites = await toggled.drainedWrites()
    #expect(toggleWrites.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 2 })

    let raised = Harness(
      command: .volume, savedValue: 0.0, muteWireSupport: .unsupported
    ) { prefs in
      prefs.enableMuteUnmute = true
      prefs.muted = true
    }
    raised.controller.setValue(0.5)
    let raiseWrites = await raised.drainedWrites()
    #expect(raiseWrites.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 2 })
    #expect(raiseWrites.contains { $0.command == VCP.audioSpeakerVolume && $0.value == 50 })
  }

  @Test func restoreOfAMutedDisplayUnderTheDenialReassertsTheVolumeRegister() async {
    // The startup/wake half of the same defect. The dedicated-strategy restore
    // skips the value because the mute wire carries the silence; where the
    // display denies that wire, the skip leaves nothing muted at all.
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unsupported
    ) { prefs in
      prefs.enableMuteUnmute = true
      prefs.muted = true
    }
    harness.controller.restoreToHardware()
    let writes = await harness.drainedWrites()
    #expect(!writes.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 1 })
    #expect(writes.last?.command == VCP.audioSpeakerVolume)
    #expect(writes.last?.value == 0)
  }

  @Test func theUnmutedRestoreSendsWireTwoEvenWhereTheRegisterIsDenied() async {
    // An unmuted display's restore is what clears a 0x8D mute sent before the
    // verdict landed, so this wire must not consult the verdict. Gating it
    // passes every other test in this file, hence a test of its own.
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unsupported
    ) { $0.enableMuteUnmute = true }
    harness.controller.restoreToHardware()
    let writes = await harness.drainedWrites()
    #expect(writes.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 2 })
    #expect(writes.contains { $0.command == VCP.audioSpeakerVolume && $0.value == 50 })
  }

  // MARK: - The verdict landing after the restore that assumed one

  @Test func arestoreThatAssumedTheMuteCommandIsRedoneWhenTheDenialLands() async {
    // The launch window: the capabilities probe is asynchronous, and the
    // restore pass is dispatched from the same turn that finishes the refresh,
    // so the verdict is always absent when a muted display is restored.
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unknown
    ) { prefs in
      prefs.enableMuteUnmute = true
      prefs.muted = true
    }
    harness.controller.restoreToHardware()
    let assumed = await harness.drainedWrites()
    #expect(assumed.count == 1)
    #expect(assumed.first?.command == VCP.audioMuteScreenBlank) // the wrong register, unavoidably

    harness.muteWireSupport = .unsupported // the probe lands
    #expect(harness.controller.restoreIfMuteStrategyChanged())
    let corrected = await harness.drainedWrites()
    #expect(corrected.last?.command == VCP.audioSpeakerVolume)
    #expect(corrected.last?.value == 0) // the silence now lands somewhere
  }

  @Test func averdictThatChangesNothingRedoesNothing() async {
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unknown
    ) { prefs in
      prefs.enableMuteUnmute = true
      prefs.muted = true
    }
    harness.controller.restoreToHardware()
    let assumed = await harness.drainedWrites()
    harness.muteWireSupport = .supported // the display confirms the assumption
    #expect(harness.controller.restoreIfMuteStrategyChanged() == false)
    #expect((await harness.drainedWrites()).count == assumed.count)
  }

  @Test func aredoNeedsARestoreToHaveHappened() async {
    // Nothing was restored (`startupAction` is not `.write`, or this display
    // was never touched), so there is no assumption to supersede.
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unknown
    ) { prefs in
      prefs.enableMuteUnmute = true
      prefs.muted = true
    }
    harness.muteWireSupport = .unsupported
    #expect(harness.controller.restoreIfMuteStrategyChanged() == false)
    #expect((await harness.drainedWrites()).isEmpty)
  }

  @Test func anUnmutedDisplayHasNoRestoreToRedo() async {
    // The unmuted restore writes the value and the ungated wire 2, neither of
    // which the verdict decides, so a late answer supersedes nothing.
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unknown
    ) { $0.enableMuteUnmute = true }
    harness.controller.restoreToHardware()
    let restored = await harness.drainedWrites()
    harness.muteWireSupport = .unsupported
    #expect(harness.controller.restoreIfMuteStrategyChanged() == false)
    #expect((await harness.drainedWrites()).count == restored.count)
  }

  @Test func arebindDropsTheAssumptionWithTheRestOfTheServiceState() async {
    // The record names a restore issued over the service the rebind replaced, so
    // it drops with the memos. The rebinding pass runs its own restore.
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unknown
    ) { prefs in
      prefs.enableMuteUnmute = true
      prefs.muted = true
    }
    harness.controller.restoreToHardware()
    _ = await harness.drainedWrites()
    harness.controller.rebind(writer: harness.fake, panelIdentity: "other")
    harness.muteWireSupport = .unsupported
    #expect(harness.controller.restoreIfMuteStrategyChanged() == false)
  }

  @Test func theMuteReadbackIsSkippedWhereTheDisplayDeniesTheRegister() async {
    // Adopting a 0x8D read from a display that lists no 0x8D would record a mute
    // state nothing wrote. Only the value read happens; the mute loop never runs.
    let scripted = ScriptedDDC(reads: [(current: 50, max: 100), (current: 1, max: 2)])
    let harness = Harness(
      command: .volume, savedValue: 0.25, writer: scripted, muteWireSupport: .unsupported
    ) { prefs in
      prefs.enableMuteUnmute = true
      prefs.startupAction = .read
    }
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.value == 0.5) // the value read still lands
    #expect(harness.controller.isMuted == false)
    #expect(await scripted.readCount == 1)
  }

  @Test func anUnknownVerdictStillSendsTheDisplaysMuteCommand() async {
    // D24's other half: no evidence allows. The MAG answers every read with
    // zeros, so its verdict is permanently `.unknown` and its mute must be
    // untouched by this gate.
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unknown
    ) { $0.enableMuteUnmute = true }
    harness.controller.setValue(0)
    let writes = await harness.drainedWrites()
    #expect(writes.count == 1)
    #expect(writes.first?.command == VCP.audioMuteScreenBlank)
    #expect(writes.first?.value == 1)
  }

  @Test func theUserOverrideOutranksTheDisplaysDenial() async {
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unsupported
    ) { prefs in
      prefs.enableMuteUnmute = true
      prefs.audioSinkOverride = .forcePresent
    }
    harness.controller.setValue(0)
    let writes = await harness.drainedWrites()
    #expect(writes.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 1 })
  }

  @Test func aVerdictLandingMidSessionDecidesTheNextMute() async {
    // The capabilities probe is asynchronous and lands after the controller
    // exists, so the gate reads it at write time rather than at construction.
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .unknown
    ) { $0.enableMuteUnmute = true }
    harness.controller.setValue(0)
    #expect((await harness.drainedWrites()).contains {
      $0.command == VCP.audioMuteScreenBlank && $0.value == 1
    })
    harness.controller.setValue(0.5) // back up, so the next drag re-crosses
    _ = await harness.drainedWrites()
    harness.muteWireSupport = .unsupported // the probe lands
    harness.controller.setValue(0)
    let writes = await harness.drainedWrites()
    #expect(writes.last?.command == VCP.audioSpeakerVolume)
    #expect(writes.last?.value == 0)
  }

  // MARK: - Cross-coalescer isolation (test-design F3 — D1's core claim)

  @Test func volumeAndContrastControllersNeverCrossSuppress() async {
    // Equal raws on two sibling commands must both land with their own
    // command bytes — per-command coalescer instances exist precisely so the
    // HardwareTarget-equality memo cannot cross-suppress (D1).
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
    let fake = FakeDDC(readResult: nil)
    let volume = DDCValueController(writer: fake, command: .volume, prefs: prefs)
    let contrast = DDCValueController(writer: fake, command: .contrast, prefs: prefs)
    volume.setValue(0.5)
    contrast.setValue(0.5)
    await volume.waitForPendingWrites()
    await contrast.waitForPendingWrites()
    let writes = await fake.recordedWrites()
    #expect(writes.contains { $0.command == VCP.audioSpeakerVolume && $0.value == 50 })
    #expect(writes.contains { $0.command == VCP.contrast && $0.value == 50 })
  }

  @Test func muteWireIsNotSuppressedByAFlooredVolumeWrite() async {
    // Floored volume raw 1 and mute wire 1 are byte-identical
    // `.ddc(raw: 1)` targets — a shared memo would swallow whichever came
    // second. The dedicated mute coalescer keeps both on the wire.
    let harness = Harness(command: .volume, savedValue: 0.5) { $0.enableMuteUnmute = true }
    harness.controller.setValue(0.004) // floors to raw 1 on 0x62
    _ = await harness.drainedWrites()
    _ = harness.controller.toggleMute(isFresh: true) // wire 1 on 0x8D
    let writes = await harness.drainedWrites()
    #expect(writes.contains { $0.command == VCP.audioSpeakerVolume && $0.value == 1 })
    #expect(writes.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 1 })
  }

  // MARK: - Validated read (D5 `.read`, MAG write-only protection)

  @Test func refreshIsGatedOnTheReadStartupAction() async {
    let harness = Harness(command: .contrast, savedValue: 0.6)
    await harness.fake.setReadResult((current: 30, max: 100))
    await harness.controller.refreshFromHardware() // startupAction == .doNothing
    #expect(harness.controller.value == 0.6)
  }

  @Test func allZeroReadIsAFailedReadAndKeepsTheSavedValue() async {
    let harness = Harness(command: .contrast, savedValue: 0.6) { prefs in
      prefs.startupAction = .read
    }
    await harness.fake.setReadResult((current: 0, max: 0)) // the MAG answer
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.value == 0.6) // fork would clobber to 0; Candela validates
    #expect(harness.store.savedBrightness(for: "contrast.pk") == 0.6)
  }

  @Test func validReadAdoptsAndPersists() async {
    let harness = Harness(command: .contrast, savedValue: 0.6) { prefs in
      prefs.startupAction = .read
    }
    await harness.fake.setReadResult((current: 30, max: 100))
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.value == 0.3)
    #expect(harness.store.savedBrightness(for: "contrast.pk") == 0.3)
  }

  @Test func pollingModeNoneSkipsTheRead() async {
    let harness = Harness(command: .contrast, savedValue: 0.6) { prefs in
      prefs.startupAction = .read
      prefs.pollingMode = .none
    }
    await harness.fake.setReadResult((current: 30, max: 100))
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.value == 0.6)
  }

  @Test func readRetriesFailedAttemptsAndAdoptsTheFirstValidResult() async {
    // Test-design F7: fail ×2 then succeed — adoption on try 3, and the loop
    // stops at the first success (normal mode budgets 5 tries).
    let scripted = ScriptedDDC(reads: [nil, (current: 0, max: 0), (current: 30, max: 100)])
    let harness = Harness(command: .contrast, savedValue: 0.6, writer: scripted) { prefs in
      prefs.startupAction = .read
    }
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.value == 0.3)
    #expect(await scripted.readCount == 3)
  }

  @Test func mutedReadOfRegisterZeroKeepsTheSavedVolume() async {
    // Muted in the default strategy, the register holds 0 as the mute artifact,
    // not information. A `.read` relaunch seeing a valid (0, 100) must not adopt
    // it, or the unmute restore target is gone (next unmute gives 1/16, not 0.5).
    let scripted = ScriptedDDC(reads: [(current: 0, max: 100)])
    let harness = Harness(command: .volume, savedValue: 0.5, writer: scripted) { prefs in
      prefs.startupAction = .read
      prefs.muted = true
    }
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.value == 0.5)
    #expect(harness.store.savedBrightness(for: "volume.pk") == 0.5)
    #expect(harness.controller.isMuted)
  }

  @Test func muteLandingDuringTheValueReadBailsTheMuteReadback() async {
    // F2 regression pin: the mute generation is captured BEFORE the value read
    // loop, so a `toggleMute` landing mid-read reads as newer and the 0x8D
    // readback bails. Sink the capture below the loop and it already includes the
    // bump, so the readback's (current: 2) clobbers the user's fresh mute.
    let scripted = ScriptedDDC(
      reads: [(current: 50, max: 100), (current: 2, max: 2)], // value read, then 0x8D says "unmuted"
      hookAfterRead: 1
    )
    let harness = Harness(command: .volume, savedValue: 0.5, writer: scripted) { prefs in
      prefs.startupAction = .read
      prefs.enableMuteUnmute = true // wire mode: toggleMute touches the mute coalescer only
    }
    let controller = harness.controller
    await scripted.setHook { await MainActor.run { _ = controller.toggleMute() } }
    await harness.controller.refreshFromHardware()
    #expect(await scripted.readCount == 2) // the 0x8D pass DID run — and bailed
    #expect(harness.controller.isMuted)
    #expect(harness.prefs.muted)
  }

  @Test func minimalPollingReadsExactlyOnce() async {
    // A bug that reads once regardless of tries — or five times under
    // .minimal — fails one of this pair.
    let scripted = ScriptedDDC(reads: [nil, (current: 30, max: 100)])
    let harness = Harness(command: .contrast, savedValue: 0.6, writer: scripted) { prefs in
      prefs.startupAction = .read
      prefs.pollingMode = .minimal
    }
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.value == 0.6) // the single try failed
    #expect(await scripted.readCount == 1)
  }

  // MARK: - Restore (D5 `.write`)

  @Test func restoreRequiresAnEverTouchedValue() async {
    let harness = Harness(command: .volume) // no saved value = never touched
    harness.controller.restoreToHardware()
    #expect(await harness.drainedWrites().isEmpty)
  }

  @Test func restoreRewritesTheSavedValue() async {
    let harness = Harness(command: .contrast, savedValue: 0.75)
    harness.controller.restoreToHardware()
    let writes = await harness.drainedWrites()
    #expect(writes.last?.command == VCP.contrast)
    #expect(writes.last?.value == 75)
  }

  @Test func restoreWhileMutedWithEnableMuteUnmuteSubmitsOnlyTheMuteWire() async {
    // The value and 0x8D coalescers drain independently, so a submitted pair races
    // to the writer actor, and many panels treat a 0x62 write as an implicit
    // unmute. While muted the mute wire IS the restore; the value waits for the
    // unmute.
    let harness = Harness(command: .volume, savedValue: 0.5) { prefs in
      prefs.enableMuteUnmute = true
      prefs.muted = true
    }
    harness.controller.restoreToHardware()
    let writes = await harness.drainedWrites()
    #expect(writes.count == 1)
    #expect(writes[0].command == VCP.audioMuteScreenBlank)
    #expect(writes[0].value == 1)
  }

  @Test func restoreUnmutedWithEnableMuteUnmuteRewritesValueAndWireTwo() async {
    let harness = Harness(command: .volume, savedValue: 0.5) { $0.enableMuteUnmute = true }
    harness.controller.restoreToHardware()
    let writes = await harness.drainedWrites()
    #expect(writes.contains { $0.command == VCP.audioSpeakerVolume && $0.value == 50 })
    #expect(writes.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 2 })
  }

  @Test func restoreWhileMutedInVolumeZeroModeReassertsSilence() async {
    let harness = Harness(command: .volume, savedValue: 0.5) { $0.muted = true }
    harness.controller.restoreToHardware()
    let writes = await harness.drainedWrites()
    #expect(writes.last?.command == VCP.audioSpeakerVolume)
    #expect(writes.last?.value == 0) // divergence: fork would audibly unmute here (planner flag 3, endorsed)
  }

  // MARK: - The display's own denial of the value register (D24, the restore's door)

  @Test func restoreWritesNothingOnADisplayThatDeniesTheVolumeRegister() async {
    // The defect: the restore is the one value write with no gesture behind it,
    // so the UI grey and the key filter never see it, and every launch, wake and
    // checkup spent an I2C transaction on a register the DELL says it lacks.
    let harness = Harness(command: .volume, savedValue: 0.5, valueWireSupport: .unsupported)
    harness.controller.restoreToHardware()
    #expect(await harness.drainedWrites().isEmpty)
    #expect(harness.controller.value == 0.5) // belief untouched: only the wire is spared
  }

  @Test func restoreStillWritesWhenTheVerdictIsUnknown() async {
    // The MAG answers the capabilities read with zeros, so its verdict is
    // permanently `.unknown`. D24 resolves that to allowed, and it has to: the
    // stored value is the only record of where a write-only panel's register sits.
    let harness = Harness(command: .volume, savedValue: 0.5, valueWireSupport: .unknown)
    harness.controller.restoreToHardware()
    let writes = await harness.drainedWrites()
    #expect(writes.count == 1)
    #expect(writes[0].command == VCP.audioSpeakerVolume)
    #expect(writes[0].value == 50)
  }

  @Test func theDenialNeverCancelsTheRestoresUnmute() async {
    // D29 rule 3: a display can deny 0x62 and still carry a 0x8D mute, and this
    // pass is what clears one taken while the verdict was unknown. The value
    // write goes; the unmute must not.
    let harness = Harness(
      command: .volume, savedValue: 0.5, muteWireSupport: .supported,
      valueWireSupport: .unsupported
    ) { $0.enableMuteUnmute = true }
    harness.controller.restoreToHardware()
    let writes = await harness.drainedWrites()
    #expect(writes.count == 1)
    #expect(writes[0].command == VCP.audioMuteScreenBlank)
    #expect(writes[0].value == 2)
  }

  @Test func mutedRestoreOnADeniedRegisterReassertsNoSilence() async {
    // Degraded strategy on a display that denies the volume register too: the
    // mute has no register to live in, so there is nothing to re-assert. The
    // logical flag stands, and `toggleMute` is the ungated way back.
    let harness = Harness(command: .volume, savedValue: 0.5, valueWireSupport: .unsupported) {
      $0.muted = true
    }
    harness.controller.restoreToHardware()
    #expect(await harness.drainedWrites().isEmpty)
    #expect(harness.controller.isMuted)
  }

  @Test func contrastRestoreIgnoresTheAudioVerdictAndItsOverride() async {
    // The audio override is about one display's speakers. A contrast restore
    // reading it would strand the contrast register on any display set to
    // "Always disabled".
    let harness = Harness(command: .contrast, savedValue: 0.75, valueWireSupport: .unsupported) {
      $0.audioSinkOverride = .forceNone
    }
    harness.controller.restoreToHardware()
    let writes = await harness.drainedWrites()
    #expect(writes.last?.command == VCP.contrast)
    #expect(writes.last?.value == 75)
  }

  // MARK: - Memo / rebind / dedupe

  @Test func duplicateTargetsAreCoalescedUntilTheMemoResets() async {
    let harness = Harness(command: .contrast, savedValue: 0.75)
    harness.controller.restoreToHardware()
    _ = await harness.drainedWrites()
    harness.controller.restoreToHardware() // same raw 75 → duplicate-skipped
    #expect((await harness.drainedWrites()).count == 1)
    harness.controller.resetWriteMemo()
    harness.controller.restoreToHardware() // wake-repeat semantics: hits the wire again
    #expect((await harness.drainedWrites()).count == 2)
  }

  @Test func rebindSwapsTheWriterAndResetsTheMemo() async {
    let harness = Harness(command: .contrast, savedValue: 0.75)
    harness.controller.setValue(0.5)
    _ = await harness.drainedWrites()
    let replacement = FakeDDC(readResult: nil)
    harness.controller.rebind(writer: replacement, panelIdentity: nil)
    harness.controller.setValue(0.5) // unchanged value → no write at all (value dedupe)
    harness.controller.setValue(0.6)
    await harness.controller.waitForPendingWrites()
    let writes = await replacement.recordedWrites()
    #expect(writes.last?.command == VCP.contrast)
    #expect(writes.last?.value == 60)
  }

  @Test func staleEpochWritesAreDropped() async {
    let harness = Harness(command: .contrast, savedValue: 0.75)
    harness.controller.setEpochProvider({ 1 }, isCurrent: { _ in false })
    harness.controller.setValue(0.5)
    #expect(await harness.drainedWrites().isEmpty)
  }

  @Test func failedWriteLeavesTheMemoUnrecordedSoRestoreRetries() async {
    // Test-design F8 (controller level): the coalescer records its duplicate
    // memo only on a successful apply — a failed DDC transaction must not
    // suppress the wake chain's retry of the same target.
    let scripted = ScriptedDDC(writeResults: [false, true])
    let harness = Harness(command: .contrast, savedValue: 0.75, writer: scripted)
    harness.controller.restoreToHardware() // fails on the wire
    await harness.controller.waitForPendingWrites()
    harness.controller.restoreToHardware() // NOT duplicate-skipped
    await harness.controller.waitForPendingWrites()
    #expect(await scripted.recordedWrites().count == 2)
  }

  // MARK: - Read evidence at the call site (B3)

  /// Replacing the fold with a plain assignment left the whole suite green: the
  /// enum's own tests cannot see a call site that stops folding. These pin the
  /// fold's scope: worst-wins within a pass, beaten by a success, then by the
  /// next pass.

  @Test func azerosAnsweringPanelPublishesAllZeros() async {
    let harness = Harness(command: .contrast, savedValue: 0.6) { $0.startupAction = .read }
    await harness.fake.setReadResult((current: 0, max: 0)) // the MAG answer
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.readEvidence == .allZeros)
    #expect(harness.controller.readMax == nil) // nothing was learned; 100 is assumed
  }

  @Test func asilentBusPublishesNoReply() async {
    let harness = Harness(command: .contrast, savedValue: 0.6) { $0.startupAction = .read }
    await harness.controller.refreshFromHardware() // FakeDDC(readResult: nil) by default
    #expect(harness.controller.readEvidence == .noReply)
  }

  /// The retry loop exists because DDC reads are flaky, so "attempt 1 silent,
  /// attempt 2 answers" is the healthy case. Folding those monotonically
  /// published "does not reply" about a panel the same pass then adopted.
  @Test func asuccessfulRetryAfterAFailedAttemptReportsAnswered() async {
    let scripted = ScriptedDDC(reads: [nil, (current: 0, max: 0), (current: 30, max: 100)])
    let harness = Harness(command: .contrast, savedValue: 0.6, writer: scripted) {
      $0.startupAction = .read
    }
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.value == 0.3) // the pass adopted the panel's value…
    #expect(harness.controller.readEvidence == .answered) // …and says so
  }

  /// Within one pass a later silent attempt cannot erase an earlier zeros answer:
  /// `allZeros` outranks `noReply` because it names the fault.
  @Test func withinOnePassASilentRetryDoesNotEraseAZerosAnswer() async {
    let scripted = ScriptedDDC(reads: [(current: 0, max: 0), nil, nil])
    let harness = Harness(command: .contrast, savedValue: 0.6, writer: scripted) {
      $0.startupAction = .read
    }
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.readEvidence == .allZeros)
  }

  /// A pass that returns before touching the wire (`startupAction != .read`
  /// here) proves nothing and must leave the previous verdict standing.
  @Test func apassThatAsksNothingLeavesTheVerdictStanding() async {
    let harness = Harness(command: .contrast, savedValue: 0.6) { $0.startupAction = .read }
    await harness.fake.setReadResult((current: 0, max: 0))
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.readEvidence == .allZeros)

    harness.prefs.startupAction = .doNothing
    await harness.fake.setReadResult((current: 30, max: 100))
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.readEvidence == .allZeros)
  }

  /// `AppModel.performRefresh` reuses a controller for any display whose
  /// `CGDirectDisplayID` reappears, and macOS reassigns those IDs across a replug,
  /// so a different physical monitor inherits this object. `readMax` back to `nil`
  /// costs bytes: writes scale against an assumed 100 until the new panel answers.
  @Test func arebindToADifferentPanelReturnsTheReadbackMaxToAssumed() async {
    let harness = Harness(command: .contrast, savedValue: 0.6, panelIdentity: "panel-A") {
      $0.startupAction = .read
    }
    await harness.fake.setReadResult((current: 30, max: 80))
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.readMax == 80)
    #expect(harness.controller.readEvidence == .answered)

    harness.controller.rebind(writer: FakeDDC(readResult: nil), panelIdentity: "panel-B")
    #expect(harness.controller.readMax == nil)
    #expect(harness.controller.readEvidence == .notAttempted)
  }

  /// `performRefresh` rebinds every kept display on every pass, not only after a
  /// replug, so a reset keyed on the call drops a readable panel's maximum on
  /// every wake. The recovering re-read only runs under `startupAction == .read`.
  @Test func arebindToTheSamePanelKeepsWhatThatPanelReported() async {
    let harness = Harness(command: .contrast, savedValue: 0.6, panelIdentity: "panel-A") {
      $0.startupAction = .read
    }
    await harness.fake.setReadResult((current: 30, max: 80))
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.readMax == 80)

    harness.controller.rebind(writer: FakeDDC(readResult: nil), panelIdentity: "panel-A")
    #expect(harness.controller.readMax == 80)
    #expect(harness.controller.readEvidence == .answered)
  }

  /// `refreshFromHardware` seeds `passEvidence` from `.notAttempted`, not from the
  /// standing `readEvidence`. Seeding from `readEvidence` left every other test in
  /// this suite green: the case that separates them is a zeros answer followed by
  /// a pass that hears nothing, where the carried seed republishes `.allZeros`.
  /// Within a pass attempts still fold worst-wins; only the seed is per-pass.
  @Test func apassThatHearsOnlySilenceReportsSilenceNotTheOldZeros() async {
    let harness = Harness(command: .contrast, savedValue: 0.6) { $0.startupAction = .read }
    await harness.fake.setReadResult((current: 0, max: 0))
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.readEvidence == .allZeros)

    await harness.fake.setReadResult(nil) // the bus goes quiet: every try returns nil
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.readEvidence == .noReply)
  }

  // MARK: - The mute queue's own drain (the register the strand is about)

  /// Value and mute ride separate coalescers and only the second carries 0x8D, so
  /// a drain reporting the value queue's health would certify the wrong register.
  @Test func aMuteWireTheEpochGateSkippedIsNotReportedAsLanded() async {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
    prefs.enableMuteUnmute = true
    prefs.muted = true
    let fake = FakeDDC(readResult: nil)
    let volume = DDCValueController(writer: fake, command: .volume, prefs: prefs)
    let gateOpen = OSAllocatedUnfairLock(initialState: false)
    volume.setEpochProvider({ 1 }, isCurrent: { _ in gateOpen.withLock { $0 } })

    _ = volume.toggleMute() // the unmute a reset sends: 0x8D = 2

    #expect(await volume.drainPendingWrites() == false, "skipped is not applied")
    let duringGate = await fake.recordedWrites()
    #expect(
      !duringGate.contains { $0.command == VCP.audioMuteScreenBlank },
      "and nothing reached the mute register"
    )

    gateOpen.withLock { $0 = true }

    #expect(await volume.drainPendingWrites(), "the re-submit lands once the gate opens")
    let afterGate = await fake.recordedWrites()
    #expect(
      afterGate.contains { $0.command == VCP.audioMuteScreenBlank && $0.value == 2 },
      "and it is the unmute wire value, not the volume register"
    )
  }

  /// A memo skip counts as landed, which holds only if the panel was really taking
  /// writes. Under HDR an I2C write is ACKed and swallowed, so a memo built through
  /// an HDR window records values that never arrived. Dropping it reopens the wire.
  @Test func aMemoDroppedOnTheHDRExitLetsTheSameRawGoOutAgain() async {
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
    let fake = FakeDDC(readResult: nil)
    let volume = DDCValueController(writer: fake, command: .volume, prefs: prefs)

    // Stands in for a write the display ACKed under HDR and swallowed. Two
    // published values scaling to the same raw, since the raw is what the memo
    // compares and therefore what it can suppress.
    volume.setValue(0.301)
    await volume.waitForPendingWrites()
    let before = await fake.recordedWrites().count

    volume.resetWriteMemo()
    volume.setValue(0.304) // raw 30 again
    #expect(await volume.drainPendingWrites())

    let after = await fake.recordedWrites()
    #expect(after.count == before + 1, "the write went out rather than being skipped")
    #expect(after.last?.value == 30)
  }

  // MARK: - reassertHardware (the settings reset's door)

  /// The post-reset shape: with the store wiped, `restoreToHardware` refuses to
  /// send (no saved value) and `setValue(0.75)` returns before the submit.
  @Test func reassertSendsTheAssumedContrastDefaultOverAnEmptyStore() async {
    let h = Harness(command: .contrast) // no savedValue: the domain was wiped
    #expect(h.controller.value == 0.75)

    h.controller.reassertHardware()

    let writes = await h.drainedWrites()
    #expect(writes.count == 1)
    #expect(writes.last?.value == 75)
  }

  @Test func reassertSendsTheAssumedVolumeDefaultOverAnEmptyStore() async {
    let h = Harness(command: .volume)
    #expect(h.controller.value == 0.125)

    h.controller.reassertHardware()

    let writes = await h.drainedWrites()
    #expect(writes.count == 1)
    // Non-zero is the load-bearing half: a volume the reset drove to 0 would
    // hardware-mute the display, which is the strand D29 rule 4 forbids.
    #expect((writes.last?.value ?? 0) > 0)
  }

  /// D29 rule 1, in the register the reset carries across its own wipe: a
  /// display whose unmute could not be confirmed is put back muted, and this
  /// door must not then write a level over the silence.
  @Test func reassertNeverDrivesAMutedDisplaysVolume() async {
    let h = Harness(command: .volume) { prefs in prefs.muted = true }
    #expect(h.controller.isMuted)

    h.controller.reassertHardware()

    #expect(await h.drainedWrites().isEmpty)
  }

  /// The one choke point every other door guards on: a display the user has
  /// taken off the DDC wire gets no traffic from the reset either.
  @Test func reassertRespectsTheUnavailableGate() async {
    let h = Harness(command: .contrast) { prefs in prefs.forceSoftware = true }

    h.controller.reassertHardware()

    #expect(await h.drainedWrites().isEmpty)
  }
}
