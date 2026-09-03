import Foundation

public struct CheckupStoredRun: Equatable, Sendable {
  public let url: URL
  public let startedAt: Date
  public let summaryLine: String
  public let envelope: CheckupReportEnvelope
}

/// One file per run, keyed by identity, under Application Support. The
/// identity key is the display's EDID-derived key, never a display id.
public struct CheckupStore: Sendable {
  public let directory: URL

  public init(directory: URL) { self.directory = directory }

  public static func defaultDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Candela/Checkups", isDirectory: true)
  }

  static func stamp() -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
    f.timeZone = TimeZone(identifier: "UTC")
    return f
  }

  /// The run's day in UTC. The exported file name and the document that names
  /// the run both read from here, so the two can never disagree about the date.
  public static func day(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withFullDate]
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: date)
  }

  /// For a directory this app creates and reads back. Flattens everything
  /// unusual, spaces included, because nobody ever sees these names.
  static func safe(_ s: String) -> String {
    s.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
  }

  /// For a name a person meets in a save panel, which is a different job:
  /// `safe` would hand them "DELL_U2725QE" over a display called DELL U2725QE.
  /// Only what a path component genuinely cannot carry goes, plus a leading dot,
  /// which would hide the file.
  static func safeFileName(_ s: String) -> String {
    let replaced = String(s.map { $0 == "/" || $0 == ":" ? "_" : $0 })
    return replaced.hasPrefix(".") ? "_" + String(replaced.dropFirst()) : replaced
  }

  /// One encoder for stored and exported envelopes, so an export is
  /// byte-identical to the stored file and `validate()` agrees on either.
  public static func encoded(_ envelope: CheckupReportEnvelope) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(envelope)
  }

  @discardableResult
  public func save(_ envelope: CheckupReportEnvelope) throws -> URL {
    let folder = directory.appendingPathComponent(Self.safe(envelope.report.identity.identityKey), isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = Self.stamp().string(from: envelope.report.startedAt).replacingOccurrences(of: ":", with: "-") + ".json"
    let url = folder.appendingPathComponent(name)
    try Self.encoded(envelope).write(to: url, options: .atomic)
    // Same canonical form as list(): macOS temp dirs sit under /var, a symlink
    // to /private/var, and the two must compare equal for the same file.
    return url.resolvingSymlinksInPath()
  }

  public func load(url: URL) throws -> CheckupReportEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CheckupReportEnvelope.self, from: Data(contentsOf: url))
  }

  public func list(identityKey: String) throws -> [CheckupStoredRun] {
    let folder = directory.appendingPathComponent(Self.safe(identityKey), isDirectory: true)
    guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
    let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
    return urls.compactMap { rawURL -> CheckupStoredRun? in
      // `contentsOfDirectory(at:)` hands back /private/var; canonicalize so this
      // equals the URL save() returns for the same file.
      let url = rawURL.resolvingSymlinksInPath()
      guard let envelope = try? load(url: url) else { return nil }
      return CheckupStoredRun(url: url, startedAt: envelope.report.startedAt,
                              summaryLine: envelope.report.summary.line, envelope: envelope)
    }.sorted { $0.startedAt > $1.startedAt }
  }

  /// A product name is whatever the panel's EDID says, and a slash or a colon in
  /// it would reach the save panel as a path. Through the filename sanitizer,
  /// NOT the folder one: the folder never leaves the app, and this is the name
  /// the save panel offers.
  public static func exportFileName(for report: CheckupReport) -> String {
    let model = report.identity.productName.isEmpty ? "Display" : report.identity.productName
    return "Candela Checkup \(safeFileName(model)) \(day(report.startedAt)).candela-checkup.json"
  }
}
