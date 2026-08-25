import CandelaKit
import Testing

/// The decision-bearing half of the live environment builder: virtual displays
/// out (CK26), the only-display flag, the panel class each source resolves to,
/// and the capability read that has to land before any of that is graded. What
/// is left reads the app's own objects and is covered by the hardware pass.
@Suite("Checkup live environment")
struct CheckupLiveEnvironmentTests {
  @Test func entriesExcludeVirtualDisplaysAndMarkTheOnlyDisplay() {
    let entries = CheckupLiveEnvironment.entries(from: [
      .init(id: 1, identityKey: "a", name: "Built-in", isBuiltIn: true, isVirtual: false, capabilities: nil, hasDDCService: false, pixelWidth: 3024, pixelHeight: 1964),
      .init(id: 2, identityKey: "v", name: "Virtual", isBuiltIn: false, isVirtual: true, capabilities: nil, hasDDCService: false, pixelWidth: 1920, pixelHeight: 1080),
    ])
    #expect(entries.map(\.id) == [1])
    #expect(entries[0].isOnlyDisplay)
    #expect(entries[0].panelClass == .noDDC)
  }

  @Test func twoRealDisplaysAreNeitherTheOnlyOne() {
    let entries = CheckupLiveEnvironment.entries(from: [
      .init(id: 1, identityKey: "a", name: "Built-in", isBuiltIn: true, isVirtual: false, capabilities: nil, hasDDCService: false, pixelWidth: 1, pixelHeight: 1),
      .init(id: 2, identityKey: "d", name: "DELL", isBuiltIn: false, isVirtual: false, capabilities: "(vcp(10 12))", hasDDCService: true, pixelWidth: 1, pixelHeight: 1),
    ])
    #expect(entries.allSatisfy { !$0.isOnlyDisplay })
    #expect(entries[1].panelClass == .readsDDC)
  }

  /// The defect this covers: with no cached string the plan pre-grades the
  /// three capability rows as "readback cannot be observed", so a Dell whose
  /// earlier probe missed would carry that claim into a saved report. The read
  /// has to answer on the build the plan is made from.
  @Test @MainActor func aDisplayWithNoCachedStringIsAskedBeforeThePlanIsGraded() async {
    let reads = ReadCount()
    let filled = await CheckupLiveEnvironment.readingCapabilities(
      into: [dell(capabilities: nil)],
      probes: ["d": .init(
        writer: CountingWriter(answer: "(vcp(10 12 62))", reads: reads), hdrEngaged: false)])
    #expect(CheckupLiveEnvironment.entries(from: filled)[0].panelClass == .readsDDC)
    #expect(await reads.count == 1)
  }

  /// DDC is dead while HDR is engaged, so the read is skipped rather than spent
  /// and the panel keeps the write-only classing a silent display earns.
  @Test @MainActor func hdrSkipsTheReadEntirely() async {
    let reads = ReadCount()
    let filled = await CheckupLiveEnvironment.readingCapabilities(
      into: [dell(capabilities: nil)],
      probes: ["d": .init(
        writer: CountingWriter(answer: "(vcp(10 12 62))", reads: reads), hdrEngaged: true)])
    #expect(CheckupLiveEnvironment.entries(from: filled)[0].panelClass == .writeOnlyDDC)
    #expect(await reads.count == 0)
  }

  @Test @MainActor func aCachedStringIsNotReReadOverTheWire() async {
    let reads = ReadCount()
    let filled = await CheckupLiveEnvironment.readingCapabilities(
      into: [dell(capabilities: "(vcp(10 12))")],
      probes: ["d": .init(writer: CountingWriter(answer: nil, reads: reads), hdrEngaged: false)])
    #expect(filled[0].capabilities == "(vcp(10 12))")
    #expect(await reads.count == 0)
  }

  private func dell(capabilities: String?) -> CheckupLiveEnvironment.Source {
    .init(
      id: 2, identityKey: "d", name: "DELL", isBuiltIn: false, isVirtual: false,
      capabilities: capabilities, hasDDCService: true, pixelWidth: 3840, pixelHeight: 2160)
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
