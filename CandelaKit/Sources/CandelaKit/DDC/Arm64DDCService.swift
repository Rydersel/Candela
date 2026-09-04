import CandelaPrivateAPIs
import os

/// Serializes DDC I/O for one display's IOAVService (spec §5: serial per-display actor).
public actor Arm64DDCService: DDCWriting {
  /// Wraps CFTypeRef to satisfy strict concurrency: the actor serializes all access,
  /// so multiple tasks cannot race on the service reference.
  private struct ServiceBox: @unchecked Sendable {
    let service: IOAVService?
  }

  private let box: ServiceBox

  private init(box: ServiceBox) {
    self.box = box
  }

  nonisolated static func create(service: IOAVService?) -> Arm64DDCService {
    Arm64DDCService(box: ServiceBox(service: service))
  }

  public func write(command: UInt8, value: UInt16) async -> Bool {
    // start/end pair also exposes the per-transaction duration (~30 ms).
    // `.info`: the default level persists every one of these to disk at drag
    // rate, and `.debug` is invisible to the `log show` the regression rig parses.
    dragPerfLog.info("ddc.write.start value=\(value)")
    let ok = Arm64DDC.write(service: box.service, command: command, value: value)
    dragPerfLog.info("ddc.write.end value=\(value) ok=\(ok)")
    return ok
  }

  public func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
    Arm64DDC.read(service: box.service, command: command)
  }

  public func readCapabilityString() async -> String? {
    var bytes: [UInt8] = []
    var offset: UInt16 = 0
    // Real strings run 200–800 bytes. The caps exist so a panel that never
    // returns the empty terminator cannot hold the bus forever.
    for _ in 0 ..< 128 {
      guard let fragment = Arm64DDC.readCapabilityFragment(service: box.service, offset: offset) else {
        // A failed fragment mid-string leaves a TRUNCATED string, which the
        // parser could read as a short-but-clean vcp list. Report failure
        // instead of handing it something plausible and wrong.
        return nil
      }
      if fragment.isEmpty { break }
      bytes.append(contentsOf: fragment)
      offset &+= UInt16(fragment.count)
      if bytes.count > 4096 { return nil }
    }
    guard !bytes.isEmpty else { return nil }
    // Trailing NULs and surrounding whitespace are the wire's, not the
    // display's — see `CapabilityPayload`. Trimming them HERE is what lets
    // `CapabilityString.outerGroupInterior` keep refusing to guess at a
    // wrapper. [MEASURED] the DELL U2725QE terminates with one NUL.
    return CapabilityPayload.string(from: bytes)
  }
}
