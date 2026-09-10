import Foundation

/// Machine-scoped evidence that the Accessibility grant has been observed present
/// on THIS Mac, so a machine that was asked and declined is told apart from one
/// that was never asked.
///
/// A file and not a preference key: Migration Assistant carries the preferences
/// domain to a new Mac while Accessibility grants stay behind, so a key would
/// arrive already claiming the grant was observed there. Nothing shows it and
/// nothing chooses it, so a settings reset leaves it alone too.
public struct MediaKeyGrantMarker: Sendable {
  public let directory: URL

  public init(directory: URL = MediaKeyGrantMarker.defaultDirectory()) {
    self.directory = directory
  }

  /// The app's own folder under Application Support, where its machine-scoped
  /// state lives.
  public static func defaultDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Candela", isDirectory: true)
  }

  var fileURL: URL { directory.appendingPathComponent("media-key-grant-observed") }

  public var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

  /// A no-op once the file is there, so the first observation's date survives.
  /// Errors are swallowed: an unwritable marker leaves the launch prompt
  /// suppressed, which is the safe direction, and the banner still offers the
  /// grant.
  public func record() {
    guard !exists else { return }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // A timestamp and nothing else: presence is all anything reads, and no
    // identifier of any kind goes in here.
    try? Self.stamp().string(from: Date()).write(to: fileURL, atomically: true, encoding: .utf8)
  }

  private static func stamp() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }
}
