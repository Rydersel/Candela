import CandelaKit
import CoreGraphics
import Foundation
import Testing

@Suite("Interrupted dim recovery across shared identities")
@MainActor
struct SharedDimRecoveryTests {
  // A marker belongs to an identity, but every attached controller has its own
  // wire. Clearing it after the first controller strands the second twin.
  @Test(arguments: [false, true])
  func bothTwinsRecoverRegardlessOfDiscoveryOrder(reversed: Bool) async throws {
    let rig = await makeRig(reversed: reversed)
    defer { rig.clearPrefs() }
    #expect(rig.model.displays.count == 2)
    #expect(rig.writers.allSatisfy { $0.writes.isEmpty })

    rig.model.recoverInterruptedDims()
    for state in rig.model.displays { await state.controller.waitForPendingWrites() }

    for writer in rig.writers {
      #expect(writer.writes.filter { $0.command == 0x10 }.map(\.value) == [100])
    }
    #expect(!rig.prefs.temporaryDimEngaged)
  }

  // A live twin must retain its marker even when another twin recovers first.
  // Otherwise a second crash loses the only signal that its register is dimmed.
  @Test(arguments: [false, true])
  func aLiveTwinKeepsTheSharedMarker(reversed: Bool) async throws {
    let rig = await makeRig(reversed: reversed)
    defer { rig.clearPrefs() }
    let live = try #require(rig.model.controller(for: 901))
    live.beginTemporaryDim(factor: 0.2)
    await live.waitForPendingWrites()
    #expect(rig.writers[0].writes.filter { $0.command == 0x10 }.map(\.value) == [20])

    rig.model.recoverInterruptedDims()
    for state in rig.model.displays { await state.controller.waitForPendingWrites() }

    #expect(live.temporaryDimFactor == 0.2)
    #expect(rig.writers[0].writes.filter { $0.command == 0x10 }.map(\.value) == [20])
    #expect(rig.writers[1].writes.filter { $0.command == 0x10 }.map(\.value) == [100])
    #expect(rig.prefs.temporaryDimEngaged)
  }

  private struct Rig {
    let model: AppModel
    let key: String
    let prefs: DisplayPrefs
    let writers: [FakeDDCWriter]

    func clearPrefs() {
      for name in UserDefaults.standard.dictionaryRepresentation().keys where name.hasSuffix(".\(key)") {
        UserDefaults.standard.removeObject(forKey: name)
      }
    }
  }

  private func makeRig(reversed: Bool) async -> Rig {
    let key = "app-tests-shared-dim-\(UUID().uuidString)"
    let prefs = DisplayPrefs(persistenceKey: key)
    prefs.combinedSwitchingPoint = -8
    prefs.temporaryDimEngaged = true
    UserDefaults.standard.set(1.0, forKey: "combinedBrightness.\(key)")
    let writers = [FakeDDCWriter(), FakeDDCWriter()]
    var entries: AppModel.DiscoveredDisplays = writers.enumerated().map { index, writer in
      (
        display: ExternalDisplay(id: CGDirectDisplayID(901 + index), name: "Twin", persistenceKey: key),
        writer: writer,
        facts: DisplayHardwareFacts(
          transportUpstream: nil, transportDownstream: nil, manufacturerID: nil,
          alphanumericSerialNumber: nil, numericSerialNumber: nil,
          physicalWidthCm: nil, physicalHeightCm: nil, ioDisplayLocation: nil,
          ioregMatchScore: 0)
      )
    }
    if reversed { entries.reverse() }
    let model = AppModel(
      shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(), audioDevices: FakeAudio(),
      discoverDisplays: { _ in .init(controlled: entries, report: .notEnumerated) })
    await model.refresh()
    for state in model.displays { await state.controller.waitForPendingWrites() }
    return Rig(model: model, key: key, prefs: prefs, writers: writers)
  }
}
