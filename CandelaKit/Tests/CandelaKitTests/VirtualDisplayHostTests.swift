import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// The one suite allowed to create a REAL virtual display, gated so a plain
/// `swift test` never touches the machine's topology. Run explicitly with:
///
///   CANDELA_VD_LIVE=1 swift test --filter VirtualDisplayHostTests
///
/// One display only: a process can enumerate modes for only the first
/// virtual display it creates, and multi-display scenarios belong to the
/// two-process rig (tools/vdrig).
/// `.serialized`: with the default parallel runner, the live create was
/// observed to collect a spurious `initWithDescriptor:` refusal while the
/// suite's other tests ran concurrently; alone it passes every time. Real
/// topology is shared state, so the suite opts out of parallelism.
@Suite("Virtual display host (live, gated)", .serialized)
struct VirtualDisplayHostTests {
  static var isLive: Bool { ProcessInfo.processInfo.environment["CANDELA_VD_LIVE"] == "1" }

  private func isOnline(_ id: CGDirectDisplayID) -> Bool {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return false }
    return ids.prefix(Int(count)).contains(id)
  }

  @Test(.enabled(if: isLive))
  func aSlotIsCreatedAppearsOnlineAndDeparts() {
    let host = VirtualDisplayHost()
    #expect(host.isAvailable)

    // The slot's DEFAULT name, deliberately: the profile filename is minted
    // from the name on the identity's first-ever creation, and this test must
    // not brand the machine's permanent slot-1 profile with a test string.
    let spec = VirtualDisplaySpec(
      name: VirtualDisplayIdentity.defaultName(slot: 1), logicalWidth: 1920, logicalHeight: 1080,
      hiDPI: false, refreshHz: 60
    )
    let result = host.create(spec, slot: 1, uuid: UUID(), appearanceTimeout: 10)
    guard case let .success(handle) = result else {
      Issue.record("create failed: \(result)")
      return
    }
    #expect(isOnline(handle.displayID))
    #expect(host.ownedDisplayIDs.contains(handle.displayID))
    #expect(host.live().count == 1)

    // A second create on the same slot must refuse without touching the
    // display.
    if case .success = host.create(spec, slot: 1, uuid: UUID(), appearanceTimeout: 5) {
      Issue.record("occupied slot accepted a second create")
    }

    #expect(host.destroy(slot: 1, departureTimeout: 10))
    #expect(!isOnline(handle.displayID))
    #expect(host.ownedDisplayIDs.isEmpty)
  }

  /// The unavailable and unoccupied paths cost nothing and run ungated.
  @Test func destroyingAnEmptySlotIsANoOp() {
    let host = VirtualDisplayHost()
    #expect(host.destroy(slot: 2, departureTimeout: 0.1))
    #expect(host.live().isEmpty)
    #expect(host.ownedDisplayIDs.isEmpty)
  }

  @Test func slotsOutsideTheRangeAreRefused() {
    let host = VirtualDisplayHost()
    let spec = VirtualDisplaySpec(
      name: "X", logicalWidth: 800, logicalHeight: 600, hiDPI: false, refreshHz: 60
    )
    #expect(host.create(spec, slot: 0, uuid: UUID(), appearanceTimeout: 0.1)
      == .failure(.capExceeded))
    #expect(host.create(spec, slot: 4, uuid: UUID(), appearanceTimeout: 0.1)
      == .failure(.capExceeded))
  }
}
