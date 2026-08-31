//  Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
//  Transplanted from the MonitorControl project (MIT).

import Foundation
import IOKit
import CandelaPrivateAPIs

let ARM64_DDC_7BIT_ADDRESS: UInt8 = 0x37 // This works with DisplayPort devices
let ARM64_DDC_DATA_ADDRESS: UInt8 = 0x51

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

  public static func read(service: IOAVService?, command: UInt8, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, readSleepTime: UInt32? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> (current: UInt16, max: UInt16)? {
    var values: (UInt16, UInt16)?
    var send: [UInt8] = [command]
    var reply = [UInt8](repeating: 0, count: 11)
    if Self.performDDCCommunication(service: service, send: &send, reply: &reply, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, readSleepTime: readSleepTime, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime) {
      // The checksum alone is a 1-in-256 guard. Without the op-code and
      // result-code check the Intel transport has always made, a display
      // answering with stale bytes, or answering a DIFFERENT VCP code than the
      // one asked for, produces a plausible `max` that silently compresses the
      // whole range.
      if DDCReplyFrame.rejection(for: reply, command: command) != nil {
        return nil
      }
      let max = DDCReplyFrame.value(high: reply[6], low: reply[7])
      let current = DDCReplyFrame.value(high: reply[8], low: reply[9])
      values = (current, max)
    } else {
      values = nil
    }
    return values
  }

  public static func write(service: IOAVService?, command: UInt8, value: UInt16, writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> Bool {
    var send: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 255)]
    var reply: [UInt8] = []
    return Self.performDDCCommunication(service: service, send: &send, reply: &reply, writeSleepTime: writeSleepTime, numOfWriteCycles: numOfWriteCycles, numOfRetryAttemps: numOfRetryAttemps, retrySleepTime: retrySleepTime)
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

  static func performDDCCommunication(service: IOAVService?, send: inout [UInt8], reply: inout [UInt8], writeSleepTime: UInt32? = nil, numOfWriteCycles: UInt8? = nil, readSleepTime: UInt32? = nil, numOfRetryAttemps: UInt8? = nil, retrySleepTime: UInt32? = nil) -> Bool {
    let dataAddress = ARM64_DDC_DATA_ADDRESS
    var success = false
    guard service != nil else {
      return success
    }
    var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0] // Note: the last byte is the place of the checksum, see next line!
    packet[packet.count - 1] = self.checksum(chk: send.count == 1 ? ARM64_DDC_7BIT_ADDRESS << 1 : ARM64_DDC_7BIT_ADDRESS << 1 ^ dataAddress, data: &packet, start: 0, end: packet.count - 2)
    for _ in 1 ... (numOfRetryAttemps ?? 4) + 1 {
      // ONE packet per logical write. The inherited default of 2 put two
      // identical packets on the bus for every write and cost 20 ms of sleep
      // before the caller could proceed. Duplicate writes saturate I2C and delay
      // the apply; measured, halving the traffic halved the on-wire time, and
      // the Dell's readback confirms the value ACHIEVED at 1 cycle. Retries
      // above are the reliability mechanism, not a blind second copy.
      for _ in 1 ... max(numOfWriteCycles ?? 1, 1) {
        usleep(writeSleepTime ?? 10000)
        success = IOAVServiceWriteI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), UInt32(dataAddress), &packet, UInt32(packet.count)) == 0
      }
      if !reply.isEmpty {
        usleep(readSleepTime ?? 50000)
        if IOAVServiceReadI2C(service, UInt32(ARM64_DDC_7BIT_ADDRESS), 0, &reply, UInt32(reply.count)) == 0 {
          success = self.checksum(chk: 0x50, data: &reply, start: 0, end: reply.count - 2) == reply[reply.count - 1]
        }
      }
      if success {
        return success
      }
      usleep(retrySleepTime ?? 20000)
    }
    return success
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

  static func ioregIterateToNextObjectOfInterest(interests: [String], iterator: inout io_iterator_t) -> (name: String, entry: io_service_t, preceedingEntry: io_service_t)? {
    var entry: io_service_t = IO_OBJECT_NULL
    var preceedingEntry: io_service_t = IO_OBJECT_NULL
    let name = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
    defer {
      name.deallocate()
    }
    while true {
      preceedingEntry = entry
      entry = IOIteratorNext(iterator)
      guard IORegistryEntryGetName(entry, name) == KERN_SUCCESS, entry != MACH_PORT_NULL else {
        break
      }
      let nameString = String(cString: name)
      for interest in interests where entry != IO_OBJECT_NULL && nameString.contains(interest) {
        return (nameString, entry, preceedingEntry)
      }
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
