import CoreGraphics
import Foundation

/// One paired instant, recorded so a candidate model can be scored offline.
///
/// The whole point of the format is that a record carries enough to recompute
/// BOTH sides from scratch. Iterating on the model against the live app costs a
/// deploy plus a multi-day soak to read one number; replaying recorded inputs
/// costs seconds, and the same log scores every future variant.
///
/// **`v` is a tool file format, not shipped schema.** §4's never-rename rule
/// governs prefs and enum raw values that live on a user's disk. This artefact
/// can be restructured freely; the field exists only so the harness refuses a
/// log it does not understand instead of misreading one.
public struct ModelReplayRecord: Codable, Equatable, Sendable {
  public static let formatVersion = 3

  public struct Display: Codable, Equatable, Sendable {
    public var persistenceKey: String
    public var displayID: UInt32
    /// **Points, not pixels, whatever the names say.** What macOS reports for
    /// the display, so already rotated: the Dell is a manufactured 3840x2160
    /// panel mounted at 270 degrees and records here as 1440x2560 points.
    ///
    /// Nothing downstream is wrong, because window bounds, display bounds and
    /// `PanelSpaceTransform` all live in that same point space; the log was
    /// merely describing itself in the wrong unit. The names stay: the capture
    /// tool builds this by argument label, so renaming is a coordinated change
    /// across two targets plus a format bump, and it buys only the label.
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var rotation: DisplayRotation

    public init(
      persistenceKey: String, displayID: UInt32, pixelWidth: Int, pixelHeight: Int,
      rotation: DisplayRotation
    ) {
      self.persistenceKey = persistenceKey
      self.displayID = displayID
      self.pixelWidth = pixelWidth
      self.pixelHeight = pixelHeight
      self.rotation = rotation
    }
  }

  /// What the capture actually delivered, in DISPLAY orientation at its own
  /// shape: 24x10 on the MAG, 14x24 on the rotated Dell.
  ///
  /// Stored rather than only its panel-physical derivation because a derived
  /// product can conceal its own cause. The letterbox defect was invisible in
  /// the stored map and obvious in the capture; recording the measurement keeps
  /// that distinction available to whoever reads this next.
  public struct Capture: Codable, Equatable, Sendable {
    public var cols: Int
    public var rows: Int
    public var grid: [Double]

    public init(cols: Int, rows: Int, grid: [Double]) {
      self.cols = cols
      self.rows = rows
      self.grid = grid
    }
  }

  /// Display-local, top-left origin, in the window server's front-to-back
  /// order. See `ExposureModelInputs.windows`: re-sorting this destroys the
  /// experiment without failing anything.
  public struct Window: Codable, Equatable, Sendable {
    public var id: UInt32
    public var pid: Int32
    public var owner: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var layer: Int

    public init(
      id: UInt32, pid: Int32, owner: String, x: Double, y: Double, w: Double, h: Double,
      layer: Int
    ) {
      self.id = id
      self.pid = pid
      self.owner = owner
      self.x = x
      self.y = y
      self.w = w
      self.h = h
      self.layer = layer
    }

    public init(_ snapshot: WindowSnapshot) {
      self.init(
        id: snapshot.windowID, pid: snapshot.ownerPID, owner: snapshot.ownerName,
        x: snapshot.bounds.origin.x, y: snapshot.bounds.origin.y,
        w: snapshot.bounds.size.width, h: snapshot.bounds.size.height,
        layer: snapshot.layer)
    }

    public var snapshot: WindowSnapshot {
      WindowSnapshot(
        windowID: id, ownerPID: pid, ownerName: owner,
        bounds: CGRect(x: x, y: y, width: w, height: h), layer: layer)
    }
  }

  public var v: Int
  public var t: Double
  public var elapsed: TimeInterval
  public var display: Display
  public var capture: Capture
  /// The panel-physical measured grid the capture tool derived live. Replay's
  /// own transform output is checked against it, so a transform error surfaces
  /// as a control failure rather than as a fitted-around distortion.
  public var measuredPanel: [Double]
  /// What the shipped model computed live at this instant. Replay with
  /// `.baseline` must reproduce it, or the log is lossy.
  public var modelledBaseline: [Double]
  public var wallpaper: [Double]?
  /// Which image the cells above came from. Recorded per sample because this
  /// rig runs a different wallpaper per display, and because a run whose
  /// wallpaper is wrong looks exactly like a model that cannot predict.
  public var wallpaperPath: String
  public var appearanceIsDark: Bool
  /// Exactly what the app's own window source reports, so `modelledBaseline`
  /// is reproducible from this alone.
  public var windows: [Window]
  /// The desktop elements the app's source filters out before the model ever
  /// sees them: the Dock, the menu bar, the desktop backdrop.
  ///
  /// Recorded but NOT fed to the baseline model, because they are not what the
  /// shipped model consumes. `ExposureModel.includedLayers` documents itself as
  /// reaching "up through the Dock and the menu bar", but the source applies
  /// `.excludeDesktopElements` first, so that range never sees them. The
  /// measured capture does contain their light. Whether closing that asymmetry
  /// helps is a variant this log can answer offline instead of costing another
  /// collection run.
  public var chrome: [Window]

