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

    await rig.model.recoverInterruptedDims()
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

    await rig.model.recoverInterruptedDims()
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

  @Test(arguments: [false, true])
  func aFailedTwinKeepsTheSharedRecoveryMarker(reversed: Bool) async {
    let rig = await makeRig(reversed: reversed)
    defer { rig.clearPrefs() }
    rig.writers[0].writesSucceed = false
    await rig.model.recoverInterruptedDims()
    #expect(rig.prefs.temporaryDimEngaged)
    #expect(rig.model.isNativeBrightnessPolling)
    #expect(rig.writers.allSatisfy { !$0.writes.isEmpty })
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

@Suite("Launch brightness recovery before polling")
@MainActor
struct LaunchDimRecoveryTests {
  @Test(arguments: [false, true])
  func aLiveTwinDepartureCannotClearTheSharedMarkerDuringRecovery(beginsDuringRecovery: Bool) async throws {
    let key = "app-tests-departed-dim-\(UUID().uuidString)"
    defer { clearPrefs(key) }
    let prefs = DisplayPrefs(persistenceKey: key)
    prefs.combinedSwitchingPoint = -8
    prefs.temporaryDimEngaged = true
    UserDefaults.standard.set(0.8, forKey: "combinedBrightness.\(key)")
    let writer = RecoveryWriteGate()
    let otherWriter = FakeDDCWriter()
    var entries = [entry(id: 901, key: key, writer: writer), entry(id: 902, key: key, writer: otherWriter)]
    let model = AppModel(
      shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(), audioDevices: FakeAudio(),
      discoverDisplays: { _ in .init(controlled: entries, report: .notEnumerated) })
    await model.refresh()
    let live = try #require(model.controller(for: 902))
    if !beginsDuringRecovery {
      live.beginTemporaryDim(factor: 0.2)
      await live.waitForPendingWrites()
    }
    let recovery = Task { await model.recoverInterruptedDims() }
    await writer.waitForWrite()
    if beginsDuringRecovery {
      live.beginTemporaryDim(factor: 0.2)
      await live.waitForPendingWrites()
    }

    // Remove both displays so rediscovery does not itself wait on the held
    // writer. The absent twin's physical register still carries its live dim.
    entries = []
    await model.refresh()
    #expect(model.displays.isEmpty)
    #expect(live.temporaryDimFactor == 0.2)
    await writer.release()
    await recovery.value
    #expect(prefs.temporaryDimEngaged)
  }

  @Test func pollingWaitsUntilTheRecoveryWriteCompletes() async {
    let key = "app-tests-launch-dim-\(UUID().uuidString)"
    defer { clearPrefs(key) }
    let prefs = DisplayPrefs(persistenceKey: key)
    prefs.combinedSwitchingPoint = -8
    prefs.temporaryDimEngaged = true
    UserDefaults.standard.set(0.8, forKey: "combinedBrightness.\(key)")
    let writer = RecoveryWriteGate()
    let model = makeModel(key: key, writer: writer)
    await model.refresh()
    #expect(!model.isNativeBrightnessPolling)
    model.notePollConsumerAppeared()
    #expect(!model.isNativeBrightnessPolling)

    var finished = false
    let recovery = Task {
      await model.recoverInterruptedDims()
      finished = true
    }
    await writer.waitForWrite()
    #expect(!finished)
    #expect(!model.isNativeBrightnessPolling)
    #expect(prefs.temporaryDimEngaged)
    #expect(UserDefaults.standard.double(forKey: "combinedBrightness.\(key)") == 0.8)

    await writer.release()
    await recovery.value
    #expect(finished)
    #expect(model.isNativeBrightnessPolling)
    #expect(!prefs.temporaryDimEngaged)
    #expect(await writer.values == [80])

    // A later rediscovery must rebuild polling without repeating launch recovery.
    await model.refresh()
    #expect(model.isNativeBrightnessPolling)
    #expect(await writer.values == [80])
  }

  @Test func safeModeStartsPollingWithoutConsumingTheRecoveryMarker() async {
    let key = "app-tests-safe-launch-dim-\(UUID().uuidString)"
    defer { clearPrefs(key) }
    let prefs = DisplayPrefs(persistenceKey: key)
    prefs.temporaryDimEngaged = true
    UserDefaults.standard.set(0.8, forKey: "combinedBrightness.\(key)")
    let writer = FakeDDCWriter()
    let model = makeModel(key: key, writer: writer, safeMode: true)
    await model.refresh()
    #expect(!model.isNativeBrightnessPolling)
    await model.recoverInterruptedDims()
    #expect(model.isNativeBrightnessPolling)
    #expect(prefs.temporaryDimEngaged)
    #expect(writer.writes.isEmpty)
  }

  private func makeModel(
    key: String, writer: any DDCWriting, safeMode: Bool = false
  ) -> AppModel {
    AppModel(
      shade: FakeShade(), gamma: FakeGamma(), hdrToggling: FakeHDR(), audioDevices: FakeAudio(),
      safeMode: safeMode,
      discoverDisplays: { _ in
        .init(controlled: [entry(id: 901, key: key, writer: writer)], report: .notEnumerated)
      })
  }

  private func entry(id: CGDirectDisplayID, key: String, writer: any DDCWriting)
    -> AppModel.DiscoveredDisplays.Element {
    (
      display: ExternalDisplay(id: id, name: "Recovery panel", persistenceKey: key),
      writer: writer,
      facts: DisplayHardwareFacts(
        transportUpstream: nil, transportDownstream: nil, manufacturerID: nil,
        alphanumericSerialNumber: nil, numericSerialNumber: nil,
        physicalWidthCm: nil, physicalHeightCm: nil, ioDisplayLocation: nil,
        ioregMatchScore: 0)
    )
  }

  private func clearPrefs(_ key: String) {
    for name in UserDefaults.standard.dictionaryRepresentation().keys where name.hasSuffix(".\(key)") {
      UserDefaults.standard.removeObject(forKey: name)
    }
  }
}

private actor RecoveryWriteGate: DDCWriting {
  private(set) var values: [UInt16] = []
  private var releaseWaiter: CheckedContinuation<Void, Never>?
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var released = false

  func write(command: UInt8, value: UInt16) async -> Bool {
    values.append(value)
    if !released {
      await withCheckedContinuation { continuation in
        releaseWaiter = continuation
        startWaiter?.resume()
        startWaiter = nil
      }
    }
    return true
  }

  func read(command: UInt8) -> (current: UInt16, max: UInt16)? { nil }
  func readCapabilityString() -> String? { nil }

  func waitForWrite() async {
    guard releaseWaiter == nil else { return }
    await withCheckedContinuation { startWaiter = $0 }
  }

  func release() {
    released = true
    releaseWaiter?.resume()
    releaseWaiter = nil
  }
}
