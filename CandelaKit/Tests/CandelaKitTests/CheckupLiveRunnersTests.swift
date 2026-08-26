import CoreGraphics
import Testing

@testable import CandelaKit

@Suite("Checkup live runners over fakes")
struct CheckupLiveRunnersTests {
  /// `@unchecked Sendable`: the runner awaits every call in order and no instance
  /// leaves its test body, so the recording arrays are confined to one thread.
  final class FakeDDC: DDCWriting, @unchecked Sendable {
    var values: [UInt8: UInt16] = [VCP.brightness: 50, VCP.contrast: 75]
    var reads: [UInt8] = []
    var writes: [(UInt8, UInt16)] = []
    var answers = true
    /// A panel that ACKs the write and does not keep the value.
    var honorsWrites = true
    /// Reads beyond this count return nothing, for the read that dies mid-check.
    var answersReadsUpTo: Int?

    func write(command: UInt8, value: UInt16) async -> Bool {
      writes.append((command, value))
      values[command] = honorsWrites ? value : value &+ 1
      return true
    }

    func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
      reads.append(command)
      if let answersReadsUpTo, reads.count > answersReadsUpTo { return nil }
      guard answers, let v = values[command] else { return nil }
      return (v, 100)
    }
  }

  @Test func capabilitiesRoundTripsOnlyAdvertisedControls() async {
    let ddc = FakeDDC()
    let caps = "(vcp(10 12)mccs_ver(2.1))"
    let claims = await CheckupLiveCapabilitiesRunner(writer: ddc, capabilities: caps).run()
    #expect(
      claims.map(\.id) == [
        CheckupCheckID.capabilityBrightness, CheckupCheckID.capabilityContrast,
        CheckupCheckID.capabilityVolume,
      ])
    #expect(claims[0].verdict.kind == "observed")
    #expect(claims[0].verdict.text.contains("read 50, wrote 50, read 50"))
    #expect(claims[2].verdict == .notObserved("volume (VCP 0x62) is not advertised by this panel"))
    #expect(!ddc.reads.contains(VCP.audioSpeakerVolume))
  }

  @Test func aReadThatReturnsNothingIsRefused() async {
    let ddc = FakeDDC()
    ddc.answers = false
    let claims = await CheckupLiveCapabilitiesRunner(writer: ddc, capabilities: "(vcp(10))").run()
    #expect(claims[0].verdict.kind == "refused")
    #expect(claims[0].verdict.text.contains("no reply"))
    #expect(ddc.writes.isEmpty)
  }

  @Test func aValueTheWriteDidNotKeepIsRefusedDespiteTheACK() async {
    let ddc = FakeDDC()
    ddc.honorsWrites = false
    let claims = await CheckupLiveCapabilitiesRunner(writer: ddc, capabilities: "(vcp(10))").run()
    #expect(claims[0].verdict.kind == "refused")
    #expect(claims[0].verdict.text.contains("the value did not hold"))
    // The panel ACKed: the write is what a return-code check would have graded.
    #expect(ddc.writes.map(\.0) == [VCP.brightness])
  }

  @Test func aSecondReadThatDiesIsRefusedAndSaysWhichReadItWas() async {
    let ddc = FakeDDC()
    ddc.answersReadsUpTo = 1
    let claims = await CheckupLiveCapabilitiesRunner(writer: ddc, capabilities: "(vcp(10))").run()
    #expect(claims[0].verdict == .refused("brightness: read 50, wrote 50, no reply to the second read"))
  }

  @Test func aCapabilitiesStringWeCannotParseIsNotADenial() async {
    let ddc = FakeDDC()
    // Unbalanced, so CapabilityString answers .unknown rather than .unsupported.
    let claims = await CheckupLiveCapabilitiesRunner(writer: ddc, capabilities: "(vcp(10 12)").run()
    #expect(claims.count == 3)
    #expect(claims.allSatisfy { $0.verdict.kind == "notObserved" })
    #expect(claims[0].verdict.text.contains("could not be parsed"))
    #expect(!claims[0].verdict.text.contains("is not advertised"))
    #expect(ddc.reads.isEmpty)
  }

  struct FakeConfigurator: DisplayConfiguring {
    var modeList: [DisplayMode]
    var current: DisplayMode?
    var refuse: Set<Int32> = []

    func displays() -> [ConfiguredDisplay] { [] }
    func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] { modeList }
    func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? { current }
    func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
      modeList.first(where: \.isNative).map { ($0.pixelWidth, $0.pixelHeight) }
    }
    func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws {
      if refuse.contains(mode.ioModeID) {
        throw DisplayConfigError(cgErrorCode: CGError.invalidOperation.rawValue)
      }
    }
    func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {}
    var revealsHiddenModes: Bool { true }
    var guardsWireTiming: Bool { false }
    func modesWithheldByWireTimingGuard(for displayID: CGDirectDisplayID) -> Int { 0 }
    var canRotate: Bool { false }
    func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation? { nil }
    func applyRotation(_ rotation: DisplayRotation, to displayID: CGDirectDisplayID) throws {}
  }

  private func mode(_ id: Int32, w: Int, h: Int, hz: Double, native: Bool = false) -> DisplayMode {
    DisplayMode(
      ioModeID: id, logicalWidth: w, logicalHeight: h, pixelWidth: w, pixelHeight: h,
      refreshHz: hz, isNative: native, provenance: .coreGraphics)
  }

  @Test func nativeModeQuotesAchievedStateAndARefusalNamesItself() async {
    let native = mode(1, w: 3840, h: 2160, hz: 60, native: true)
    let ok = FakeConfigurator(modeList: [native], current: native)
    let claims = await CheckupLiveModeRunner(configurator: ok, displayID: 1).runNativeMode()
    #expect(claims.first?.verdict == .observed("achieved 3840 by 2160 at 60 Hz; macOS reports"))

    let refusing = FakeConfigurator(modeList: [native], current: native, refuse: [1])
    let refused = await CheckupLiveModeRunner(configurator: refusing, displayID: 1).runNativeMode()
    #expect(refused.first?.verdict.kind == "refused")
  }

  @Test func everyApplyIsPreviewScopedSoACrashDoesNotParkThePanel() async {
    let native = mode(1, w: 3840, h: 2160, hz: 60, native: true)
    let recorder = ScopeRecordingConfigurator(modeList: [native])
    let runner = CheckupLiveModeRunner(configurator: recorder, displayID: 1)
    _ = await runner.runNativeMode()
    _ = await runner.runRefreshSweep()
    _ = await runner.restore()
    #expect(!recorder.scopes.isEmpty)
    #expect(recorder.scopes.allSatisfy { $0 == .preview })
  }

  @Test func refreshSweepReportsEachRateAndTheOneThatDidNotAchieve() async {
    let m60 = mode(1, w: 3840, h: 2160, hz: 60, native: true)
    let m120 = mode(2, w: 3840, h: 2160, hz: 120)
    // The fake's currentMode reports whatever was applied except 120, which
    // stays at 60: the wrong-cable cap.
    let configurator = SweepConfigurator(modeList: [m60, m120], capAt: 60)
    let claims = await CheckupLiveModeRunner(configurator: configurator, displayID: 1)
      .runRefreshSweep()
    #expect(claims.map(\.id) == ["refresh.60", "refresh.120"])
    #expect(claims[0].verdict.kind == "observed")
    #expect(claims[1].verdict == .refused("requested 120 Hz, achieved 60 Hz; macOS reports"))
  }

  @Test func ntscAndSixtyAreSweptAsTwoRatesUnderTwoIds() async {
    let m60 = mode(1, w: 3840, h: 2160, hz: 60, native: true)
    let ntsc = mode(2, w: 3840, h: 2160, hz: 59.94)
    let configurator = SweepConfigurator(modeList: [m60, ntsc], capAt: 240)
    let claims = await CheckupLiveModeRunner(configurator: configurator, displayID: 1)
      .runRefreshSweep()
    #expect(claims.map(\.id) == ["refresh.59.9", "refresh.60"])
    #expect(claims.allSatisfy { $0.verdict.kind == "observed" })
    #expect(claims[0].verdict.text.contains("59.9 Hz achieved"))
  }

  @Test func theSweepIgnoresRevealedAndSynthesizedModes() async {
    let m60 = mode(1, w: 3840, h: 2160, hz: 60, native: true)
    let revealed = DisplayMode(
      ioModeID: 2, logicalWidth: 3840, logicalHeight: 2160, pixelWidth: 3840,
      pixelHeight: 2160, refreshHz: 75, isNative: false, provenance: .coreGraphicsServices)
    let synthesized = DisplayMode(
      ioModeID: 3, logicalWidth: 3840, logicalHeight: 2160, pixelWidth: 3840,
      pixelHeight: 2160, refreshHz: 100, isNative: false, provenance: .synthesized)
    let configurator = SweepConfigurator(modeList: [m60, revealed, synthesized], capAt: 240)
    let claims = await CheckupLiveModeRunner(configurator: configurator, displayID: 1)
      .runRefreshSweep()
    #expect(claims.map(\.id) == ["refresh.60"])
  }

  /// Silence would leave the plan's sweep row with no claim at all, which reads
  /// as a check that never ran rather than one with nothing to sweep.
  @Test func aCatalogWithNoNativeModeEmitsTheSweepRowAsNotObserved() async {
    let scaled = mode(1, w: 2560, h: 1440, hz: 60)
    let configurator = SweepConfigurator(modeList: [scaled], capAt: 240)
    let claims = await CheckupLiveModeRunner(configurator: configurator, displayID: 1)
      .runRefreshSweep()
    #expect(claims.map(\.id) == [CheckupCheckID.refreshSweep])
    #expect(
      claims[0].verdict == .notObserved("no native mode in the catalog for this display"))
    #expect(claims[0].family == .refresh)
  }

  @Test func restoreReportsWhetherTheDisplayIsActuallyBackOnItsOriginalMode() async {
    let m60 = mode(1, w: 3840, h: 2160, hz: 60, native: true)
    let m120 = mode(2, w: 3840, h: 2160, hz: 120)

    let willing = SweepConfigurator(modeList: [m60, m120], capAt: 60)
    let runner = CheckupLiveModeRunner(configurator: willing, displayID: 1)
    _ = await runner.runRefreshSweep()
    #expect(await runner.restore())

    // Accepts the apply, reports a different mode: the ACK that means nothing.
    let stubborn = StuckConfigurator(modeList: [m60, m120])
    let stuckRunner = CheckupLiveModeRunner(configurator: stubborn, displayID: 1)
    _ = await stuckRunner.runRefreshSweep()
    stubborn.stuckOn = m120
    #expect(await stuckRunner.restore() == false)
  }

  @Test func restoreWithNothingToPutBackIsNotAFailure() async {
    let empty = FakeConfigurator(modeList: [], current: nil)
    #expect(await CheckupLiveModeRunner(configurator: empty, displayID: 1).restore())
  }

  /// `@unchecked Sendable` for the same reason as `FakeDDC`: the runner actor
  /// awaits each call in order and the instance never leaves its test body.
  final class SweepConfigurator: DisplayConfiguring, @unchecked Sendable {
    let modeList: [DisplayMode]
    let capAt: Double
    var applied: DisplayMode?

    init(modeList: [DisplayMode], capAt: Double) {
      self.modeList = modeList
      self.capAt = capAt
    }

    func displays() -> [ConfiguredDisplay] { [] }
    func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] { modeList }
    func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
      guard let applied else { return modeList.first }
      return applied.refreshHz > capAt ? modeList.first : applied
    }
    func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
      (3840, 2160)
    }
    func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws {
      applied = mode
    }
    func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {}
    var revealsHiddenModes: Bool { true }
    var guardsWireTiming: Bool { false }
    func modesWithheldByWireTimingGuard(for displayID: CGDirectDisplayID) -> Int { 0 }
    var canRotate: Bool { false }
    func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation? { nil }
    func applyRotation(_ rotation: DisplayRotation, to displayID: CGDirectDisplayID) throws {}
  }

  /// Accepts every apply and reports whatever `stuckOn` says: the panel that
  /// answers `ok` and does not move. Same confinement as the fakes above.
  final class StuckConfigurator: DisplayConfiguring, @unchecked Sendable {
    let modeList: [DisplayMode]
    var stuckOn: DisplayMode?

    init(modeList: [DisplayMode]) { self.modeList = modeList }

    func displays() -> [ConfiguredDisplay] { [] }
    func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] { modeList }
    func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
      stuckOn ?? modeList.first
    }
    func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
      (3840, 2160)
    }
    func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws {}
    func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {}
    var revealsHiddenModes: Bool { true }
    var guardsWireTiming: Bool { false }
    func modesWithheldByWireTimingGuard(for displayID: CGDirectDisplayID) -> Int { 0 }
    var canRotate: Bool { false }
    func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation? { nil }
    func applyRotation(_ rotation: DisplayRotation, to displayID: CGDirectDisplayID) throws {}
  }

  /// Records the scope of every apply. Same confinement as the fakes above.
  final class ScopeRecordingConfigurator: DisplayConfiguring, @unchecked Sendable {
    let modeList: [DisplayMode]
    var scopes: [DisplayConfigScope] = []

    init(modeList: [DisplayMode]) { self.modeList = modeList }

    func displays() -> [ConfiguredDisplay] { [] }
    func modes(for displayID: CGDirectDisplayID) -> [DisplayMode] { modeList }
    func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? { modeList.first }
    func nativePixels(for displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
      modeList.first.map { ($0.pixelWidth, $0.pixelHeight) }
    }
    func apply(_ mode: DisplayMode, to displayID: CGDirectDisplayID, scope: DisplayConfigScope) throws {
      scopes.append(scope)
    }
    func applyMirroring(_ changes: [MirrorChange], scope: DisplayConfigScope) throws {}
    var revealsHiddenModes: Bool { true }
    var guardsWireTiming: Bool { false }
    func modesWithheldByWireTimingGuard(for displayID: CGDirectDisplayID) -> Int { 0 }
    var canRotate: Bool { false }
    func rotation(of displayID: CGDirectDisplayID) -> DisplayRotation? { nil }
    func applyRotation(_ rotation: DisplayRotation, to displayID: CGDirectDisplayID) throws {}
  }

  /// `@unchecked Sendable` for the same reason as the configurator fakes: the
  /// runner awaits each call in order and the instance stays in one test body.
  final class FakeHDR: HDRToggling, @unchecked Sendable {
    var supports = true
    var enabled = false
    var settles = true
    var sets: [Bool] = []
    /// Sets past this count are ACKed and change nothing, for the restore that
    /// does not take.
    var honorSetsUpTo: Int?

    func supportsHDR(displayID: CGDirectDisplayID) async -> Bool { supports }
    func isHDREnabled(displayID: CGDirectDisplayID) async -> Bool { enabled }
    func measuredHDREnabled(displayID: CGDirectDisplayID) async -> Bool { enabled }
    @discardableResult
    func setHDR(displayID: CGDirectDisplayID, enabled: Bool) async -> Bool {
      sets.append(enabled)
      let honors = settles && (honorSetsUpTo.map { sets.count <= $0 } ?? true)
      if honors { self.enabled = enabled }
      return true
    }
    func displaysReconfigured() async {}
  }

  private func identity(pq: Bool) -> CheckupDisplayIdentity {
    CheckupDisplayIdentity(
      identityKey: "k", vendorID: 1, modelID: 2, serial: nil, manufactureWeek: nil,
      manufactureYear: nil, nativePixelWidth: 1, nativePixelHeight: 1, maxRefreshHz: nil,
      supportsPQEOTF: pq, supportsHDRGammaEOTF: pq, productName: "x")
  }

  private func hdrRunner(_ hdr: FakeHDR, pq: Bool) -> CheckupLiveHDRRunner {
    CheckupLiveHDRRunner(
      hdr: hdr, displayID: 1, identity: identity(pq: pq),
      settleDelay: .zero, restoreDelay: .zero)
  }

  @Test func hdrWithNoFlagsIsObservedAsUnadvertisedAndNeverToggled() async {
    let hdr = FakeHDR()
    let claims = await hdrRunner(hdr, pq: false).run()
    #expect(claims.map(\.id) == [CheckupCheckID.hdrFlags, CheckupCheckID.hdrSettle])
    #expect(claims[0].verdict == .observed("panel does not advertise HDR (no EOTF flags)"))
    #expect(claims[1].verdict == .notObserved("not attempted: the panel advertises no HDR"))
    #expect(hdr.sets.isEmpty)
  }

  @Test func hdrThatSettlesIsObservedAndRestored() async {
    let hdr = FakeHDR()
    let claims = await hdrRunner(hdr, pq: true).run()
    #expect(claims[1].verdict == .observed("toggled on, preferHDRModes settled on"))
    #expect(hdr.sets == [true, false])
    #expect(hdr.enabled == false)
  }

  @Test func hdrThatDoesNotSettleIsRefused() async {
    let hdr = FakeHDR()
    hdr.settles = false
    let claims = await hdrRunner(hdr, pq: true).run()
    #expect(claims[1].verdict == .refused("toggled on, preferHDRModes stayed off"))
  }

  @Test func aPanelAlreadyInHDRIsToggledOffAndBackSoTheCheckCanFail() async {
    let hdr = FakeHDR()
    hdr.enabled = true
    let claims = await hdrRunner(hdr, pq: true).run()
    // Setting HDR on when it is already on would settle instantly against a
    // state nothing here produced: off first, so there is a transition to see.
    #expect(hdr.sets == [false, true, true])
    #expect(
      claims[1].verdict
        == .observed(
          "toggled off, preferHDRModes settled off; toggled on, preferHDRModes settled on"))
    #expect(hdr.enabled == true)
  }

  @Test func aPanelAlreadyInHDRThatWillNotLeaveItIsRefused() async {
    let hdr = FakeHDR()
    hdr.enabled = true
    hdr.settles = false
    let claims = await hdrRunner(hdr, pq: true).run()
    #expect(hdr.sets == [false, true, true])
    // The on transition "settles" only because the panel never left HDR, which
    // is exactly why one transition on its own is not a check.
    #expect(
      claims[1].verdict
        == .refused(
          "toggled off, preferHDRModes stayed on; toggled on, preferHDRModes settled on"))
  }

  /// A panel left in the other HDR state is an achieved-state miss, so the
  /// claim is refused however cleanly the transitions themselves read.
  @Test func aRestoreThatDoesNotSettleIsSaidOutLoudAndRefusesTheClaim() async {
    let hdr = FakeHDR()
    hdr.honorSetsUpTo = 1
    let claims = await hdrRunner(hdr, pq: true).run()
    #expect(hdr.sets == [true, false])
    #expect(hdr.enabled == true)
    #expect(
      claims[1].verdict
        == .refused(
          "toggled on, preferHDRModes settled on; restore to the prior state did not settle"))
  }
}
