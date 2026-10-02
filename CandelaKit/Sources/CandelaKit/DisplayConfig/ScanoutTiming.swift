import CoreGraphics
import Foundation
import IOKit

/// Active pixels driven by the display controller, independent of the desktop framebuffer.
public struct ScanoutTiming: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public let refreshHz: Double

  public init(width: Int, height: Int, refreshHz: Double) {
    self.width = width
    self.height = height
    self.refreshHz = refreshHz
  }

  public var diagnosticDescription: String {
    "\(width) x \(height) at \(String(format: "%.3f", refreshHz)) Hz"
  }
}

/// Apple Silicon's controller timing. An absent or ambiguous record is not verification.
public enum ScanoutTimingReader {
  public static func read(displayID: CGDirectDisplayID) -> ScanoutTiming? {
    guard let location = displayLocation(displayID) else { return nil }
    return read(displayID: displayID, expectedLocation: location)
  }

  static func displayLocation(_ displayID: CGDirectDisplayID) -> String? {
    guard let location = Arm64DDC.displayInfoDictionary(displayID: displayID)?[kIODisplayLocationKey] as? String,
          !location.isEmpty else { return nil }
    return location
  }

  /// The exact port path is mandatory. Vendor, model and EDID UUID alone cannot
  /// distinguish identical neighbors. Resolve the path again after applying so
  /// a display ID reassigned during reconfiguration cannot borrow another pipe.
  static func read(displayID: CGDirectDisplayID, expectedLocation: String) -> ScanoutTiming? {
    guard displayLocation(displayID) == expectedLocation else { return nil }
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    defer { IOObjectRelease(root) }
    var iterator = io_iterator_t()
    guard IORegistryEntryCreateIterator(root, kIOServicePlane,
      IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var candidates: [(location: String, read: () -> [String: Any]?)] = []
    var entries: [io_registry_entry_t] = []
    defer { entries.forEach { IOObjectRelease($0) } }
    while let object = Arm64DDC.ioregIterateToNextObjectOfInterest(
      interests: ["AppleCLCD2"], iterator: &iterator) {
      let entry = object.entry
      entries.append(entry)
      var path = [CChar](repeating: 0, count: 4096)
      guard IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS else { continue }
      let location = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      candidates.append((location, {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let record = properties?.takeRetainedValue() as? [String: Any],
              let after = IORegistryEntryCreateCFProperty(entry, "DPTimingModeId" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue(),
              integer(after) == integer(record["DPTimingModeId"])
        else { return nil }
        return record
      }))
    }
    guard let record = matchingRecord(displayLocation: expectedLocation, candidates: candidates),
          displayLocation(displayID) == expectedLocation else { return nil }
    return parse(record)
  }

  static func matchingRecord(
    displayLocation: String?, candidates: [(location: String, read: () -> [String: Any]?)]
  ) -> [String: Any]? {
    guard let displayLocation, !displayLocation.isEmpty else { return nil }
    let matches = candidates.filter { $0.location == displayLocation }
    guard matches.count == 1 else { return nil }
    return matches[0].read()
  }

  /// DPTimingModeId names an ID in this node's array, never an array index.
  /// PreciseSyncRate is unsigned 16.16 fixed point. Reject malformed values
  /// instead of inventing a clean result from zeroes or truncated fractions.
  static func parse(_ record: [String: Any]) -> ScanoutTiming? {
    guard let id = integer(record["DPTimingModeId"]), id >= 0,
          let elements = record["TimingElements"] as? [[String: Any]] else { return nil }
    let matches = elements.filter { integer($0["ID"]) == id }
    guard matches.count == 1,
          let horizontal = matches[0]["HorizontalAttributes"] as? [String: Any],
          let vertical = matches[0]["VerticalAttributes"] as? [String: Any],
          let width = integer(horizontal["Active"]), (1...65535).contains(width),
          let height = integer(vertical["Active"]), (1...65535).contains(height),
          let fixedRate = integer(vertical["PreciseSyncRate"]), fixedRate > 0,
          fixedRate <= 1000 * 65536 else { return nil }
    return ScanoutTiming(width: width, height: height, refreshHz: Double(fixedRate) / 65536)
  }

  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite,
          number.doubleValue.rounded() == number.doubleValue,
          number.doubleValue >= 0, number.doubleValue < Double(Int.max) else { return nil }
    return number.intValue
  }
}

/// The expected wire geometry is not always the framebuffer or the native size.
/// Revealed HiDPI and synthesized modes require the panel's native timing;
/// ordinary lower-resolution modes may legitimately drive a smaller timing.
public enum ScanoutVerification {
  public enum Verdict: Equatable { case verified, mismatch, notVerifiable }

  public static func verdict(
    requested: DisplayMode, nativePixels: (width: Int, height: Int)?, timing: ScanoutTiming?
  ) -> Verdict {
    guard let timing else { return .notVerifiable }
    if requested.refreshHz > 0,
       !ModePersistence.refreshMatches(requested.refreshHz, timing.refreshHz) { return .mismatch }
    guard let nativePixels, nativePixels.width > 0, nativePixels.height > 0 else { return .notVerifiable }
    // Registry timings are in panel orientation; CoreGraphics can be rotated.
    let nativeMatches = sameSize(timing, width: nativePixels.width, height: nativePixels.height)
    if nativeMatches { return .verified }
    if requested.isNative || requested.isSynthesized || (requested.isRevealed && requested.isHiDPI) {
      return .mismatch
    }
    return sameSize(timing, width: requested.pixelWidth, height: requested.pixelHeight)
      ? .verified : .notVerifiable
  }

  private static func sameSize(_ timing: ScanoutTiming, width: Int, height: Int) -> Bool {
    (timing.width == width && timing.height == height)
      || (timing.width == height && timing.height == width)
  }
}

/// Session-only quarantine, scoped to a display's hardware identity and controller path.
/// Geometry survives mode-ID reassignment; no entry is persisted across launches.
final class RejectedScanoutModes: @unchecked Sendable {
  private let lock = NSLock()
  private var modes: [String: Set<DisplayModeDescriptor>] = [:]

  func record(_ mode: DisplayMode, displayKey: String) {
    lock.withLock { _ = modes[displayKey, default: []].insert(mode.descriptor) }
  }

  func contains(_ mode: DisplayMode, displayKey: String) -> Bool {
    lock.withLock { modes[displayKey]?.contains(mode.descriptor) == true }
  }
}
