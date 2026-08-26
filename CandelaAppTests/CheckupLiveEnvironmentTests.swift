import CandelaKit
import CoreGraphics
import Testing

/// The decision-bearing half of the live builder; what is left reads the app's
/// own objects and is covered by the hardware pass.
@Suite("Checkup live environment")
struct CheckupLiveEnvironmentTests {
  @Test func entriesExcludeVirtualDisplaysAndMarkTheOnlyDisplay() {
    let entries = CheckupLiveEnvironment.entries(from: [
      source(id: 1, key: "a", name: "Built-in", isBuiltIn: true, pixelWidth: 3024, pixelHeight: 1964),
      source(id: 2, key: "v", name: "Virtual", isVirtual: true, pixelWidth: 1920, pixelHeight: 1080),
    ])
    #expect(entries.map(\.id) == [1])
    #expect(entries[0].isOnlyDisplay)
    #expect(entries[0].panelClass == .noDDC)
  }

  @Test func twoRealDisplaysAreNeitherTheOnlyOne() {
    let entries = CheckupLiveEnvironment.entries(from: [
      source(id: 1, key: "a", name: "Built-in", isBuiltIn: true, pixelWidth: 1, pixelHeight: 1),
      source(id: 2, key: "d", name: "DELL", capabilities: "(vcp(10 12))", hasDDCService: true, pixelWidth: 1, pixelHeight: 1),
    ])
    #expect(entries.allSatisfy { !$0.isOnlyDisplay })
    #expect(entries[1].panelClass == .readsDDC)
  }

  /// With no cached string the plan pre-grades the capability rows as
  /// unobservable, so a Dell whose earlier probe missed would carry that into a saved report.
  @Test @MainActor func aDisplayWithNoCachedStringIsAskedBeforeThePlanIsGraded() async {
    let reads = ReadCount()
    let filled = await CheckupLiveEnvironment.readingLiveState(
      into: [dell(capabilities: nil)],
      writers: ["d": CountingWriter(answer: "(vcp(10 12 62))", reads: reads)],
      hdr: nil)
    #expect(CheckupLiveEnvironment.entries(from: filled)[0].panelClass == .readsDDC)
    #expect(await reads.count == 1)
  }

  /// DDC is dead while HDR is engaged, so the read is skipped rather than spent
  /// and the panel keeps the write-only classing a silent display earns.
  @Test @MainActor func hdrSkipsTheReadEntirely() async {
    let reads = ReadCount()
    var hdr = dell(capabilities: nil)
    hdr.hdrEngaged = true
    let filled = await CheckupLiveEnvironment.readingLiveState(
      into: [hdr],
      writers: ["d": CountingWriter(answer: "(vcp(10 12 62))", reads: reads)],
      hdr: nil)
    #expect(CheckupLiveEnvironment.entries(from: filled)[0].panelClass == .writeOnlyDDC)
    #expect(await reads.count == 0)
    // The classing is untrustworthy in that state, which is why the plan grades
    // the capability rows off `hdrEngaged` and not off the class.
    #expect(CheckupLiveEnvironment.entries(from: filled)[0].hdrEngaged)
  }

  @Test @MainActor func aCachedStringIsNotReReadOverTheWire() async {
    let reads = ReadCount()
    let filled = await CheckupLiveEnvironment.readingLiveState(
      into: [dell(capabilities: "(vcp(10 12))")],
      writers: ["d": CountingWriter(answer: nil, reads: reads)],
      hdr: nil)
    #expect(filled[0].capabilities == "(vcp(10 12))")
    #expect(await reads.count == 0)
  }

  /// A display mirroring another has no `NSScreen`, so no field can be drawn on
  /// it: a run there books emission and grades attestations for a blank panel.
  @Test func entriesExcludeAMirroringDisplay() {
    let entries = CheckupLiveEnvironment.entries(from: [
      source(id: 1, key: "a", name: "Built-in", isBuiltIn: true, pixelWidth: 1, pixelHeight: 1),
      source(id: 2, key: "m", name: "MAG", isMirroring: true, pixelWidth: 1, pixelHeight: 1),
    ])
    #expect(entries.map(\.id) == [1])
    // The survivor is the only display, which is what the strip and the plant's
    // exclusion band both key on.
    #expect(entries[0].isOnlyDisplay)
  }