  public init(
    v: Int = ModelReplayRecord.formatVersion, t: Double, elapsed: TimeInterval,
    display: Display, capture: Capture, measuredPanel: [Double], modelledBaseline: [Double],
    wallpaper: [Double]?, wallpaperPath: String = "", appearanceIsDark: Bool,
    windows: [Window], chrome: [Window] = []
  ) {
    self.v = v
    self.t = t
    self.elapsed = elapsed
    self.display = display
    self.capture = capture
    self.measuredPanel = measuredPanel
    self.modelledBaseline = modelledBaseline
    self.wallpaper = wallpaper
    self.wallpaperPath = wallpaperPath
    self.appearanceIsDark = appearanceIsDark
    self.windows = windows
    self.chrome = chrome
  }

  public var transform: PanelSpaceTransform {
    PanelSpaceTransform(
      displaySize: CGSize(width: display.pixelWidth, height: display.pixelHeight),
      rotation: display.rotation)
  }

  public var inputs: ExposureModelInputs {
    ExposureModelInputs(
      windows: windows.map(\.snapshot), wallpaperCells: wallpaper,
      appearanceIsDark: appearanceIsDark)
  }

  /// The same instant with system chrome admitted, for the variant that asks
  /// whether modelling the Dock and menu bar closes any of the gap. Chrome goes
  /// BEHIND the app windows: it is what a window occludes, never the reverse.
  public var inputsIncludingChrome: ExposureModelInputs {
    ExposureModelInputs(
      windows: (windows + chrome).map(\.snapshot), wallpaperCells: wallpaper,
      appearanceIsDark: appearanceIsDark)
  }

  /// Grids rounded to `ModelReplayLog.decimals`, which is already far past an
  /// 8-bit source's real precision and roughly halves the file.
  public func roundedForLog() -> ModelReplayRecord {
    var copy = self
    copy.capture.grid = copy.capture.grid.map(ModelReplayLog.round)
    copy.measuredPanel = copy.measuredPanel.map(ModelReplayLog.round)
    copy.modelledBaseline = copy.modelledBaseline.map(ModelReplayLog.round)
    copy.wallpaper = copy.wallpaper.map { $0.map(ModelReplayLog.round) }
    return copy
  }
}

/// Append-only JSON Lines writer with file rotation.
///
/// One line per sample so a crash costs at most a torn line, which the reader
/// discards. Torn LINE, not torn final line: a write that fails part way leaves
/// an unterminated tail mid-file, and `append` seals it so the next record does
/// not concatenate onto it. Inspectable with `grep` and `python3`, which
/// matters more on a probe instrument than the bytes a binary format would
/// save.
public final class ModelReplayLog {
  /// 1/255 is 0.0039, so five places is already past what an 8-bit capture can
  /// express. Consequence: both replay controls compare within a tolerance and
  /// never by exact equality.
  public static let decimals = 5
  private static let scale = pow(10.0, Double(decimals))

  public static func round(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return (value * scale).rounded() / scale
  }

  /// Rotate on BYTES, not only on a record count.
  ///
  /// A record-count cap is a proxy for disk, and the proxy drifted the moment
  /// the capture oversample went to 16 cells per grid-cell edge. A record used
  /// to be about 11.5 KB; it now carries the whole capture grid, one JSON
  /// number per cell, and MEASURED here it is 493 KB on the MAG (a 384x161
  /// request) and 660 KB on the rotated Dell (216x384). The old defaults of
  /// 2000 records across 5 files were sized as 110 MB and would now retain
  /// about 6 GB, with each whole-file read in the fit landing over a gigabyte
  /// in one allocation.
  ///
  /// Bytes cap the thing that actually matters and stay correct through the
  /// next change to the capture shape. The arithmetic:
  ///
  /// - a file closes once it passes `bytesPerFile`, so it overshoots by at
  ///   most one record. The ceiling for a record is the square case, 384x384
  ///   cells, about 1.2 MB; no panel here is square, so this is a bound rather
  ///   than an expectation.
  /// - retained <= `filesKept * (bytesPerFile + 1.2 MB)`
  ///   = 16 * (32 + 1.2) MB = **531 MB**, whatever the panel geometry.
  /// - at the Dell's 660 KB that is about 48 records per file and 780 retained,
  ///   comfortably more than the roughly 450 a 150-minute three-panel session
  ///   at the default 60 second interval produces.
  public static let defaultBytesPerFile = 32 * 1024 * 1024
  public static let defaultFilesKept = 16
  /// Still a cap, and it binds first for a SMALL record: a 7.6 KB record (the
  /// 24x10 grids the tests build) reaches 2000 lines at 15 MB, well under the
  /// byte cap. Whichever limit is reached first rotates.
  public static let defaultSamplesPerFile = 2000

