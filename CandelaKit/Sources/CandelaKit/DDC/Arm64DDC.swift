//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Transplanted from the MonitorControl project (MIT).

import Foundation
import IOKit
import CandelaPrivateAPIs

let ARM64_DDC_7BIT_ADDRESS: UInt8 = 0x37 // This works with DisplayPort devices
let ARM64_DDC_DATA_ADDRESS: UInt8 = 0x51

/// The floor between two packets on one display's I2C bus, measured from the
/// last call's return rather than paid before every packet. Paying it up front
/// cost every command 10 ms of dead time on a transaction measured at about
/// 14 ms, even on a bus idle for minutes; measuring keeps every gap that exists.
///
/// One per display for the life of the process (`DDCBusPacerRegistry`), so two
/// panels never pace each other and two services for one panel never race.
///
/// `@unchecked Sendable`: both fields are confined by `lock` and the clock is a
/// `@Sendable` closure; the static entry points and the registry share it
/// across actors.
final class DDCBusPacer: @unchecked Sendable {
  private let now: @Sendable () -> UInt64
  private let lock = NSLock()
  private var lastCallEnd: UInt64

  /// Injected clock so tests spend no real time. The bus starts SEEN, not quiet:
  /// another writer may have used it microseconds ago, and on a write-only panel
  /// a packet inside the floor fails silently. Costs one floor's wait per display
  /// per process.
  init(now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
    self.now = now
    self.lastCallEnd = now()
  }

  /// Microseconds still owed before the next packet may go out. Zero once the
  /// bus has been quiet longer than the floor.
  func deficit(floor: UInt32) -> UInt32 {
    self.lock.lock()
    defer { self.lock.unlock() }
    let current = self.now()
    // A clock that went backwards pays the full floor: the conservative direction.
    let elapsed = current > self.lastCallEnd ? (current - self.lastCallEnd) / 1000 : 0
    return elapsed >= UInt64(floor) ? 0 : floor - UInt32(elapsed)
  }

  /// Call after every I2C call on this display, whatever it returned: the bus
  /// was busy either way.
  func recordBusUse() {
    self.lock.lock()
    self.lastCallEnd = self.now()
    self.lock.unlock()
  }
}

/// One pacer per display, held for the life of the process. Services are rebuilt
/// on every refresh while the retired one can still drain a queued write
/// (`DDCCommandApplier` holds its writer as a `let`), so a per-service pacer let
/// two pacers each believe one bus was quiet.
///
/// Keyed on display ID, which a replug can reassign; that costs at most one
/// misattributed floor across an interval measured in seconds.
/// `@unchecked Sendable`: the table is confined by `lock`.
final class DDCBusPacerRegistry: @unchecked Sendable {
  static let shared = DDCBusPacerRegistry()

  private let lock = NSLock()
  private var pacers: [CGDirectDisplayID: DDCBusPacer] = [:]

  /// `now` seeds a pacer on first sight only: a rebuilt service does not restart
  /// the clock.
  func pacer(
    for displayID: CGDirectDisplayID,
    now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
  ) -> DDCBusPacer {
    self.lock.lock()
    defer { self.lock.unlock() }
    if let existing = self.pacers[displayID] { return existing }
    let fresh = DDCBusPacer(now: now)
    self.pacers[displayID] = fresh
    return fresh
  }
}

public class Arm64DDC: NSObject {
  static let MAX_MATCH_SCORE: Int = 20

  public struct IOregService {
    var edidUUID: String = ""
    var manufacturerID: String = ""
    var productName: String = ""
    var serialNumber: Int64 = 0
    var alphanumericSerialNumber: String = ""
    var ioDisplayLocation: String = ""
    var transportUpstream: String = ""
    var transportDownstream: String = ""
    var service: IOAVService?
    var serviceLocation: Int = 0
  }

  public struct Arm64Service {
    var displayID: CGDirectDisplayID = 0
    var service: IOAVService?
    var serviceLocation: Int = 0
    var dummy: Bool = false
    var serviceDetails: IOregService
    var matchScore: Int = 0
  }

