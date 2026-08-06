import Foundation
import Testing
@testable import CandelaKit

@Suite("DDCValueController")
@MainActor
struct DDCValueControllerTests {
  /// Per-test throwaway defaults + memory store (the PathSelection harness
  /// pattern — never touch .standard).
  @MainActor
  private final class Harness {
    let defaults: UserDefaults
    let prefs: DisplayPrefs
    let fake = FakeDDC(readResult: nil) // write-only panel by default (MAG parity)
    let store = PathMemoryStore()
    let controller: DDCValueController

    init(
      command: DDCCommand, savedValue: Double? = nil,
      writer: (any DDCWriting)? = nil, // e.g. ScriptedDDC for retry/failure tests
      panelIdentity: String? = nil, // only the rebind tests care which panel this is
      configure: (DisplayPrefs) -> Void = { _ in }
    ) {
      defaults = InMemoryDefaults()
      prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
      configure(prefs)
      let storageKey = "\(command.rawValue).pk"
      if let savedValue { store.saveBrightness(savedValue, for: storageKey) }
      controller = DDCValueController(
        writer: writer ?? fake, command: command, prefs: prefs,
        displayID: 1, store: store, storageKey: storageKey, panelIdentity: panelIdentity
      )
    }

    func drainedWrites() async -> [(command: UInt8, value: UInt16)] {
      await controller.waitForPendingWrites()
      return await fake.recordedWrites()
    }
  }

  /// Scripted read queue + counter and scripted write results — the
  /// constant-result `FakeDDC` cannot observe the retry loop (test-design F7)
  /// or a failed transaction (test-design F8).
  private actor ScriptedDDC: DDCWriting {
    private(set) var readCount = 0
    private var reads: [(current: UInt16, max: UInt16)?]
    private var writeResults: [Bool]
    private(set) var writes: [(command: UInt8, value: UInt16)] = []

    init(reads: [(current: UInt16, max: UInt16)?] = [], writeResults: [Bool] = []) {
      self.reads = reads
      self.writeResults = writeResults
    }

    func write(command: UInt8, value: UInt16) async -> Bool {
      writes.append((command, value))
      return writeResults.isEmpty ? true : writeResults.removeFirst()
    }

    func read(command _: UInt8) async -> (current: UInt16, max: UInt16)? {
      readCount += 1
      return reads.isEmpty ? nil : reads.removeFirst()
    }

    func recordedWrites() -> [(command: UInt8, value: UInt16)] { writes }
  }

