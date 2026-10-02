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

  /// The display's own registry location, as the reader matches on it.
  /// Public for the probe's `scanout` subcommand.
  public static func location(of displayID: CGDirectDisplayID) -> String? {
    displayLocation(displayID)
  }

  /// Every display-controller service path, for the probe: a location that
  /// equals none of these is a reader that can never return a timing.
  public static func controllerPaths() -> [String] {
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    defer { IOObjectRelease(root) }
    var iterator = io_iterator_t()
    guard IORegistryEntryCreateIterator(root, kIOServicePlane,
      IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var paths: [String] = []
    while let object = Arm64DDC.ioregIterateToNextObjectOfInterest(
      interests: ["AppleCLCD2"], iterator: &iterator) {
      defer { IOObjectRelease(object.entry) }
      var path = [CChar](repeating: 0, count: 4096)
      guard IORegistryEntryGetPath(object.entry, kIOServicePlane, &path) == KERN_SUCCESS else { continue }
      paths.append(String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
    return paths
  }

  static func displayLocation(_ displayID: CGDirectDisplayID) -> String? {
    guard let location = Arm64DDC.displayInfoDictionary(displayID: displayID)?[kIODisplayLocationKey] as? String,
          !location.isEmpty else { return nil }
    return location
  }

  /// The probe's `modeapply` control: the reading with the raw
  /// `DPTimingModeId` it was resolved from, so a known pair of modes can be
  /// shown moving the record (the Dell's 76 to 78) in one command.
  public static func diagnosticRead(
    displayID: CGDirectDisplayID
  ) -> (timing: ScanoutTiming?, timingModeID: Int?) {
    guard let location = displayLocation(displayID),
          let record = record(displayID: displayID, expectedLocation: location)
    else { return (nil, nil) }
    return (parse(record), integer(record["DPTimingModeId"]))
  }

  /// The exact port path is mandatory. Vendor, model and EDID UUID alone cannot
  /// distinguish identical neighbors. Resolve the path again after applying so
  /// a display ID reassigned during reconfiguration cannot borrow another pipe.
  static func read(displayID: CGDirectDisplayID, expectedLocation: String) -> ScanoutTiming? {
    record(displayID: displayID, expectedLocation: expectedLocation).flatMap(parse)
  }

  private static func record(
    displayID: CGDirectDisplayID, expectedLocation: String
  ) -> [String: Any]? {
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
    return record
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
/// Revealed HiDPI and synthesized modes require the panel's native timing (or,
/// for a revealed mode, at least its own framebuffer); ordinary lower-resolution
/// modes may legitimately drive a smaller timing.
public enum ScanoutVerification {
  /// `mismatch` is the only verdict that restores and withholds, and only the
  /// modes `isEnforced` names can earn it. `unexpected` is a reading that
  /// disagrees with a mode macOS publishes for itself: kept for diagnostics,
  /// never acted on, because nothing has measured those modes scanning out wrong.
  public enum Verdict: Equatable { case verified, mismatch, unexpected, notVerifiable }

  /// The modes whose wire timing the platform has been measured getting wrong.
  public static func isEnforced(_ mode: DisplayMode) -> Bool {
    mode.isSynthesized || (mode.isRevealed && mode.isHiDPI)
  }

  /// The post-apply verdict, given the reading taken before the apply.
  ///
  /// The controller can keep reporting the outgoing timing after CoreGraphics
  /// reports the new mode, steadily enough to pass a double read. So a reading
  /// equal to the pre-apply one proves nothing unless the request expects that
  /// timing, and with no pre-apply reading only a verified one counts.
  ///
  /// Blind spot: a wrong timing equal to the outgoing one (the measured crop, a
  /// revealed 3440x1440 at 2x and 120 Hz applied from a published 2560x1440 at
  /// 120 Hz) reads as not verifiable. The configurator logs it at error level.
  public static func verdict(
    requested: DisplayMode, nativePixels: (width: Int, height: Int)?,
    before: ScanoutTiming?, after: ScanoutTiming?
  ) -> Verdict {
    guard let after else { return .notVerifiable }
    let reading = verdict(requested: requested, nativePixels: nativePixels, timing: after)
    guard reading != .verified else { return .verified }
    guard let before, before != after else { return .notVerifiable }
    return reading
  }

  public static func verdict(
    requested: DisplayMode, nativePixels: (width: Int, height: Int)?, timing: ScanoutTiming?
  ) -> Verdict {
    guard let timing else { return .notVerifiable }
    let wrongly: Verdict = isEnforced(requested) ? .mismatch : .unexpected
    if requested.refreshHz > 0,
       !ModePersistence.refreshMatches(requested.refreshHz, timing.refreshHz) { return wrongly }
    guard let nativePixels, nativePixels.width > 0, nativePixels.height > 0 else { return .notVerifiable }
    // Registry timings are in panel orientation; CoreGraphics can be rotated.
    if sameSize(timing, width: nativePixels.width, height: nativePixels.height) { return .verified }
    if requested.isSynthesized { return .mismatch }
    if requested.isRevealed && requested.isHiDPI {
      // Cropping is a timing smaller than the framebuffer it has to carry.
      if !covers(timing, width: requested.pixelWidth, height: requested.pixelHeight) {
        return .mismatch
      }
      return sameSize(timing, width: requested.pixelWidth, height: requested.pixelHeight)
        ? .verified : .notVerifiable
    }
    if sameSize(timing, width: requested.pixelWidth, height: requested.pixelHeight) { return .verified }
    return requested.isNative ? .unexpected : .notVerifiable
  }

  /// A synthesized size's mirror slave, re-timed onto `retimedOnto`. That mode
  /// need not be native (2560x1440 on a 3440x1440 panel), so once the re-time
  /// has landed its framebuffer and refresh are a correct wire too. Unlanded,
  /// the slave sits on the mirror's mode and rate, and a target-sized wire
  /// there is the measured crop.
  public static func retimeVerdict(
    retimedOnto target: DisplayMode?, landed: Bool,
    nativePixels: (width: Int, height: Int)?, timing: ScanoutTiming?
  ) -> Verdict {
    guard let timing else { return .notVerifiable }
    if landed, let target, target.refreshHz > 0,
       !ModePersistence.refreshMatches(target.refreshHz, timing.refreshHz) { return .mismatch }
    if let nativePixels, sameSize(timing, width: nativePixels.width, height: nativePixels.height) {
      return .verified
    }
    let landedTarget = landed ? target : nil
    if let landedTarget, sameSize(timing, width: landedTarget.pixelWidth, height: landedTarget.pixelHeight) {
      return .verified
    }
    return nativePixels == nil && landedTarget == nil ? .notVerifiable : .mismatch
  }

  private static func sameSize(_ timing: ScanoutTiming, width: Int, height: Int) -> Bool {
    (timing.width == width && timing.height == height)
      || (timing.width == height && timing.height == width)
  }

  private static func covers(_ timing: ScanoutTiming, width: Int, height: Int) -> Bool {
    (timing.width >= width && timing.height >= height)
      || (timing.width >= height && timing.height >= width)
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
