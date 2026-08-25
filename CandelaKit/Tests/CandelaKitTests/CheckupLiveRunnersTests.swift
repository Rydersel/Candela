import CoreGraphics
import Testing

@testable import CandelaKit

@Suite("Checkup live runners over fakes")
struct CheckupLiveRunnersTests {
  final class FakeDDC: DDCWriting, @unchecked Sendable {
    // Confined to one test; the runner awaits each call in order.
    var values: [UInt8: UInt16] = [VCP.brightness: 50, VCP.contrast: 75]
    var reads: [UInt8] = []
    var writes: [(UInt8, UInt16)] = []
    var answers = true

    func write(command: UInt8, value: UInt16) async -> Bool {
      writes.append((command, value))
      values[command] = value
      return true
    }

    func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
      reads.append(command)
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

  final class FakeHDR: HDRToggling, @unchecked Sendable {
    var supports = true
    var enabled = false
    var settles = true
    var sets: [Bool] = []

    func supportsHDR(displayID: CGDirectDisplayID) async -> Bool { supports }
    func isHDREnabled(displayID: CGDirectDisplayID) async -> Bool { enabled }
    func measuredHDREnabled(displayID: CGDirectDisplayID) async -> Bool { enabled }
    @discardableResult
    func setHDR(displayID: CGDirectDisplayID, enabled: Bool) async -> Bool {
      sets.append(enabled)
      if settles { self.enabled = enabled }
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
    #expect(claims[1].verdict.kind == "observed")
    #expect(hdr.sets == [true, false])
    #expect(hdr.enabled == false)
  }

  @Test func hdrThatDoesNotSettleIsRefused() async {
    let hdr = FakeHDR()
    hdr.settles = false
    let claims = await hdrRunner(hdr, pq: true).run()
    #expect(claims[1].verdict == .refused("toggled on, preferHDRModes stayed off"))
  }
}
