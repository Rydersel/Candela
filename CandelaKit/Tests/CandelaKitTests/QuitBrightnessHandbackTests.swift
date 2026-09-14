import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

private actor HandbackPanel: DDCWriting {
  var raw: UInt16 = 62
  var maximum: UInt16 = 100
  var succeeds = true
  var answers = true
  var writes: [UInt16] = []
  var primary: UInt8 = 0x10
  var failedCodes: Set<UInt8> = []
  private var blocksNextRead = false
  private var blockedRead: CheckedContinuation<Void, Never>?

  func write(command: UInt8, value: UInt16) -> Bool {
    writes.append(value)
    let success = succeeds && !failedCodes.contains(command)
    if success && command == primary { raw = value }
    return success
  }
  func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
    let answer: (current: UInt16, max: UInt16)? = answers ? (raw, maximum) : nil
    if blocksNextRead {
      blocksNextRead = false
      await withCheckedContinuation { blockedRead = $0 }
    }
    return answer
  }
  func blockNextRead() { blocksNextRead = true }
  func waitForBlockedRead() async {
    while blockedRead == nil { await Task.yield() }
  }
  func releaseRead() { blockedRead?.resume(); blockedRead = nil }
  func setPrimary(_ value: UInt8) { primary = value }
  func setFailedCodes(_ value: Set<UInt8>) { failedCodes = value }
  func setRaw(_ value: UInt16) { raw = value }
  func setSuccess(_ value: Bool) { succeeds = value }
  func setAnswers(_ value: Bool) { answers = value }
}

@Suite("Quit brightness handback") @MainActor
struct QuitBrightnessHandbackTests {
  @MainActor private final class Rig {
    let suite = "quit-handback-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let prefs: DisplayPrefs
    let store = PathMemoryStore()
    let panel = HandbackPanel()
    init(_ saved: Double = 0.81) {
      defaults = UserDefaults(suiteName: suite)!
      prefs = DisplayPrefs(defaults: defaults, persistenceKey: "panel")
      store.values["logical"] = saved
    }
    func controller(panel: HandbackPanel? = nil) -> BrightnessController {
      BrightnessController(
        writer: panel ?? self.panel,
        backends: BrightnessBackends(applierNative: FakeNativeApplier(), hdr: nil,
                                    shade: RecordingShade(), gamma: RecordingGamma()),
        prefs: prefs, displayID: 7, store: store, storageKey: "logical", wireSiblings: [])
    }
    func clear() { defaults.removePersistentDomain(forName: suite) }
  }

  @Test(arguments: [0.81, 0.905])
  func repeatedQuitAndLaunchPreserveLogicalBrightness(saved: Double) async {
    let rig = Rig(saved)
    defer { rig.clear() }
    var current = rig.controller()
    for _ in 0..<2 {
      current.restoreFullRangeDDC()
      await current.waitForPendingWrites()
      current = rig.controller()
      await current.refreshFromHardware()
      #expect(abs(current.brightness - saved) < 0.000_001)
      #expect(rig.store.values["logical"] == saved)
      let canonical = DimmingMath.valueToDDC(
        (saved - 0.5) / 0.5, minDDC: 0, maxDDC: 100, curve: 1, invert: false)
      #expect(await rig.panel.raw == canonical)
      await current.refreshFromHardware()
      #expect(abs(current.brightness - saved) <= 0.005)
    }
  }

  @Test func realMonitorChangeUsesNormalCombinedAdoption() async {
    let rig = Rig()
    defer { rig.clear() }
    let outgoing = rig.controller()
    outgoing.restoreFullRangeDDC()
    await outgoing.waitForPendingWrites()
    await rig.panel.setRaw(40)
    let next = rig.controller()
    await next.refreshFromHardware()
    #expect(next.brightness == 0.7)
    #expect(rig.store.values["logical"] == 0.7)
    #expect(await rig.panel.raw == 40)
  }

  @Test func failedQuitDoesNotAuthorizeHandbackRecovery() async {
    let rig = Rig()
    defer { rig.clear() }
    await rig.panel.setSuccess(false)
    let outgoing = rig.controller()
    outgoing.restoreFullRangeDDC()
    await outgoing.waitForPendingWrites()
    await rig.panel.setSuccess(true)
    // Matching the attempted quit value is insufficient without a successful write.
    await rig.panel.setRaw(81)
    let next = rig.controller()
    await next.refreshFromHardware()
    #expect(next.brightness == 0.905)
  }

