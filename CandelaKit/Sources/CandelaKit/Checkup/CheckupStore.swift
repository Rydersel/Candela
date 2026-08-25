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

  static func safe(_ s: String) -> String {
    s.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
  }

  @discardableResult
  public func save(_ envelope: CheckupReportEnvelope) throws -> URL {
    let folder = directory.appendingPathComponent(Self.safe(envelope.report.identity.identityKey), isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let name = Self.stamp().string(from: envelope.report.startedAt).replacingOccurrences(of: ":", with: "-") + ".json"
    let url = folder.appendingPathComponent(name)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(envelope).write(to: url, options: .atomic)
    // `contentsOfDirectory(at:)` in list() resolves symlinks in the path
    // (macOS temp dirs land under /var, a symlink to /private/var); resolve
    // here too so a URL returned from save() equals the one list() returns
    // for the same file.
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
      // `contentsOfDirectory(at:)` resolves a macOS temp dir's /var symlink
      // to /private/var; `resolvingSymlinksInPath()` canonicalizes back to
      // /var, matching the URL save() returns for the same file.
      let url = rawURL.resolvingSymlinksInPath()
      guard let envelope = try? load(url: url) else { return nil }
      return CheckupStoredRun(url: url, startedAt: envelope.report.startedAt,
                              summaryLine: envelope.report.summary.line, envelope: envelope)
    }.sorted { $0.startedAt > $1.startedAt }
  }

  public static func exportFileName(for report: CheckupReport) -> String {
    let day = ISO8601DateFormatter()
    day.formatOptions = [.withFullDate]
    day.timeZone = TimeZone(identifier: "UTC")
    let model = report.identity.productName.isEmpty ? "Display" : report.identity.productName
    return "Candela Checkup \(model) \(day.string(from: report.startedAt)).candela-checkup.json"
  }
}