  public static func getServiceMatches(displayIDs: [CGDirectDisplayID]) -> [Arm64Service] {
    let ioregServicesForMatching = self.getIoregServicesForMatching()
    var matchedDisplayServices: [Arm64Service] = []
    var scoredCandidateDisplayServices: [Int: [Arm64Service]] = [:]
    for displayID in displayIDs {
      for ioregServiceForMatching in ioregServicesForMatching {
        let score = self.ioregMatchScore(displayID: displayID, ioregEdidUUID: ioregServiceForMatching.edidUUID, ioDisplayLocation: ioregServiceForMatching.ioDisplayLocation, ioregProductName: ioregServiceForMatching.productName, ioregSerialNumber: ioregServiceForMatching.serialNumber)
        let dummy = self.checkIfDummy(ioregService: ioregServiceForMatching)
        let displayService = Arm64Service(displayID: displayID, service: ioregServiceForMatching.service, serviceLocation: ioregServiceForMatching.serviceLocation, dummy: dummy, serviceDetails: ioregServiceForMatching, matchScore: score)
        if scoredCandidateDisplayServices[score] == nil {
          scoredCandidateDisplayServices[score] = []
        }
        scoredCandidateDisplayServices[score]?.append(displayService)
      }
    }
    var takenServiceLocations: [Int] = []
    var takenDisplayIDs: [CGDirectDisplayID] = []
    for score in stride(from: self.MAX_MATCH_SCORE, to: 0, by: -1) {
      if let scoredCandidateDisplayService = scoredCandidateDisplayServices[score] {
        for candidateDisplayService in scoredCandidateDisplayService where !(takenDisplayIDs.contains(candidateDisplayService.displayID) || takenServiceLocations.contains(candidateDisplayService.serviceLocation)) {
          takenDisplayIDs.append(candidateDisplayService.displayID)
          takenServiceLocations.append(candidateDisplayService.serviceLocation)
          matchedDisplayServices.append(candidateDisplayService)
        }
      }
    }
    return matchedDisplayServices
  }