  /// The plan and the pick page both read this off the entry.
  @Test func hdrEngagedRidesThroughToTheEntry() {
    let entries = CheckupLiveEnvironment.entries(from: [
      source(id: 2, key: "d", name: "DELL", capabilities: "(vcp(10 12))", hasDDCService: true,
             hdrEngaged: true, pixelWidth: 3840, pixelHeight: 2160, pointHeight: 2160)
    ])
    #expect(entries[0].hdrEngaged)
    #expect(entries[0].pointHeight == 2160)
    // The class is still what the string says; HDR is a run condition, not a
    // property of the panel.
    #expect(entries[0].panelClass == .readsDDC)
  }

  /// The app's cached HDR mirror is not a true mirror of the panel: HDR
  /// engaged from outside the app leaves it reading `false`, which pre-grades
  /// the capability rows write-only when readback cannot be observed at all.
  @Test @MainActor func hdrIsMeasuredFromTheDisplayRatherThanTheCachedMirror() async {
    let filled = await CheckupLiveEnvironment.readingLiveState(
      into: [dell(capabilities: "(vcp(10 12))")],
      writers: [:],
      hdr: MeasuredHDR(measured: true))
    let entry = CheckupLiveEnvironment.entries(from: filled)[0]
    #expect(entry.hdrEngaged)
    let caps = CheckupPlan.make(panelClass: entry.panelClass, hdrEngaged: entry.hdrEngaged)
      .filter { $0.family == .capabilities }
    #expect(caps.count == 3)
    #expect(caps.allSatisfy { $0.pregraded == .notObserved(CheckupPlan.hdrEngagedCapabilityText) })
  }

  /// The inverse, so the measurement is the answer in both directions: a mirror
  /// left reading engaged after HDR was turned off outside the app does not
  /// cost a Dell its capability rows.
  @Test @MainActor func aMeasuredReadClearsAStaleEngagedMirror() async {
    var stale = dell(capabilities: "(vcp(10 12))")
    stale.hdrEngaged = true
    let filled = await CheckupLiveEnvironment.readingLiveState(
      into: [stale], writers: [:], hdr: MeasuredHDR(measured: false))
    let entry = CheckupLiveEnvironment.entries(from: filled)[0]
    #expect(!entry.hdrEngaged)
    let caps = CheckupPlan.make(panelClass: entry.panelClass, hdrEngaged: entry.hdrEngaged)
      .filter { $0.family == .capabilities }
    #expect(caps.allSatisfy { $0.pregraded == nil })
  }

  private func dell(capabilities: String?) -> CheckupLiveEnvironment.Source {
    source(
      id: 2, key: "d", name: "DELL", capabilities: capabilities, hasDDCService: true,
      pixelWidth: 3840, pixelHeight: 2160, pointHeight: 2160)
  }

  private func source(
    id: CGDirectDisplayID, key: String, name: String, isBuiltIn: Bool = false,
    isVirtual: Bool = false, isMirroring: Bool = false, capabilities: String? = nil,
    hasDDCService: Bool = false, hdrEngaged: Bool = false, pixelWidth: Int,
    pixelHeight: Int, pointHeight: Double = 1
  ) -> CheckupLiveEnvironment.Source {
    .init(
      id: id, identityKey: key, name: name, isBuiltIn: isBuiltIn, isVirtual: isVirtual,
      isMirroring: isMirroring, capabilities: capabilities, hasDDCService: hasDDCService,
      hdrEngaged: hdrEngaged, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
      pointHeight: pointHeight)
  }
}

private actor ReadCount {
  private(set) var count = 0
  func note() { count += 1 }
}

private struct CountingWriter: DDCWriting {
  let answer: String?
  let reads: ReadCount

  func write(command _: UInt8, value _: UInt16) async -> Bool { false }
  func read(command _: UInt8) async -> (current: UInt16, max: UInt16)? { nil }
  func readCapabilityString() async -> String? {
    await reads.note()
    return answer
  }
}

/// Answers the read-through with a fixed value while the cached question says
/// the opposite, which is the split the checkup has to get right.
private struct MeasuredHDR: HDRToggling {
  let measured: Bool

  func supportsHDR(displayID _: CGDirectDisplayID) async -> Bool { true }
  func isHDREnabled(displayID _: CGDirectDisplayID) async -> Bool { !measured }
  func measuredHDREnabled(displayID _: CGDirectDisplayID) async -> Bool { measured }
  @discardableResult
  func setHDR(displayID _: CGDirectDisplayID, enabled _: Bool) async -> Bool { false }
  func displaysReconfigured() async {}
}
