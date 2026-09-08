import CandelaPrivateAPIs
import CoreGraphics
import os

/// One line per DDC read. Nothing else reports which of the two silent verdicts
/// a panel earned, and that is the whole of a write-only panel's signature.
let ddcReadLog = Logger(subsystem: "com.rydersel.Candela", category: "ddcread")

/// Serializes DDC I/O for one display's IOAVService (spec §5: serial per-display actor).
public actor Arm64DDCService: DDCWriting {
  /// Wraps CFTypeRef to satisfy strict concurrency: the actor serializes all access,
  /// so multiple tasks cannot race on the service reference.
  private struct ServiceBox: @unchecked Sendable {
    let service: IOAVService?
  }

  private let box: ServiceBox
  /// This display's bus floor, shared with every service ever built for it: a
  /// service retired mid-drain cannot spend the new one's floor.
  private let pacer: DDCBusPacer
  /// Hashed: a raw persistence key can embed the panel's serial number and
  /// these log lines are `.public`.
  private let logTag: String

  private init(box: ServiceBox, pacer: DDCBusPacer, logTag: String) {
    self.box = box
    self.pacer = pacer
    self.logTag = logTag
  }

  /// `displayID` keys the shared pacer; `logTag` is `DisplayLogging.tag(for:)` of
  /// the persistence key, so a read verdict is attributable with two panels.
  nonisolated static func create(
    service: IOAVService?, displayID: CGDirectDisplayID, logTag: String
  ) -> Arm64DDCService {
    Arm64DDCService(
      box: ServiceBox(service: service),
      pacer: DDCBusPacerRegistry.shared.pacer(for: displayID),
      logTag: logTag
    )
  }

  public func write(command: UInt8, value: UInt16) async -> Bool {
    // start/end pair also exposes the per-transaction duration: ~14 ms, from
    // the MAG's nine-write ramp measured at 0.129 s.
    // `.info`: the default level persists every one of these to disk at drag
    // rate, and `.debug` is invisible to the `log show` the regression rig parses.
    dragPerfLog.info("ddc.write.start value=\(value)")
    let ok = Arm64DDC.write(service: box.service, command: command, value: value, pacer: pacer)
    dragPerfLog.info("ddc.write.end value=\(value) ok=\(ok)")
    return ok
  }

  public func read(command: UInt8) async -> (current: UInt16, max: UInt16)? {
    await readOutcome(command: command).value
  }

  public func readOutcome(command: UInt8) async -> DDCReadOutcome {
    let outcome = Arm64DDC.readOutcome(service: box.service, command: command, pacer: pacer)
    // The only instrument for which silent branch a panel takes. Reads happen on
    // menu open or wake, not at drag rate, so one line each is cheap; `.info`
    // because `log show` does not persist `.debug`.
    switch outcome {
    case let .frame(current, max):
      ddcReadLog.info("ddc.read display=\(self.logTag, privacy: .public) command=0x\(UInt(command), format: .hex) outcome=frame current=\(current) max=\(max)")
    case .allZeros:
      ddcReadLog.info("ddc.read display=\(self.logTag, privacy: .public) command=0x\(UInt(command), format: .hex) outcome=zeros")
    case .noReply:
      ddcReadLog.info("ddc.read display=\(self.logTag, privacy: .public) command=0x\(UInt(command), format: .hex) outcome=silent")
    }
    return outcome
  }

  public func readCapabilityString() async -> String? {
    // The fragment loop paces itself, but it leaves the bus busy: without this
    // the next write would see an idle bus and skip the floor.
    defer { pacer.recordBusUse() }
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