  // WARNING: these pacer-less entry points neither pace from the bus nor record
  // use of it, so calling one for a display an `Arm64DDCService` also drives
  // leaves that actor's pacer believing the bus was quiet. Route DDC through
  // the actor.
  public static func read(service: IOAVService?, command: UInt8, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, readSleepTime: UInt32? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> (current: UInt16, max: UInt16)? {
    self.readOutcome(service: service, command: command, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, readSleepTime: readSleepTime, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime).value
  }

  /// `read`, keeping what the wire proved. `command` goes into the ladder so every
  /// ATTEMPT is validated against it; a frame answering another code retries like
  /// a failed read and ends as `noReply` rather than a fourth case.
  public static func readOutcome(service: IOAVService?, command: UInt8, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, readSleepTime: UInt32? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> DDCReadOutcome {
    self.readOutcome(service: service, command: command, pacer: nil, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, readSleepTime: readSleepTime, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime)
  }

  static func readOutcome(service: IOAVService?, command: UInt8, pacer: DDCBusPacer?, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, readSleepTime: UInt32? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> DDCReadOutcome {
    var send: [UInt8] = [command]
    var reply = [UInt8](repeating: 0, count: DDCReplyFrame.expectedLength)
    switch Self.performDDCCommunication(service: service, send: &send, reply: &reply, replyCommand: command, pacer: pacer, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, readSleepTime: readSleepTime, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime) {
    case .ok:
      // Validated per attempt inside the ladder: `.ok` means a frame answering
      // THIS code.
      return .frame(
        current: DDCReplyFrame.value(high: reply[8], low: reply[9]),
        max: DDCReplyFrame.value(high: reply[6], low: reply[7])
      )
    case .answeredZeros:
      return .allZeros
    case .silent:
      return .noReply
    }
  }

  public static func write(service: IOAVService?, command: UInt8, value: UInt16, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> Bool {
    self.write(service: service, command: command, value: value, pacer: nil, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime)
  }

  static func write(service: IOAVService?, command: UInt8, value: UInt16, pacer: DDCBusPacer?, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> Bool {
    var send: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 255)]
    var reply: [UInt8] = []
    return Self.performDDCCommunication(service: service, send: &send, reply: &reply, pacer: pacer, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime) == .ok
  }

  /// One DDC/CI Capabilities Request (op 0xF3) at `offset`.
  ///
  /// This cannot go through `performDDCCommunication`. That function encodes the
  /// message as `[0x80 | (send.count + 1)][send.count][send…]`, which works only
  /// because Get VCP is op 0x01 with one parameter and Set VCP is op 0x03 with
  /// three — the op code IS the parameter count, by coincidence. 0xF3 with two
  /// offset bytes breaks the coincidence, so the packet is built here.
  ///
  /// Returns the fragment's payload, `[]` for the terminator, or `nil` when the
  /// transaction failed (no reply, bad checksum, wrong op code, wrong offset).
  public static func readCapabilityFragment(
    service: IOAVService?,
    offset: UInt16,
    writeSleepTime: UInt32? = nil,
    readSleepTime: UInt32? = nil,
    numOfRetryAttempts: UInt8 = 2,
    retrySleepTime: UInt32? = nil
  ) -> [UInt8]? {
    guard service != nil else { return nil }
    let dataAddress = ARM64_DDC_DATA_ADDRESS
    // [0x80 | messageLength][op][offsetHi][offsetLo][checksum]
    var packet: [UInt8] = [0x80 | 3, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF), 0]
    // Seeded like the READ path (0x6E alone, not 0x6E ^ 0x51): a capabilities
    // request is a request-with-reply exactly like Get VCP, and the fork's two
    // seeds are empirical, not derived. If a panel NAKs every fragment while
    // answering Get VCP fine, try the write seed (0x6E ^ dataAddress) before
    // concluding the panel is silent.
    packet[packet.count - 1] = self.checksum(
      chk: ARM64_DDC_7BIT_ADDRESS << 1, data: &packet, start: 0, end: packet.count - 2
    )
    // Max frame: source + length byte + (op + 2 offset + 32 payload) + checksum.
    var reply = [UInt8](repeating: 0, count: 38)
    for _ in 0 ... numOfRetryAttempts {
      usleep(writeSleepTime ?? 10000)
      guard IOAVServiceWriteI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), UInt32(dataAddress),
                                &packet, UInt32(packet.count)) == 0
      else {
        usleep(retrySleepTime ?? 20000)
        continue
      }
      usleep(readSleepTime ?? 50000)
      if IOAVServiceReadI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), 0,
                            &reply, UInt32(reply.count)) == 0,
        let fragment = CapabilityString.fragment(fromFrame: reply, expectedOffset: offset) {
        return fragment
      }
      usleep(retrySleepTime ?? 20000)
    }
    return nil
  }

  /// What one DDC transaction proved. `write` collapses it back to a Bool;
  /// `readOutcome` keeps the distinction the sentinel below buys.
  enum TransactionOutcome: Equatable {
    /// The write was acknowledged and, where a reply was expected, a
    /// checksum-clean frame came back.
    case ok
    /// The panel wrote zeros over the sentinel: it is on the bus and saying
    /// nothing. The write-only signature.
    case answeredZeros
    /// Nothing usable: a refused write, a failed read call, a buffer the read
    /// left untouched, or a frame that failed its checksum.
    case silent
  }

  /// The reply buffer's fill before every read call. `IOAVServiceReadI2C` can
  /// return success without writing the buffer, so a zero fill made "answered
  /// zeros" and "wrote nothing" the same bytes. 0xFF is also what an idle I2C
  /// line reads as, so a floating read counts as untouched.
  static let replySentinel: UInt8 = 0xFF

  /// Verdict for a reply buffer whose read call reported success. Validated here,
  /// inside the ladder, so a frame answering a DIFFERENT code gets the same retry
  /// as any failed read.
  static func replyVerdict(_ reply: [UInt8], command: UInt8? = nil) -> TransactionOutcome {
    guard reply.count >= 2 else { return .silent }
    var frame = reply
    guard self.checksum(chk: 0x50, data: &frame, start: 0, end: frame.count - 2) == frame[frame.count - 1] else {
      return reply.allSatisfy { $0 == 0 } ? .answeredZeros : .silent
    }
    // The checksum alone is a 1-in-256 guard. Without the op-code and
    // result-code check the Intel transport has always made, a display
    // answering with stale bytes, or answering a DIFFERENT VCP code than the
    // one asked for, produces a plausible `max` that silently compresses the
    // whole range.
    if let command, DDCReplyFrame.rejection(for: reply, command: command) != nil {
      return .silent
    }
    return .ok
  }

  /// One attempt's verdict folded into the transaction's: `answeredZeros` outlives
  /// a later silence, the ordering `DDCReadEvidence.worse` uses. The ladder returns
  /// on `.ok` rather than folding it; the `.ok` arms only keep this total.
  static func fold(_ transaction: TransactionOutcome, _ attempt: TransactionOutcome) -> TransactionOutcome {
    switch (transaction, attempt) {
    case (.ok, _), (_, .ok): .ok
    case (.answeredZeros, _), (_, .answeredZeros): .answeredZeros
    default: .silent
    }
  }

  /// The two I2C calls and the sleep between them, injected so a test can drive
  /// the retry ladder and see the ORDER of sleeps against packets. `live` is the
  /// private API; nothing but a test passes anything else.
  struct I2CTransport: Sendable {
    var write: @Sendable (IOAVService?, UnsafeMutableRawPointer, UInt32) -> Int32
    var read: @Sendable (IOAVService?, UnsafeMutableRawPointer, UInt32) -> Int32
    /// A recorded call, because where a sleep falls relative to a packet is the
    /// write path's whole latency.
    var sleep: @Sendable (UInt32) -> Void = { usleep($0) }

    static let live = I2CTransport(
      write: { service, bytes, count in
        IOAVServiceWriteI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), UInt32(ARM64_DDC_DATA_ADDRESS), bytes, count)
      },
      read: { service, bytes, count in
        IOAVServiceReadI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), 0, bytes, count)
      }
    )
  }

  static func performDDCCommunication(service: IOAVService?, send: inout [UInt8], reply: inout [UInt8], replyCommand: UInt8? = nil, pacer: DDCBusPacer? = nil, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, readSleepTime: UInt32? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> TransactionOutcome {
    guard service != nil else {
      return .silent
    }
    return self.runTransaction(service: service, send: &send, reply: &reply, replyCommand: replyCommand, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, readSleepTime: readSleepTime, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime, pacer: pacer, transport: .live)
  }

  /// The retry ladder. Split from the entry point so a nil service is refused
  /// before any sleep, and so a test can hand it a panel.
  static func runTransaction(service: IOAVService?, send: inout [UInt8], reply: inout [UInt8], replyCommand: UInt8?, writeSleepTime: UInt32?, numOfWriteCycles: UInt8?, readSleepTime: UInt32?, numOfRetryAttemps: UInt8?, retrySleepTime: UInt32?, pacer: DDCBusPacer?, transport: I2CTransport) -> TransactionOutcome {
    let dataAddress = ARM64_DDC_DATA_ADDRESS
    var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0] // Note: the last byte is the place of the checksum, see next line!
    packet[packet.count - 1] = self.checksum(chk: send.count == 1 ? ARM64_DDC_7BIT_ADDRESS << 1 : ARM64_DDC_7BIT_ADDRESS << 1 ^ dataAddress, data: &packet, start: 0, end: packet.count - 2)
    var outcome = TransactionOutcome.silent
    let pacing = writeSleepTime ?? 10000
    // Only the FIRST packet is paced from the bus; a second write cycle or a
    // retry keeps the full sleep it always had. With no pacer the floor is paid
    // in full.
    var firstPacket = true
    for _ in 1 ... (numOfRetryAttemps ?? 4) + 1 {
      // ONE packet per logical write. The inherited default of 2 put two
      // identical packets on the bus for every write and cost 20 ms of sleep
      // before the caller could proceed. Duplicate writes saturate I2C and delay
      // the apply; measured, halving the traffic halved the on-wire time, and
      // the Dell's readback confirms the value ACHIEVED at 1 cycle. Retries
      // above are the reliability mechanism, not a blind second copy.
      var wrote = false
      for _ in 1 ... max(numOfWriteCycles ?? 1, 1) {
        let owed = firstPacket ? (pacer?.deficit(floor: pacing) ?? pacing) : pacing
        firstPacket = false
        if owed > 0 { transport.sleep(owed) }
        wrote = transport.write(service, &packet, UInt32(packet.count)) == 0
        pacer?.recordBusUse()
      }
      if reply.isEmpty {
        if wrote { return .ok }
      } else {
        // Not carried from `wrote`: a landed write with a failed reply read is a
        // failed READ and retries like one. The read still runs after a NAKed
        // write, as it always did: a clean frame behind it is still an answer.
        for index in reply.indices { reply[index] = Self.replySentinel }
        transport.sleep(readSleepTime ?? 50000)
        let answered = transport.read(service, &reply, UInt32(reply.count))
        // Recorded whatever it returned: the bus was busy either way.
        pacer?.recordBusUse()
        if answered == 0 {
          let verdict = Self.replyVerdict(reply, command: replyCommand)
          if verdict == .ok { return .ok }
          outcome = Self.fold(outcome, verdict)
        }
      }
      transport.sleep(retrySleepTime ?? 20000)
    }
    return outcome
  }

  /// DDC checksum calculator
  static func checksum(chk: UInt8, data: inout [UInt8], start: Int, end: Int) -> UInt8 {
    var chkd: UInt8 = chk
    for i in start ... end {
      chkd ^= data[i]
    }
    return chkd
  }

  static func ioregMatchScore(displayID: CGDirectDisplayID, ioregEdidUUID: String, ioDisplayLocation: String = "", ioregProductName: String = "", ioregSerialNumber: Int64 = 0) -> Int {
    var matchScore = 0
    if let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?.takeRetainedValue() as NSDictionary? {
      if let kDisplayYearOfManufacture = dictionary[kDisplayYearOfManufacture] as? Int64, let kDisplayWeekOfManufacture = dictionary[kDisplayWeekOfManufacture] as? Int64, let kDisplayVendorID = dictionary[kDisplayVendorID] as? Int64, let kDisplayProductID = dictionary[kDisplayProductID] as? Int64, let kDisplayVerticalImageSize = dictionary[kDisplayVerticalImageSize] as? Int64, let kDisplayHorizontalImageSize = dictionary[kDisplayHorizontalImageSize] as? Int64 {
        struct KeyLoc {
          var key: String
          var loc: Int
        }
        let edidUUIDSearchKeys: [KeyLoc] = [
          // Vendor ID
          KeyLoc(key: String(format: "%04x", UInt16(max(0, min(kDisplayVendorID, 256 * 256 - 1)))).uppercased(), loc: 0),
          // Product ID
          KeyLoc(key: String(format: "%02x", UInt8((UInt16(max(0, min(kDisplayProductID, 256 * 256 - 1))) >> (0 * 8)) & 0xFF)).uppercased()
            + String(format: "%02x", UInt8((UInt16(max(0, min(kDisplayProductID, 256 * 256 - 1))) >> (1 * 8)) & 0xFF)).uppercased(), loc: 4),
          // Manufacture date
          KeyLoc(key: String(format: "%02x", UInt8(max(0, min(kDisplayWeekOfManufacture, 256 - 1)))).uppercased()
            + String(format: "%02x", UInt8(max(0, min(kDisplayYearOfManufacture - 1990, 256 - 1)))).uppercased(), loc: 19),
          // Image size
          KeyLoc(key: String(format: "%02x", UInt8(max(0, min(kDisplayHorizontalImageSize / 10, 256 - 1)))).uppercased()
            + String(format: "%02x", UInt8(max(0, min(kDisplayVerticalImageSize / 10, 256 - 1)))).uppercased(), loc: 30),
        ]
        for searchKey in edidUUIDSearchKeys where searchKey.key != "0000" && searchKey.key == ioregEdidUUID.prefix(searchKey.loc + 4).suffix(4) {
          matchScore += 1
        }
      }
      if ioDisplayLocation != "", let kIODisplayLocation = dictionary[kIODisplayLocationKey] as? String, ioDisplayLocation == kIODisplayLocation {
        matchScore += 10
      }
      if ioregProductName != "", let nameList = dictionary["DisplayProductName"] as? [String: String], let name = nameList["en_US"] ?? nameList.first?.value, name.lowercased() == ioregProductName.lowercased() {
        matchScore += 1
      }
      if ioregSerialNumber != 0, let serial = dictionary[kDisplaySerialNumber] as? Int64, serial == ioregSerialNumber {
        matchScore += 1
      }
    }
    return matchScore
  }

  /// Physical panel size in CENTIMETRES, from
  /// `CoreDisplay_DisplayCreateInfoDictionary`'s image-size fields (which are
  /// in millimetres).
  ///
  /// `ioregMatchScore` reads the same two fields on every discovery pass and
  /// then drops them, but widening a hot scoring loop's return to carry a
  /// by-product for a read-only pane is not worth it. This costs one extra
  /// `CoreDisplay_DisplayCreateInfoDictionary` per matched display per pass, and
  /// it is a dictionary read: no I2C, so no DDC transaction, timing, retry or
  /// written value is touched.
  ///
  /// Guards `> 0` deliberately: a panel that declares 0 mm has declared nothing,
  /// and "0 x 0 cm" would be a fabricated number rather than an admission.
  static func physicalSizeCm(displayID: CGDirectDisplayID) -> (width: Int, height: Int)? {
    guard let dictionary = CoreDisplay_DisplayCreateInfoDictionary(displayID)?
      .takeRetainedValue() as NSDictionary?,
      let horizontal = dictionary[kDisplayHorizontalImageSize] as? Int64,
      let vertical = dictionary[kDisplayVerticalImageSize] as? Int64,
      horizontal > 0, vertical > 0
    else { return nil }
    return (Int(horizontal / 10), Int(vertical / 10))
  }

  /// The `DisplayAttributes` record (EDID as macOS parsed it at connection) of
  /// the framebuffer entry that scores highest for this display.
  ///
  /// Not gated on a following `DCPAVServiceProxy` node the way the DDC pool
  /// walk is: identity does not depend on DDC health, and that gate drops every
  /// panel with no I2C route, the built-in included. No cross-display
  /// exclusivity either; ties go to the first entry in walk order.
  /// Nil when nothing scores above zero: the display exposed no parsed EDID record.
  static func displayAttributes(displayID: CGDirectDisplayID) -> [String: Any]? {
    let ioregRoot: io_registry_entry_t = IORegistryGetRootEntry(kIOMainPortDefault)
    defer { IOObjectRelease(ioregRoot) }
    var iterator = io_iterator_t()
    guard IORegistryEntryCreateIterator(ioregRoot, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
      return nil
    }
    defer { IOObjectRelease(iterator) }
    var candidates: [(score: Int, entry: io_service_t)] = []
    defer { for candidate in candidates { IOObjectRelease(candidate.entry) } }
    while let objectOfInterest = self.ioregIterateToNextObjectOfInterest(interests: ["AppleCLCD2", "IOMobileFramebufferShim"], iterator: &iterator) {
      let details = self.getIORegServiceAppleCDC2Properties(entry: objectOfInterest.entry)
      let score = self.ioregMatchScore(displayID: displayID, ioregEdidUUID: details.edidUUID, ioDisplayLocation: details.ioDisplayLocation, ioregProductName: details.productName, ioregSerialNumber: details.serialNumber)
      candidates.append((score, objectOfInterest.entry))
    }
    return self.bestMatchingRecord(among: candidates.map { candidate in
      (candidate.score, { Self.displayAttributesRecord(entry: candidate.entry) })
    })
  }

  /// Highest score above zero wins, ties to the first in walk order; nil when the
  /// winner has no readable record. An unreadable record must not disqualify the
  /// winner: with two panels of the same vendor the loser's record parses fine
  /// and would report the twin's serial as this display's. One lazy read, winner only.
  static func bestMatchingRecord(among candidates: [(score: Int, record: () -> [String: Any]?)]) -> [String: Any]? {
    var winner: (index: Int, score: Int)?
    for (index, candidate) in candidates.enumerated() where candidate.score > (winner?.score ?? 0) {
      winner = (index, candidate.score)
    }
    return winner.flatMap { candidates[$0.index].record() }
  }

  static func displayAttributesRecord(entry: io_service_t) -> [String: Any]? {
    guard let unmanagedAttributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) else {
      return nil
    }
    return unmanagedAttributes.takeRetainedValue() as? [String: Any]
  }

  /// Next entry whose name contains one of `interests`. Returned RETAINED: the
  /// caller must release it. Skipped entries (thousands per pass) are released here.
  static func ioregIterateToNextObjectOfInterest(interests: [String], iterator: inout io_iterator_t) -> (name: String, entry: io_service_t)? {
    let name = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer {
      name.deallocate()
    }
    while true {
      let entry = IOIteratorNext(iterator)
      guard entry != IO_OBJECT_NULL else {
        break
      }
      guard IORegistryEntryGetName(entry, name) == KERN_SUCCESS else {
        IOObjectRelease(entry)
        break
      }
      let nameString = String(cString: name)
      for interest in interests where nameString.contains(interest) {
        return (nameString, entry)
      }
      IOObjectRelease(entry)
    }
    return nil
  }

  static func getIORegServiceAppleCDC2Properties(entry: io_service_t) -> IOregService {
    var ioregService = IOregService()
    if let unmanagedEdidUUID = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let edidUUID = unmanagedEdidUUID.takeRetainedValue() as? String {
      ioregService.edidUUID = edidUUID
    }
    let cpath = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
    IORegistryEntryGetPath(entry, kIOServicePlane, cpath)
    ioregService.ioDisplayLocation = String(cString: cpath)
    if let unmanagedDisplayAttrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let displayAttrs = unmanagedDisplayAttrs.takeRetainedValue() as? NSDictionary {
      if let productAttrs = displayAttrs.value(forKey: "ProductAttributes") as? NSDictionary {
        if let manufacturerID = productAttrs.value(forKey: "ManufacturerID") as? String {
          ioregService.manufacturerID = manufacturerID
        }
        if let productName = productAttrs.value(forKey: "ProductName") as? String {
          ioregService.productName = productName
        }
        if let serialNumber = productAttrs.value(forKey: "SerialNumber") as? Int64 {
          ioregService.serialNumber = serialNumber
        }
        if let alphanumericSerialNumber = productAttrs.value(forKey: "AlphanumericSerialNumber") as? String {
          ioregService.alphanumericSerialNumber = alphanumericSerialNumber
        }
      }
    }
    if let unmanagedTransport = IORegistryEntryCreateCFProperty(entry, "Transport" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let transport = unmanagedTransport.takeRetainedValue() as? NSDictionary {
      if let upstream = transport.value(forKey: "Upstream") as? String {
        ioregService.transportUpstream = upstream
      }
      if let downstream = transport.value(forKey: "Downstream") as? String {
        ioregService.transportDownstream = downstream
      }
    }
    return ioregService
  }

  static func setIORegServiceDCPAVServiceProxy(entry: io_service_t, ioregService: inout IOregService) {
    if let unmanagedLocation = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)), let location = unmanagedLocation.takeRetainedValue() as? String {
      if location == "External" {
        ioregService.service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() as IOAVService
      }
    }
  }

  static func getIoregServicesForMatching() -> [IOregService] {
    var serviceLocation = 0
    var ioregServicesForMatching: [IOregService] = []
    let ioregRoot: io_registry_entry_t = IORegistryGetRootEntry(kIOMainPortDefault)
    defer {
      IOObjectRelease(ioregRoot)
    }
    var iterator = io_iterator_t()
    defer {
      IOObjectRelease(iterator)
    }
    var ioregService = IOregService()
    guard IORegistryEntryCreateIterator(ioregRoot, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
      return ioregServicesForMatching
    }
    let keyDCPAVServiceProxy = "DCPAVServiceProxy"
    let keysFramebuffer = ["AppleCLCD2", "IOMobileFramebufferShim"]
    while true {
      guard let objectOfInterest = ioregIterateToNextObjectOfInterest(interests: [keyDCPAVServiceProxy] + keysFramebuffer, iterator: &iterator) else {
        break
      }
      // Owned reference from the helper. Safe to release after either branch:
      // the properties read copies, and the IOAVService has its own lifetime.
      defer { IOObjectRelease(objectOfInterest.entry) }
      if keysFramebuffer.contains(objectOfInterest.name) {
        ioregService = self.getIORegServiceAppleCDC2Properties(entry: objectOfInterest.entry)
        serviceLocation += 1
        ioregService.serviceLocation = serviceLocation
      } else if objectOfInterest.name == keyDCPAVServiceProxy {
        self.setIORegServiceDCPAVServiceProxy(entry: objectOfInterest.entry, ioregService: &ioregService)
        ioregServicesForMatching.append(ioregService)
      }
    }
    return ioregServicesForMatching
  }

  static func checkIfDummy(ioregService: IOregService) -> Bool {
    if ioregService.manufacturerID == "AOC", ioregService.productName == "28E850" {
      return true
    }
    return false
  }
}
