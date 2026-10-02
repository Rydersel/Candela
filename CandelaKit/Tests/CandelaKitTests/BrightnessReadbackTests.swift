import Foundation
import Testing
@testable import CandelaKit

private actor PausedBrightnessRead: DDCWriting {
  private(set) var started = false
  private var continuation: CheckedContinuation<Void, Never>?

  func write(command _: UInt8, value _: UInt16) async -> Bool { true }
  func read(command _: UInt8) async -> (current: UInt16, max: UInt16)? {
    started = true
    await withCheckedContinuation { continuation = $0 }
    return (60, 120)
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor PausedRecoveryRead: DDCWriting {
  private var raw: UInt16 = 80
  private var reads = 0
  private(set) var verifying = false
  private var continuation: CheckedContinuation<Void, Never>?

  func write(command _: UInt8, value: UInt16) -> Bool { raw = value; return true }
  func read(command _: UInt8) async -> (current: UInt16, max: UInt16)? {
    reads += 1
    let current = raw
    if reads == 2 {
      verifying = true
      await withCheckedContinuation { continuation = $0 }
    }
    return (current, 100)
  }
  func release() { continuation?.resume(); continuation = nil }
}

@Suite("Readable brightness adoption") @MainActor
struct BrightnessReadbackTests {
  @Test(arguments: [false, true])
  func anHDRTransitionSupersedesAnInFlightSDRRead(overlay: Bool) async throws {
    let h = Harness(settle: .seconds(10)) { prefs, _ in prefs.avoidGamma = overlay }
    await h.prime()
    h.controller.setBrightness(0.25)
    await h.controller.waitForPendingWrites()
    let wire = PausedBrightnessRead()
    h.controller.rebind(writer: wire, panelIdentity: "t")
    let read = Task { await h.controller.refreshFromHardware() }
    let readLimit = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await wire.started) && ContinuousClock.now < readLimit { await Task.yield() }
    #expect(await wire.started)
    let hdr = Task { await h.controller.setHDRMode(.alwaysOn) }
    let hdrLimit = ContinuousClock.now.advanced(by: .seconds(2))
    while !h.controller.isHDREngaged && ContinuousClock.now < hdrLimit { await Task.yield() }
    #expect(h.controller.isHDREngaged)
    #expect(h.controller.isHDRSettling)
    let gammaBefore = h.gamma.scales
    let shadeBefore = h.shade.alphaCalls.count
    await wire.release()
    await read.value
    #expect(h.controller.brightness == 0.25)
    #expect(h.store.values[Harness.storageKey] == 0.25)
    #expect(h.gamma.scales == gammaBefore)
    #expect(h.shade.alphaCalls.count == shadeBefore)
    // Read evidence remains useful even though the SDR value is obsolete.
    #expect(h.controller.readEvidence == .answered)
    #expect(h.controller.maxDDCValue == 120)
    // Cancellation shortens only the test's settle sleep; await all continuations.
    hdr.cancel()
    await hdr.value
    await h.controller.waitForPendingWrites()
    #expect(h.native.targets().last == .native(0.25))
  }

  @Test func anHDRTransitionDoesNotConsumePendingQuitRecoveryEvidence() async throws {
    let h = Harness(settle: .seconds(10), seed: [Harness.storageKey: 0.8]) { prefs, _ in
      prefs.quitBrightnessHandback = QuitBrightnessHandback(
        id: UUID(), savedLogical: 0.8, quitLogical: 0.8, mapping: .init(prefs),
        raw: 80, effectiveMaximum: 100)
    }
    await h.prime()
    let record = try #require(h.prefs.quitBrightnessHandback)
    let wire = PausedRecoveryRead()
    // Keep the initial panel identity so this remains the same recovery lease.
    h.controller.rebind(writer: wire, panelIdentity: nil)
    let read = Task { await h.controller.refreshFromHardware() }
    let readLimit = ContinuousClock.now.advanced(by: .seconds(2))
    while !(await wire.verifying) && ContinuousClock.now < readLimit { await Task.yield() }
    #expect(await wire.verifying)
    let hdr = Task { await h.controller.setHDRMode(.alwaysOn) }
    let hdrLimit = ContinuousClock.now.advanced(by: .seconds(2))
    while !h.controller.isHDREngaged && ContinuousClock.now < hdrLimit { await Task.yield() }
    #expect(h.controller.isHDREngaged)
    await wire.release()
    await read.value
    #expect(h.prefs.quitBrightnessHandback?.id == record.id)
    #expect(h.controller.brightness == 0.8)
    #expect(h.store.values[Harness.storageKey] == 0.8)
    hdr.cancel()
    await hdr.value
    await h.controller.waitForPendingWrites()
  }

  /// An OSD change above the hardware floor ends the software dim, without
  /// writing the newly observed register back to the monitor.
  @Test(arguments: [false, true])
  func anOSDRiseClearsTheSoftwareDim(overlay: Bool) async {
    let h = Harness(withHDR: false) { prefs, _ in prefs.avoidGamma = overlay }
    h.controller.setBrightness(0.25)
    await h.controller.waitForPendingWrites()
    let writesBefore = await h.ddc.recordedWrites().count
    await h.ddc.setReadResult((current: 60, max: 100))

    await h.controller.refreshFromHardware()
    await h.controller.waitForPendingWrites()

    #expect(h.controller.brightness == 0.8)
    #expect(h.store.values[Harness.storageKey] == 0.8)
    if overlay {
      #expect(h.shade.alphaCalls.last?.alpha == 0)
    } else {
      #expect(h.gamma.scales.last == 1)
    }
    #expect(await h.ddc.recordedWrites().count == writesBefore)
  }

  @Test func anOSDMoveToZeroFromTheHardwareBandAdoptsTheBoundary() async {
    let h = Harness(withHDR: false)
    h.controller.setBrightness(0.8)
    await h.controller.waitForPendingWrites()
    await h.ddc.setReadResult((current: 0, max: 100))
    await h.controller.refreshFromHardware()
    #expect(h.controller.brightness == 0.5)
    #expect(h.store.values[Harness.storageKey] == 0.5)
    #expect(h.controller.readEvidence == .answered)
  }

  /// Inversion maps register zero to full brightness, not the software band.
  @Test func anInvertedRegisterZeroAdoptsFullBrightness() async {
    let h = Harness(withHDR: false) { prefs, _ in
      var tuning = prefs.tuning(for: .brightness)
      tuning.invert = true
      prefs.setTuning(tuning, for: .brightness)
    }
    h.controller.setBrightness(0.25)
    await h.controller.waitForPendingWrites()
    await h.ddc.setReadResult((current: 0, max: 100))
    await h.controller.refreshFromHardware()
    #expect(h.controller.brightness == 1)
    #expect(h.store.values[Harness.storageKey] == 1)
    #expect(h.gamma.scales.last == 1)
  }

  /// The tuned hardware floor cannot distinguish any of the software values.
  @Test(arguments: [false, true])
  func aTunedHardwareFloorPreservesTheSoftwareValue(inverted: Bool) async {
    let h = Harness(withHDR: false) { prefs, _ in
      var tuning = prefs.tuning(for: .brightness)
      tuning.minDDCOverride = 20
      tuning.maxDDCOverride = 80
      tuning.invert = inverted
      prefs.setTuning(tuning, for: .brightness)
    }
    h.controller.setBrightness(0.25)
    await h.controller.waitForPendingWrites()
    let gammaBefore = h.gamma.scales
    await h.ddc.setReadResult((current: inverted ? 80 : 20, max: 100))
    await h.controller.refreshFromHardware()
    #expect(h.controller.brightness == 0.25)
    #expect(h.store.values[Harness.storageKey] == 0.25)
    #expect(h.gamma.scales == gammaBefore)
  }
}