  /// Scripted reads plus a hook fired DURING a chosen read — the seam that
  /// lets a test land user input inside `refreshFromHardware`'s value loop
  /// (the F2 mute-generation regression pin).
  private actor HookedScriptedDDC: DDCWriting {
    private(set) var readCount = 0
    private var reads: [(current: UInt16, max: UInt16)?]
    private var hookAfterRead: Int
    private var hook: (@Sendable () async -> Void)?
    private(set) var writes: [(command: UInt8, value: UInt16)] = []

    init(reads: [(current: UInt16, max: UInt16)?], hookAfterRead: Int) {
      self.reads = reads
      self.hookAfterRead = hookAfterRead
    }

    func setHook(_ hook: @escaping @Sendable () async -> Void) { self.hook = hook }

    func write(command: UInt8, value: UInt16) async -> Bool {
      writes.append((command, value))
      return true
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
    // Brief deviation (savedValue): a fresh contrast controller seeds 0.75,
    // so the brief's setValue(0.75) was value-deduped and never hit the wire
    // — seed 0.5 so 0.75 is a real change; the assertion is unchanged.
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
    // Fork isSw() parity (review R5): the user sets forceSoftware precisely
    // because the display's DDC wire is broken — the volume/contrast surface
    // must not hammer it with writes, on any path.
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
    // Brief deviation: tuple arrays are not Equatable, so the brief's
    // `writes == writes.filter(...)` cannot compile; allSatisfy asserts the
    // same thing — every write rode 0x62, no 0x8D traffic.
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
    // Concurrency F5: default strategy muted → the register holds 0 while
    // `value` keeps the stored level. A slider click landing EXACTLY on the
    // stored value must still rewrite the register — the `changed` guard
    // alone would leave the panel silent behind an unmuted UI.
    let harness = Harness(command: .volume, savedValue: 0.5) { $0.muted = true }
    harness.controller.setValue(0.5)
    #expect(harness.controller.isMuted == false)
    let writes = await harness.drainedWrites()
    #expect(writes.last?.command == VCP.audioSpeakerVolume)
    #expect(writes.last?.value == 50)
  }

  // MARK: - Mute strategy switched mid-session (test-design F4; D2 supports live pref flips)

  @Test func strategySwitchToWireModeUnmutesWithWireTwoAndVolumeRestore() async {
    // Muted under the default strategy (register holds 0), user flips
    // enableMuteUnmute on via `defaults write`, then unmutes: BOTH the wire-2
    // companion and the volume rewrite must go out — the register still holds
    // the old strategy's 0.
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
    // Muted under enableMuteUnmute (0x8D=1 on the wire, register untouched),
    // pref flipped off, then unmute: the default strategy sends no 0x8D
    // traffic, so the volume rewrite is the whole unmute. NOTE the recorded
    // hazard: the panel may stay hardware-0x8D-muted — the fork's settings UI
    // un-mutes BEFORE persisting the pref flip; that guard is an M5 settings
    // behavior (see the plan's M5 deferrals section).
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

  // MARK: - Cross-coalescer isolation (test-design F3 — D1's core claim)

  @Test func volumeAndContrastControllersNeverCrossSuppress() async {
    // Equal raws on two sibling commands must both land with their own
    // command bytes — per-command coalescer instances exist precisely so the
    // HardwareTarget-equality memo cannot cross-suppress (D1).
    let defaults = InMemoryDefaults()
    let prefs = DisplayPrefs(defaults: defaults, persistenceKey: "pk")
    let fake = FakeDDC(readResult: nil)
    let volume = DDCValueController(writer: fake, command: .volume, prefs: prefs, displayID: 1)
    let contrast = DDCValueController(writer: fake, command: .contrast, prefs: prefs, displayID: 1)
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
    // Fix round 1 F1: muted in the default strategy, the register holds 0 as
    // the MUTE ARTIFACT, not information. A `.read` relaunch seeing
    // (0, 100) — a technically valid read — must not adopt/persist 0, or the
    // unmute restore target is destroyed (next unmute restores 1/16, not 0.5).
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
    // Fix round 1 F2 regression pin: the mute generation is captured BEFORE
    // the value read loop. A `toggleMute` landing mid-value-read bumps that
    // generation, so the 0x8D readback pass must recognise the user's fresh
    // mute as newer and bail. Sink the capture below the value loop and the
    // capture already includes the bump — the readback's (current: 2) then
    // clobbers the fresh mute back to unmuted and this test goes red.
    let scripted = HookedScriptedDDC(
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
    // Review R2: the value and 0x8D coalescers drain independently, so a
    // submitted PAIR races to the writer actor — and many panels treat a
    // 0x62 write as an implicit unmute. The D5 wake chain re-rolls that race
    // 10 times. While muted, the mute wire IS the restore; the volume value
    // is written only when unmuted.
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

  /// The enum's own tests cannot catch a call site that stops folding, and no
  /// test asserted this controller ever publishes anything at all — replacing
  /// the fold with a plain assignment left the whole suite green. These pin
  /// the published verdict, and with it the SCOPE of the fold: worst-wins
  /// among a pass's failed attempts, superseded by a success, superseded again
  /// by the next pass that asks.

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

  /// The defect this whole scope change exists to remove. The retry loop is
  /// there BECAUSE DDC reads are flaky, so "attempt 1 silent, attempt 2
  /// answers" is the ordinary healthy case — and folding those monotonically
  /// published "this display does not reply" about a panel whose value the
  /// very same pass then adopted. A read that eventually succeeded is a read
  /// that succeeded.
  @Test func asuccessfulRetryAfterAFailedAttemptReportsAnswered() async {
    let scripted = ScriptedDDC(reads: [nil, (current: 0, max: 0), (current: 30, max: 100)])
    let harness = Harness(command: .contrast, savedValue: 0.6, writer: scripted) {
      $0.startupAction = .read
    }
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.value == 0.3) // the pass adopted the panel's value…
    #expect(harness.controller.readEvidence == .answered) // …and says so
  }

  /// The half that must NOT be weakened: within one pass, a later silent
  /// attempt cannot erase an earlier zeros answer. `allZeros` outranks
  /// `noReply` because it is the more specific finding, and it is the one that
  /// names the fault.
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

  /// A DIFFERENT panel on the same object, so both read-derived facts go back
  /// to their "nothing learned" state. Not academic: `AppModel.performRefresh`
  /// REUSES these controllers for any display whose `CGDirectDisplayID`
  /// reappears, and macOS reassigns those IDs across a replug — a different
  /// physical monitor on the same port inherits this object.
  ///
  /// `readMax` is the one that moves bytes: `nil` means "assume 100", so a
  /// panel that had reported a max below 100 is written against 100 again
  /// until the new panel answers. Deliberate, and asserted rather than left to
  /// be discovered — see `rebind(writer:panelIdentity:)`.
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

  /// The counterpart, and the regression the first ruling shipped:
  /// `AppModel.performRefresh` rebinds every KEPT display on EVERY pass, not
  /// only after a replug, so a reset keyed on the CALL rather than on a change
  /// of panel drops a readable panel's reported maximum on every wake and
  /// every reconfiguration. Here that costs real bytes — `readMax == nil`
  /// means writes scale against 100 — and the recovering re-read is a no-op
  /// unless `startupAction == .read`, which it usually is not.
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

  /// The clause the whole per-pass scope rests on, and until now the only one
  /// nothing pinned: `refreshFromHardware` seeds `passEvidence` from
  /// `.notAttempted`, not from the standing `readEvidence`. Seeding it from
  /// `readEvidence` — the obvious "surely we should keep folding" edit —
  /// left every other test in this suite green.
  ///
  /// The case that separates them: pass 1 gets the MAG's zeros answer, pass 2
  /// goes completely silent. `allZeros` outranks `noReply`, so the carried
  /// seed would republish `.allZeros` — "this panel answers with zeros" about
  /// a panel that, on the only evidence this pass has, is not answering at
  /// all. The verdict is the CURRENT pass's, and the current pass heard
  /// nothing.
  ///
  /// Note what is NOT weakened: within pass 2 every attempt still folds
  /// worst-wins (`withinOnePassASilentRetryDoesNotEraseAZerosAnswer` pins that
  /// half). Only the seed changed scope.
  @Test func apassThatHearsOnlySilenceReportsSilenceNotTheOldZeros() async {
    let harness = Harness(command: .contrast, savedValue: 0.6) { $0.startupAction = .read }
    await harness.fake.setReadResult((current: 0, max: 0))
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.readEvidence == .allZeros)

    await harness.fake.setReadResult(nil) // the bus goes quiet: every try returns nil
    await harness.controller.refreshFromHardware()
    #expect(harness.controller.readEvidence == .noReply)
  }
}
