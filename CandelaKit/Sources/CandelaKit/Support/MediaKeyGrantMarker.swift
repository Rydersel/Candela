import Foundation
import IOKit

/// Evidence that Accessibility was granted on this Mac. Application Support can
/// migrate with the user account, so the record must match the current machine.
public struct MediaKeyGrantMarker: Sendable {
  public let directory: URL
  private let machineIdentifier: String?

  private struct Record: Codable {
    let machineIdentifier: String
    let observedAt: Date
  }

  public init(directory: URL = MediaKeyGrantMarker.defaultDirectory()) {
    self.init(directory: directory, machineIdentifier: Self.currentMachineIdentifier())
  }

  init(directory: URL, machineIdentifier: String?) {
    self.directory = directory
    self.machineIdentifier = machineIdentifier.flatMap { $0.isEmpty ? nil : $0 }
  }

  public static func defaultDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Candela", isDirectory: true)
  }

  var fileURL: URL { directory.appendingPathComponent("media-key-grant-observed") }

  public var exists: Bool {
    guard let machineIdentifier,
      let data = try? Data(contentsOf: fileURL),
      let record = try? JSONDecoder().decode(Record.self, from: data)
    else { return false }
    return record.machineIdentifier == machineIdentifier
  }

  /// Called only after observing the actual grant. A migrated or legacy record
  /// becomes evidence for this machine then, never merely because it was read.
  /// An unavailable identity or unwritable file leaves the launch prompt quiet.
  public func record() {
    guard let machineIdentifier, !exists else { return }
    let record = Record(machineIdentifier: machineIdentifier, observedAt: Date())
    guard let data = try? JSONEncoder().encode(record) else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: fileURL, options: .atomic)
  }

  /// This identifier stays in the local marker; it is never logged or exported.
  private static func currentMachineIdentifier() -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let property = IORegistryEntryCreateCFProperty(
      service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0),
      let identifier = property.takeRetainedValue() as? String,
      let uuid = UUID(uuidString: identifier)
    else { return nil }
    return uuid.uuidString
  }
}