  /// The bound the defaults promise, so a change to any of them fails a test
  /// rather than quietly costing gigabytes.
  public static let recordBytesCeiling = 1_250_000
  public static var retainedBytesCeiling: Int {
    defaultFilesKept * (defaultBytesPerFile + recordBytesCeiling)
  }

  public let directory: URL
  public let samplesPerFile: Int
  public let filesKept: Int
  public let bytesPerFile: Int

  /// Records whose bytes reached the disk only in part, so the loss is stated
  /// rather than inferred from a line the reader could not parse.
  public private(set) var partialWrites = 0

  private var written = 0
  private var writtenBytes = 0
  private var fileIndex = 0
  /// Set at init and after a rotation, so the first append of a run always
  /// opens a NEW file. Resuming INTO the last file was the whole of the
  /// never-rotates defect: `written` is 0 on a fresh process, so the count cap
  /// could not fire, and a tool the operator is told to restart after every
  /// wallpaper or appearance change restarts often.
  private var needsNewFile = true

  public init(
    directory: URL, samplesPerFile: Int = ModelReplayLog.defaultSamplesPerFile,
    filesKept: Int = ModelReplayLog.defaultFilesKept,
    bytesPerFile: Int = ModelReplayLog.defaultBytesPerFile
  ) throws {
    self.directory = directory
    self.samplesPerFile = max(1, samplesPerFile)
    self.filesKept = max(1, filesKept)
    self.bytesPerFile = max(1, bytesPerFile)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    // Resume AFTER the highest existing index, never into it, so a restart
    // (which MP6 requires after a wallpaper change) neither discards what the
    // previous run collected nor grows a file the caps can no longer reach.
    fileIndex = (try? Self.existingIndices(in: directory).max()).flatMap { $0 } ?? 0
  }

