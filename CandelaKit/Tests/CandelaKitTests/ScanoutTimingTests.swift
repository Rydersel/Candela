import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

@Suite("Controller scan-out verification")
struct ScanoutTimingTests {
  private func element(_ id: Int, _ width: Any = 3440, _ height: Any = 1440,
                       _ rate: Any = 9_436_725) -> [String: Any] {
    ["ID": id, "HorizontalAttributes": ["Active": width],
     "VerticalAttributes": ["Active": height, "PreciseSyncRate": rate]]
  }

  @Test func activeIDSelectsItsOwnEntryAndDecodesFixedPoint() throws {
    let timing = try #require(ScanoutTimingReader.parse([
      "DPTimingModeId": 86, "TimingElements": [element(84, 2560, 1440, 7_864_320), element(86)]
    ]))
    #expect(timing.width == 3440)
    #expect(timing.height == 1440)
    #expect(abs(timing.refreshHz - 143.993) < 0.00002)
  }

  @Test func missingAndAmbiguousActiveIDsCannotVerify() {
    let records: [[String: Any]] = [
      [:], ["DPTimingModeId": 87, "TimingElements": [element(86)]],
      ["DPTimingModeId": 86, "TimingElements": [element(86), element(86, 1920, 1080)]]
    ]
    for record in records { #expect(ScanoutTimingReader.parse(record) == nil) }
  }

  @Test func malformedAttributesCannotBecomeCleanReadings() {
    for entry in [element(86, 0), element(86, -1), element(86, true),
                  element(86, 3440.5), element(86, 3440, 1440, 0),
                  element(86, 3440, 1440, Double.infinity),
                  element(86, 3440, 1440, 4_294_967_296)] {
      #expect(ScanoutTimingReader.parse(["DPTimingModeId": 86, "TimingElements": [entry]]) == nil)
    }
  }

  @Test func exactLocationCannotBorrowAnIdenticalNeighborsRecord() throws {
    let record = ScanoutTimingReader.matchingRecord(displayLocation: "IOService:/port2/AppleCLCD2", candidates: [
      ("IOService:/port1/AppleCLCD2", { ["DPTimingModeId": 86, "TimingElements": [element(86, 1920, 1080)]] }),
      ("IOService:/port2/AppleCLCD2", { ["DPTimingModeId": 86, "TimingElements": [element(86)]] })
    ])
    #expect(ScanoutTimingReader.parse(try #require(record))?.width == 3440)
    #expect(ScanoutTimingReader.matchingRecord(displayLocation: nil,
      candidates: [("IOService:/port1/AppleCLCD2", { ["ID": 1] })]) == nil)
    #expect(ScanoutTimingReader.matchingRecord(displayLocation: "missing",
      candidates: [("other", { ["ID": 1] })]) == nil)
  }

  @Test func ambiguousOrUnreadableWinnerDoesNotFallBackToAnotherPipe() {
    var reads = 0
    #expect(ScanoutTimingReader.matchingRecord(displayLocation: "same", candidates: [
      ("same", { reads += 1; return ["ID": 1] }),
      ("same", { reads += 1; return ["ID": 2] })
    ]) == nil)
    #expect(reads == 0)
    #expect(ScanoutTimingReader.matchingRecord(displayLocation: "same", candidates: [
      ("same", { nil }), ("other", { ["ID": 1] })
    ]) == nil)
  }

  private func mode(_ provenance: ModeProvenance = .coreGraphicsServices,
                    pixels: (Int, Int) = (6880, 2880), logical: (Int, Int) = (3440, 1440),
                    hz: Double = 120, native: Bool = false, id: Int32 = 1) -> DisplayMode {
    DisplayMode(ioModeID: id, logicalWidth: logical.0, logicalHeight: logical.1,
                pixelWidth: pixels.0, pixelHeight: pixels.1, refreshHz: hz,
                isNative: native, provenance: provenance)
  }

  @Test func revealedFramebufferSuccessDoesNotHideCroppedScanout() {
    let requested = mode()
    #expect(ModeApplyVerification.verdict(requested: requested, achieved: requested) == .honoured)
    #expect(ScanoutVerification.verdict(requested: requested, nativePixels: (3440, 1440),
      timing: ScanoutTiming(width: 2560, height: 1440, refreshHz: 120)) == .mismatch)
  }

  @Test func rotatedNativeTimingAndRefreshNoisePass() {
    #expect(ScanoutVerification.verdict(requested: mode(.coreGraphics,
      pixels: (2880, 5120), logical: (1440, 2560), hz: 60), nativePixels: (2160, 3840),
      timing: ScanoutTiming(width: 3840, height: 2160, refreshHz: 59.997)) == .verified)
  }

  @Test func legitimateLowerWireModeIsNotComparedBlindlyToNative() {
    #expect(ScanoutVerification.verdict(requested: mode(.coreGraphics,
      pixels: (1920, 1080), logical: (1920, 1080), hz: 60), nativePixels: (3440, 1440),
      timing: ScanoutTiming(width: 1920, height: 1080, refreshHz: 60)) == .verified)
  }

  @Test func absentTimingOrNativeGeometryIsExplicitlyNotVerifiable() {
    #expect(ScanoutVerification.verdict(requested: mode(), nativePixels: (3440, 1440), timing: nil) == .notVerifiable)
    #expect(ScanoutVerification.verdict(requested: mode(), nativePixels: nil,
      timing: ScanoutTiming(width: 3440, height: 1440, refreshHz: 120)) == .notVerifiable)
  }

  @Test func rateMismatchAndSynthesizedForeignTimingFail() {
    #expect(ScanoutVerification.verdict(requested: mode(), nativePixels: (3440, 1440),
      timing: ScanoutTiming(width: 3440, height: 1440, refreshHz: 119.4)) == .mismatch)
    #expect(ScanoutVerification.verdict(requested: mode(.synthesized, hz: 0), nativePixels: (3440, 1440),
      timing: ScanoutTiming(width: 2560, height: 1440, refreshHz: 60)) == .mismatch)
  }

  @Test func withholdingANativeModeDoesNotEraseKnownPanelDimensions() {
    let native = mode(.coreGraphics, pixels: (3440, 1440), native: true)
    let revealed = mode(.coreGraphics, id: 2)
    let snapshot = CoreGraphicsDisplayConfigurator.makeModeSnapshot(
      pass: (published: [native, revealed], revealed: nil),
      selectableModes: [revealed], readCurrent: { revealed })
    #expect(snapshot.modes == [revealed])
    #expect(snapshot.nativePixels?.width == 3440)
    #expect(snapshot.nativePixels?.height == 1440)
  }

  @Test func unsafeModesFollowGeometryButDoNotTransferBetweenDisplays() {
    let rejected = RejectedScanoutModes()
    rejected.record(mode(), displayKey: "panel-a:port1")
    #expect(rejected.contains(mode(id: 77), displayKey: "panel-a:port1"))
    #expect(!rejected.contains(mode(), displayKey: "panel-a:port2"))
    #expect(!rejected.contains(mode(hz: 144), displayKey: "panel-a:port1"))
  }

  @Test func quarantiningTheActiveModeDoesNotHideItsReadback() {
    let active = mode()
    let safe = mode(.coreGraphics, pixels: (3440, 1440), native: true, id: 2)
    let snapshot = CoreGraphicsDisplayConfigurator.makeModeSnapshot(
      pass: (published: [safe], revealed: .init(modes: [active], dropped: .init())),
      selectableModes: [safe], readCurrent: { active })
    #expect(snapshot.current == active)
    #expect(snapshot.modes == [safe])
  }

  @Test func aReadingUnchangedFromBeforeTheApplyIsNotEvidence() {
    let before = ScanoutTiming(width: 3440, height: 1440, refreshHz: 175)
    let native120 = mode(.coreGraphics, pixels: (3440, 1440), hz: 120, native: true)
    #expect(ScanoutVerification.verdict(requested: native120, nativePixels: (3440, 1440),
      before: before, after: before) == .notVerifiable)
    // Even an enforced mode: a stale record cannot condemn it.
    #expect(ScanoutVerification.verdict(requested: mode(), nativePixels: (3440, 1440),
      before: before, after: before) == .notVerifiable)
    // Control: the same wrong reading, once it has moved, still condemns it.
    #expect(ScanoutVerification.verdict(requested: mode(), nativePixels: (3440, 1440),
      before: before, after: ScanoutTiming(width: 2560, height: 1440, refreshHz: 120)) == .mismatch)
    // An unchanged reading the request expects verifies.
    #expect(ScanoutVerification.verdict(
      requested: mode(.coreGraphics, pixels: (3440, 1440), hz: 175, native: true),
      nativePixels: (3440, 1440), before: before, after: before) == .verified)
    // With nothing to compare against, a reading that does not verify proves nothing.
    #expect(ScanoutVerification.verdict(requested: mode(), nativePixels: (3440, 1440),
      before: nil, after: ScanoutTiming(width: 2560, height: 1440, refreshHz: 120)) == .notVerifiable)
  }

  @Test func aNativeModeOnAnotherTimingIsRecordedNotWithheld() {
    let native120 = mode(.coreGraphics, pixels: (3440, 1440), hz: 120, native: true)
    #expect(!ScanoutVerification.isEnforced(native120))
    #expect(ScanoutVerification.verdict(requested: native120, nativePixels: (3440, 1440),
      timing: ScanoutTiming(width: 3440, height: 1440, refreshHz: 175)) == .unexpected)
    #expect(ScanoutVerification.verdict(requested: native120, nativePixels: (3440, 1440),
      timing: ScanoutTiming(width: 2560, height: 1440, refreshHz: 120)) == .unexpected)
    let ordinary = mode(.coreGraphics, pixels: (2560, 1080), logical: (2560, 1080), hz: 60)
    #expect(ScanoutVerification.verdict(requested: ordinary, nativePixels: (3440, 1440),
      timing: ScanoutTiming(width: 2560, height: 1080, refreshHz: 100)) == .unexpected)
    #expect(ScanoutVerification.isEnforced(mode()))
    #expect(ScanoutVerification.isEnforced(mode(.synthesized, hz: 0)))
  }

  @Test func aRevealedHiDPIModeOnItsOwnFramebufferTimingPasses() {
    let small = mode(pixels: (2560, 1440), logical: (1280, 720))
    #expect(ScanoutVerification.verdict(requested: small, nativePixels: (3440, 1440),
      timing: ScanoutTiming(width: 2560, height: 1440, refreshHz: 120)) == .verified)
    #expect(ScanoutVerification.verdict(requested: small, nativePixels: (3440, 1440),
      timing: ScanoutTiming(width: 1440, height: 2560, refreshHz: 120)) == .verified)
    let wider = mode(pixels: (3200, 1340), logical: (1600, 670))
    #expect(ScanoutVerification.verdict(requested: wider, nativePixels: (3440, 1440),
      timing: ScanoutTiming(width: 2560, height: 1440, refreshHz: 120)) == .mismatch)
  }

  @Test func noRecordStopsTheSettleWithoutPolling() {
    let configurator = CoreGraphicsDisplayConfigurator()
    var sleeps = 0
    var reads = 0
    let result: ScanoutTiming? = configurator.settled(
      now: { Date(timeIntervalSince1970: 0) }, sleep: { _ in sleeps += 1 },
      read: { reads += 1; return nil }
    ) {
      CoreGraphicsDisplayConfigurator.scanoutSettled(
        $0, before: nil, requested: self.mode(), nativePixels: (3440, 1440))
    }
    #expect(result == nil)
    #expect(reads == 1)
    #expect(sleeps == 0)
  }

  @Test func aStaleRecordKeepsPollingUntilItMoves() {
    let before = ScanoutTiming(width: 3440, height: 1440, refreshHz: 175)
    let requested = mode(.coreGraphics, pixels: (3440, 1440), hz: 120, native: true)
    #expect(!CoreGraphicsDisplayConfigurator.scanoutSettled(
      before, before: before, requested: requested, nativePixels: (3440, 1440)))
    #expect(CoreGraphicsDisplayConfigurator.scanoutSettled(
      ScanoutTiming(width: 3440, height: 1440, refreshHz: 120), before: before,
      requested: requested, nativePixels: (3440, 1440)))
  }

  // MARK: - The real configurator's guard, driven through its probe seam

  private let previous = ScanoutTiming(width: 3440, height: 1440, refreshHz: 175)
  private let foreign = ScanoutTiming(width: 2560, height: 1440, refreshHz: 120)

  @Test func aLateRecordFromThePreviousApplyCannotWithholdTheNextMode() throws {
    // B's pre-apply reading is still the old timing, then A's late timing lands
    // inside B's window, then the window closes.
    let script = ScriptedScanout([previous, previous, foreign])
    let configurator = CoreGraphicsDisplayConfigurator(scanout: script.probe)
    try configurator.guardedApply(mode(), to: 42, enforcesScanout: true,
      nativePixels: { (3440, 1440) }, achieved: { nil }) {}
    // Not withheld: the same mode is not refused the next time.
    try configurator.guardedApply(mode(), to: 42, enforcesScanout: true,
      nativePixels: { (3440, 1440) }, achieved: { nil }) {}
  }

  @Test func aSteadyForeignTimingWithholdsAndRefusesTheMode() throws {
    let script = ScriptedScanout([previous, foreign, foreign])
    let configurator = CoreGraphicsDisplayConfigurator(scanout: script.probe)
    let error = try #require(throws: DisplayConfigError.self) {
      try configurator.guardedApply(self.mode(), to: 42, enforcesScanout: true,
        nativePixels: { (3440, 1440) }, achieved: { self.mode() }) {}
    }
    #expect(error.unhonouredCommit?.scanoutTiming == foreign)
    var committed = false
    let refused = try #require(throws: DisplayConfigError.self) {
      try configurator.guardedApply(self.mode(id: 9), to: 42, enforcesScanout: true,
        nativePixels: { (3440, 1440) }, achieved: { nil }) { committed = true }
    }
    #expect(refused.cgErrorCode == CGError.illegalArgument.rawValue)
    #expect(!committed)
  }

  @Test func theWayBackNeitherRefusesNorWithholds() throws {
    let script = ScriptedScanout([previous, foreign, foreign])
    let configurator = CoreGraphicsDisplayConfigurator(scanout: script.probe)
    _ = try? configurator.guardedApply(mode(), to: 42, enforcesScanout: true,
      nativePixels: { (3440, 1440) }, achieved: { nil }) {}
    script.reset([previous, foreign, foreign])
    var committed = false
    try configurator.guardedApply(mode(), to: 42, enforcesScanout: false,
      nativePixels: { (3440, 1440) }, achieved: { nil }) { committed = true }
    #expect(committed)
  }

  @Test func aModeThatVerifiesStopsTheSettleAtOnce() throws {
    let script = ScriptedScanout([previous, ScanoutTiming(width: 3440, height: 1440, refreshHz: 120)])
    let configurator = CoreGraphicsDisplayConfigurator(scanout: script.probe)
    try configurator.guardedApply(mode(), to: 42, enforcesScanout: true,
      nativePixels: { (3440, 1440) }, achieved: { nil }) {}
    #expect(script.sleeps == 0)
  }

  @Test func anUnchangedRecordOnAWithholdableModeIsNotVerifiable() {
    let script = ScriptedScanout([previous, previous, previous])
    let configurator = CoreGraphicsDisplayConfigurator(scanout: script.probe)
    let result = configurator.settledScanout(
      requested: mode(), nativePixels: (3440, 1440), before: script.next()) { script.next() }
    #expect(result.verdict == .notVerifiable)
  }
}

/// A probe whose reads follow a script and whose clock runs out with it: the
/// window closes the moment the last scripted reading has been taken.
///
/// `@unchecked Sendable`: every stored var is behind `lock`.
final class ScriptedScanout: @unchecked Sendable {
  private let lock = NSLock()
  private var readings: [ScanoutTiming?]
  private var _sleeps = 0

  init(_ readings: [ScanoutTiming?]) { self.readings = readings }

  var sleeps: Int { lock.withLock { _sleeps } }

  func reset(_ readings: [ScanoutTiming?]) { lock.withLock { self.readings = readings } }

  func next() -> ScanoutTiming? {
    lock.withLock { readings.isEmpty ? nil : readings.removeFirst() }
  }

  var probe: CoreGraphicsDisplayConfigurator.ScanoutProbe {
    .init(
      location: { _ in "IOService:/port1/AppleCLCD2" },
      read: { [self] _, _ in next() },
      hardwareIdentity: { _ in "1:2:3" },
      now: { [self] in
        Date(timeIntervalSince1970: lock.withLock { readings.isEmpty } ? 1_000 : 0)
      },
      sleep: { [self] _ in lock.withLock { _sleeps += 1 } })
  }
}