  @Test func failedNormalizationAndAutomaticRestoreRetainEvidenceAcrossAnotherQuit() async {
    let rig = Rig()
    defer { rig.clear() }
    let outgoing = rig.controller()
    outgoing.restoreFullRangeDDC()
    await outgoing.waitForPendingWrites()
    let next = rig.controller()
    await rig.panel.setSuccess(false)
    await next.refreshFromHardware()
    next.resetWriteMemo()
    next.reassertHardware()
    await next.waitForPendingWrites()
    await next.refreshFromHardware()
    #expect(next.brightness == 0.81)
    #expect(rig.store.values["logical"] == 0.81)
    next.restoreFullRangeDDC()
    await next.waitForPendingWrites()
    await rig.panel.setSuccess(true)
    let third = rig.controller()
    await third.refreshFromHardware()
    #expect(third.brightness == 0.81)
    #expect(await rig.panel.raw == 62)
  }

  @Test func epochSkippedQuitDoesNotCreateProvenance() async {
    let rig = Rig()
    defer { rig.clear() }
    let outgoing = rig.controller()
    outgoing.setEpochProvider({ 1 }, isCurrent: { _ in false })
    outgoing.restoreFullRangeDDC()
    await outgoing.waitForPendingWrites()
    #expect(rig.prefs.quitBrightnessHandback == nil)
    await rig.panel.setRaw(81)
    let next = rig.controller()
    await next.refreshFromHardware()
    #expect(next.brightness == 0.905)
  }

  @Test func softwareZoneRestoresParkedHardwareWithoutOverwritingStoredSoftwareValue() async {
    let rig = Rig(0.3)
    defer { rig.clear() }
    let outgoing = rig.controller()
    outgoing.setBrightness(0.3)
    await outgoing.waitForPendingWrites()
    outgoing.restoreFullRangeDDC()
    await outgoing.waitForPendingWrites()
    #expect(await rig.panel.raw == 30)
    let next = rig.controller()
    await next.refreshFromHardware()
    #expect(next.brightness == 0.5)
    #expect(rig.store.values["logical"] == 0.3)
    #expect(await rig.panel.raw == 0)
    await next.refreshFromHardware()
    #expect(rig.store.values["logical"] == 0.3)
  }

  @Test(arguments: [0, 1, 2, 3, 4])
  func exactRawMatchingUsesTheQuitMapping(variant: Int) async {
    let rig = Rig()
    defer { rig.clear() }
    var tuning = rig.prefs.tuning(for: .brightness)
    switch variant {
    case 0: tuning.curveIndex = 1
    case 1: tuning.curveIndex = 9
    case 2: tuning.minDDCOverride = 5; tuning.maxDDCOverride = 90
    case 3: tuning.invert = true
    default: tuning.remapCodes = [0x12, 0x13]
    }
    rig.prefs.setTuning(tuning, for: .brightness)
    await rig.panel.setPrimary(tuning.remapCodes.first ?? 0x10)
    let outgoing = rig.controller()
    outgoing.restoreFullRangeDDC()
    await outgoing.waitForPendingWrites()
    let next = rig.controller()
    await next.refreshFromHardware()
    #expect(next.brightness == 0.81)
    #expect(rig.store.values["logical"] == 0.81)
    let canonical = DimmingMath.valueToDDC(
      (0.81 - 0.5) / 0.5, minDDC: Double(tuning.minDDCOverride),
      maxDDC: Double(tuning.effectiveMaxDDC(readMax: 100)),
      curve: tuning.curveMultiplier, invert: tuning.invert)
    #expect(await rig.panel.raw == canonical)
  }

  @Test func changedMappingAndChangedSavedValueRejectStaleProvenance() async {
    let rig = Rig()
    defer { rig.clear() }
    let outgoing = rig.controller()
    outgoing.restoreFullRangeDDC()
    await outgoing.waitForPendingWrites()
    rig.prefs.disableCombinedBrightness = true
    let next = rig.controller()
    await next.refreshFromHardware()
    #expect(next.brightness == 0.81)
    #expect(await rig.panel.raw == 81)
    #expect(rig.prefs.quitBrightnessHandback == nil)

    rig.prefs.disableCombinedBrightness = false
    next.restoreFullRangeDDC()
    await next.waitForPendingWrites()
    rig.store.values["logical"] = 0.7
    let third = rig.controller()
    await third.refreshFromHardware()
    #expect(third.brightness == 0.905)
  }

