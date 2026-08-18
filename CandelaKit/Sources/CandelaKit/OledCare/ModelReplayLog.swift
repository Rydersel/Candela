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
    /// As macOS reports it, so already rotated. The Dell is a 3840x2160 panel
    /// mounted at 270 degrees and appears here as 2160x3840.
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
/// One line per sample so a crash costs at most a torn final line, which the
/// reader discards. Inspectable with `grep` and `python3`, which matters more
/// on a probe instrument than the bytes a binary format would save.
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

  public let directory: URL
  public let samplesPerFile: Int
  public let filesKept: Int

  private var written = 0
  private var fileIndex = 0

  public init(directory: URL, samplesPerFile: Int = 2000, filesKept: Int = 5) throws {
    self.directory = directory
    self.samplesPerFile = max(1, samplesPerFile)
    self.filesKept = max(1, filesKept)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    // Resume after the highest existing index rather than overwriting, so a
    // restart (which MP6 requires after a wallpaper change) does not discard
    // what the previous run collected.
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
    if written >= samplesPerFile || fileIndex == 0 {
      fileIndex += 1
      written = 0
    }
    let encoder = JSONEncoder()
    var line = try encoder.encode(record.roundedForLog())
    line.append(0x0A)

    let target = url(for: fileIndex)
    if let handle = FileHandle(forWritingAtPath: target.path) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } else {
      try line.write(to: target)
    }
    written += 1
    // After the write, not before: pruning first would keep `filesKept` old
    // files and then add one, leaving the cap permanently off by one.
    pruneOldFiles()
  }

  private func pruneOldFiles() {
    guard let indices = try? Self.existingIndices(in: directory) else { return }
    for stale in indices.sorted().dropLast(filesKept) {
      try? FileManager.default.removeItem(at: url(for: stale))
    }
  }

  /// Every record in a log directory, oldest first. A line that fails to decode
  /// is skipped and counted rather than aborting the read: the last line of an
  /// interrupted run is expected to be torn, and one bad line should not throw
  /// away a week of samples.
  public static func read(directory: URL) throws -> (records: [ModelReplayRecord], skipped: Int) {
    let indices = try existingIndices(in: directory).sorted()
    let decoder = JSONDecoder()
    var records: [ModelReplayRecord] = []
    var skipped = 0
    for index in indices {
      let path = directory.appendingPathComponent(String(format: "replay-%05d.jsonl", index))
      guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
      for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let data = line.data(using: .utf8),
          let record = try? decoder.decode(ModelReplayRecord.self, from: data)
        else {
          skipped += 1
          continue
        }
        guard record.v == ModelReplayRecord.formatVersion else {
          skipped += 1
          continue
        }
        records.append(record)
      }
    }
    return (records, skipped)
  }
}
