import Testing
@testable import CandelaKit

@Suite("DDCCommandApplier")
struct DDCCommandApplierTests {
  @Test func writesTheCarriedCommandCode() async {
    let fake = FakeDDC()
    let applier = DDCCommandApplier(writer: fake, command: VCP.audioSpeakerVolume)
    #expect(await applier.apply(.ddc(raw: 42)))
    let writes = await fake.recordedWrites()
    #expect(writes.count == 1)
    #expect(writes[0].command == VCP.audioSpeakerVolume)
    #expect(writes[0].value == 42)
  }

  @Test func remapFansOutToEveryCode() async {
    // Fork getRemapControlCodes: writes go to EVERY remapped code.
    let fake = FakeDDC()
    let applier = DDCCommandApplier(writer: fake, command: VCP.contrast, remapCodes: [0x10, 0x2F])
    #expect(await applier.apply(.ddc(raw: 7)))
    let writes = await fake.recordedWrites()
    #expect(writes.map(\.command) == [0x10, 0x2F]) // remap replaces the command, not adds to it
    #expect(writes.map(\.value) == [7, 7])
  }

  @Test func nativeTargetIsRejectedAsWiringBug() async {
    let fake = FakeDDC()
    let applier = DDCCommandApplier(writer: fake, command: VCP.contrast)
    #expect(await applier.apply(.native(0.5)) == false)
    #expect(await fake.recordedWrites().isEmpty)
  }

  @Test func ddcCommandCarriesTheRightVCPCodes() {
    #expect(DDCCommand.brightness.code == VCP.brightness)
    #expect(DDCCommand.volume.code == VCP.audioSpeakerVolume)
    #expect(DDCCommand.contrast.code == VCP.contrast)
    #expect(DDCCommand.allCases == [.brightness, .volume, .contrast])
  }

  @Test func remapFanOutFailurePropagates() async {
    // A false from ANY fanned-out code must surface as a failed apply: the
    // coalescer records its duplicate memo only on success, so a partial
    // fan-out failure must not suppress the retry (test-design F8).
    //
    // The FIRST code fails on purpose: with the last code failing, an
    // accidental short-circuit (`allOK && await write`) would still pass both
    // assertions. Failing 0x10 pins BOTH halves of the contract — the failure
    // propagates AND the fan-out continues to 0x2F.
    let fake = PartialFailDDC(failingCommand: 0x10)
    let applier = DDCCommandApplier(writer: fake, command: VCP.contrast, remapCodes: [0x10, 0x2F])
    #expect(await applier.apply(.ddc(raw: 7)) == false)
    #expect(await fake.recordedWrites().map(\.command) == [0x10, 0x2F]) // no short-circuit past the failure
  }
}

/// Fails writes to one specific code; records everything.
actor PartialFailDDC: DDCWriting {
  private(set) var writes: [(command: UInt8, value: UInt16)] = []
  private let failingCommand: UInt8

  init(failingCommand: UInt8) { self.failingCommand = failingCommand }

  func write(command: UInt8, value: UInt16) async -> Bool {
    writes.append((command, value))
    return command != failingCommand
  }

  func read(command _: UInt8) async -> (current: UInt16, max: UInt16)? { nil }
  func recordedWrites() -> [(command: UInt8, value: UInt16)] { writes }
}