  static func existingIndices(in directory: URL) throws -> [Int] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    return names.compactMap { name in
      guard name.hasPrefix("replay-"), name.hasSuffix(".jsonl") else { return nil }
      return Int(name.dropFirst("replay-".count).dropLast(".jsonl".count))
    }
  }

  private func url(for index: Int) -> URL {
    directory.appendingPathComponent(String(format: "replay-%05d.jsonl", index))
  }

  public func append(_ record: ModelReplayRecord) throws {
    if needsNewFile || written >= samplesPerFile || writtenBytes >= bytesPerFile {
      fileIndex += 1
      written = 0
      writtenBytes = 0
      needsNewFile = false
    }
    let encoder = JSONEncoder()
    var line = try encoder.encode(record.roundedForLog())
    line.append(0x0A)

    let target = url(for: fileIndex)
    // Updating, not writing: the seal check below has to READ the last byte,
    // and a write-only handle cannot.
    if let handle = FileHandle(forUpdatingAtPath: target.path) {
      defer { try? handle.close() }
      let end = try handle.seekToEnd()
      // Seal an unterminated tail before appending. A write that throws part
      // way (a full disk is the realistic one) lands bytes without its closing
      // newline, and the next append would concatenate onto them: one
      // unparseable line spanning two records, so the good record is lost
      // along with the torn one. A lone newline costs one line and keeps the
      // damage to the record that actually suffered it.
      if end > 0, try Self.lastByte(of: handle, fileLength: end) != 0x0A {
        partialWrites += 1
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]))
        writtenBytes += 1
      }
      try handle.write(contentsOf: line)
    } else {
      try line.write(to: target)
    }
    written += 1
    writtenBytes += line.count
    // After the write, not before: pruning first would keep `filesKept` old
    // files and then add one, leaving the cap permanently off by one.
    pruneOldFiles()
  }

  private static func lastByte(of handle: FileHandle, fileLength: UInt64) throws -> UInt8? {
    try handle.seek(toOffset: fileLength - 1)
    return try handle.read(upToCount: 1)?.first
  }

  private func pruneOldFiles() {
    guard let indices = try? Self.existingIndices(in: directory) else { return }
    for stale in indices.sorted().dropLast(filesKept) {
      try? FileManager.default.removeItem(at: url(for: stale))
    }
  }

  /// What a read could not use, by cause.
  ///
  /// One counter could not tell "your log is from a newer tool" from "your log
  /// is damaged", and it charged a whole unreadable FILE the same single unit
  /// as one torn line. Both matter on the artifact that produces a verdict: a
  /// version mismatch is a tool to rebuild, damage is a capture to rerun, and a
  /// missing file is an unknown number of records rather than one.
  public struct ReadLosses: Equatable, Sendable, CustomStringConvertible {
    /// Lines that are not decodable records: a torn write, a truncated
    /// multi-byte character, anything else the JSON decoder refuses.
    public var damagedLines = 0
    /// Lines that decoded far enough to state a format version this tool does
    /// not read. Refused rather than misread.
    public var versionMismatchLines = 0
    /// Files that could not be opened at all. Their records are lost and their
    /// COUNT is unknown, which is why this is not folded into a line total.
    /// Reachable in the documented workflow: the fit is polled during capture,
    /// indices are enumerated before the files are opened, and pruning deletes
    /// files between those two moments.
    public var unreadableFiles = 0
    /// The versions actually seen, so the operator is told which tool wrote it.
    public var mismatchedVersions: Set<Int> = []

    public init() {}

    /// Lines only. `unreadableFiles` deliberately does not count here: adding
    /// an unknown quantity to a known one produces a number that reads as
    /// precise and is not.
    public var lostLines: Int { damagedLines + versionMismatchLines }

    public var isEmpty: Bool { lostLines == 0 && unreadableFiles == 0 }

    /// Written to read inside a sentence, because the fit interpolates this
    /// straight into its "records N, skipped ..." line.
    public var description: String {
      guard !isEmpty else { return "0" }
      func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n == 1 ? one : many)"
      }
      var parts: [String] = []
      if damagedLines > 0 {
        parts.append(count(damagedLines, "damaged line", "damaged lines"))
      }
      if versionMismatchLines > 0 {
        let seen = mismatchedVersions.sorted().map(String.init).joined(separator: ", ")
        parts.append(
          count(versionMismatchLines, "line", "lines") + " from format \(seen) "
            + "(this tool reads \(ModelReplayRecord.formatVersion))")
      }
      if unreadableFiles > 0 {
        parts.append(
          count(unreadableFiles, "unreadable file", "unreadable files")
            + ", holding an unknown number of records")
      }
      return parts.joined(separator: "; ")
    }
  }

  /// Just enough of a line to ask which format wrote it, WITHOUT the full
  /// decode succeeding. Version was checked after the decode, so a record from
  /// a newer tool that added a required field failed to decode and was booked
  /// as damage: the two diagnoses that lead to opposite actions looked
  /// identical.
  private struct VersionEnvelope: Decodable {
    var v: Int
  }

  /// Every record in a log directory, oldest first. A line that fails to decode
  /// is skipped and counted rather than aborting the read: the last line of an
  /// interrupted run is expected to be torn, and one bad line should not throw
  /// away a week of samples. What was skipped comes back broken out by cause;
  /// see `ReadLosses`, whose description is written to be printed as it stands.
  public static func read(directory: URL) throws -> (
    records: [ModelReplayRecord], skipped: ReadLosses
  ) {
    let indices = try existingIndices(in: directory).sorted()
    let decoder = JSONDecoder()
    var records: [ModelReplayRecord] = []
    var losses = ReadLosses()
    for index in indices {
      let path = directory.appendingPathComponent(String(format: "replay-%05d.jsonl", index))
      // Read BYTES and split on newline, rather than decoding the file as one
      // UTF-8 string. A tear that splits a multi-byte character made the whole
      // file fail to decode, so `continue` discarded every record in it and
      // reported `skipped 0`: the count actively misdirected the diagnosis, and
      // an interrupted capture is the ordinary way to produce that tear.
      //
      // Mapped, not slurped: the kernel pages a file in as the split walks it,
      // so a full file is never one anonymous allocation. That is what keeps
      // the byte cap on a file a memory bound too and not just a disk one.
      guard let bytes = try? Data(contentsOf: path, options: .mappedIfSafe) else {
        losses.unreadableFiles += 1
        continue
      }
      for line in bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
        let data = Data(line)
        guard !data.isEmpty else { continue }
        guard let envelope = try? decoder.decode(VersionEnvelope.self, from: data) else {
          losses.damagedLines += 1
          continue
        }
        guard envelope.v == ModelReplayRecord.formatVersion else {
          losses.versionMismatchLines += 1
          losses.mismatchedVersions.insert(envelope.v)
          continue
        }
        guard let record = try? decoder.decode(ModelReplayRecord.self, from: data) else {
          losses.damagedLines += 1
          continue
        }
        records.append(record)
      }
    }
    return (records, losses)
  }
}