  @Test func onlyTheReadableRemapRegistersSuccessfulWriteAuthorizesRecovery() async {
    let rig = Rig()
    defer { rig.clear() }
    var tuning = rig.prefs.tuning(for: .brightness)
    tuning.remapCodes = [0x10, 0x13]
    rig.prefs.setTuning(tuning, for: .brightness)
    await rig.panel.setFailedCodes([0x13])
    let outgoing = rig.controller()
    outgoing.restoreFullRangeDDC()
    await outgoing.waitForPendingWrites()
    #expect(outgoing.lastApplyFailed())
    #expect(rig.prefs.quitBrightnessHandback != nil)
    await rig.panel.setFailedCodes([])
    let next = rig.controller()
    await next.refreshFromHardware()
    #expect(next.brightness == 0.81)
    #expect(await rig.panel.raw == 62)

    await rig.panel.setFailedCodes([0x10])
    next.restoreFullRangeDDC()
    await next.waitForPendingWrites()
    #expect(rig.prefs.quitBrightnessHandback == nil)
  }

  @Test(arguments: [false, true])
  func aReadlessTwinKeepsDurableEvidenceAfterTheOtherTwinRecovers(abandonFirst: Bool) async {
    let rig = Rig()
    defer { rig.clear() }
    let outgoing = rig.controller()
    outgoing.restoreFullRangeDDC()
    await outgoing.waitForPendingWrites()
    let otherPanel = HandbackPanel()
    await otherPanel.setRaw(81)
    await otherPanel.setAnswers(false)
    let first = rig.controller()
    var second: BrightnessController? = rig.controller(panel: otherPanel)
    await second?.refreshFromHardware()
    if abandonFirst { second = nil }
    await first.refreshFromHardware()
    second = nil
    #expect(rig.prefs.quitBrightnessHandback != nil)
    await otherPanel.setAnswers(true)
    let later = rig.controller(panel: otherPanel)
    await later.refreshFromHardware()
    #expect(later.brightness == 0.81)
    #expect(await otherPanel.raw == 62)
  }

  @Test func legacyEligibilitySurvivesUnreadableLaunchAndDurableProvenanceWins() async {
    let rig = Rig()
    defer { rig.clear() }
    await rig.panel.setRaw(81)
    let first = rig.controller()
    first.noteLegacyUpdateHandback()
    await rig.panel.setAnswers(false)
    await first.refreshFromHardware()
    await rig.panel.setAnswers(true)
    let second = rig.controller()
    await second.refreshFromHardware()
    #expect(second.brightness == 0.81)
    #expect(await rig.panel.raw == 62)
    second.restoreFullRangeDDC()
    await second.waitForPendingWrites()
    let durableID = rig.prefs.quitBrightnessHandback?.id
    let third = rig.controller()
    third.noteLegacyUpdateHandback()
    #expect(rig.prefs.quitBrightnessHandback?.id == durableID)
    #expect(rig.prefs.quitBrightnessHandback?.isLegacy == false)
    await third.refreshFromHardware()
    #expect(third.brightness == 0.81)
  }


  @Test func aReadFromAnotherMappingCannotNormalizeAfterPreferencesReturnToTheRecordMapping() async {
    let rig = Rig()
    defer { rig.clear() }
    let outgoing = rig.controller()
    outgoing.restoreFullRangeDDC()
    await outgoing.waitForPendingWrites()
    let incoming = rig.controller()
    let originalTuning = rig.prefs.tuning(for: .brightness)
    var differentTuning = originalTuning
    differentTuning.minDDCOverride = 10
    rig.prefs.setTuning(differentTuning, for: .brightness)
    await rig.panel.blockNextRead()
    let read = Task { await incoming.refreshFromHardware() }
    await rig.panel.waitForBlockedRead()
    rig.prefs.setTuning(originalTuning, for: .brightness)
    await rig.panel.releaseRead()
    await read.value
    #expect(await rig.panel.raw == 81)
    #expect(await rig.panel.writes == [81])
    #expect(rig.prefs.quitBrightnessHandback != nil)
    #expect(rig.store.values["logical"] == 0.81)
    await incoming.refreshFromHardware()
    #expect(await rig.panel.raw == 62)
    #expect(incoming.brightness == 0.81)
    #expect(rig.store.values["logical"] == 0.81)
  }
}
