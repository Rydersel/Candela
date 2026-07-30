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
    dragPerfLog.log("ddc.write.start value=\(value)")
    let ok = Arm64DDC.write(service: box.service, command: command, value: value)
    dragPerfLog.log("ddc.write.end value=\(value) ok=\(ok)")
    return ok
  }

  public func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
    Arm64DDC.read(service: box.service, command: command)
  }
}
