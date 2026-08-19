import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

// The replay log is the instrument the whole probe rests on. If a record does
// not carry enough to recompute both sides, every number fitted from it is
// about the log rather than about the model.
@Suite("Model replay log")
struct ModelReplayLogTests {

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("replay-\(UInt32.random(in: 0..<UInt32.max))")
  }

  private func record(
    t: Double = 100, owners: [String] = ["Ghostty", "Safari"], captureCols: Int = 24,
    captureRows: Int = 10
  )
    -> ModelReplayRecord
  {
    let display = ModelReplayRecord.Display(
      persistenceKey: "3669D03D-TEST", displayID: 7,
      pixelWidth: 3440, pixelHeight: 1440, rotation: .standard)
    let transform = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    let windows = owners.enumerated().map { index, owner in
      ModelReplayRecord.Window(
        id: UInt32(index + 1), pid: Int32(index + 1), owner: owner,
        x: Double(index) * 200, y: 100, w: 1600, h: 900, layer: 0)
    }
    let paper = (0..<PanelGrid.cellCount).map { Double($0 % 17) / 17.0 }
    let inputs = ExposureModelInputs(
      windows: windows.map(\.snapshot), wallpaperCells: paper, appearanceIsDark: false)
    let modelled = ExposureModel.modelledGrid(inputs: inputs, through: transform)
    return ModelReplayRecord(
      t: t, elapsed: 60,
      display: display,
      capture: .init(
        cols: captureCols, rows: captureRows,
        grid: (0..<(captureCols * captureRows)).map { Double($0 % 9973) / 9973.0 }),
      measuredPanel: (0..<240).map { Double($0) / 240.0 },
      modelledBaseline: modelled,
      wallpaper: paper, appearanceIsDark: false, windows: windows)
  }

  @Test("a written record replays to the grid it recorded")
  func roundTripReproducesTheBaselineGrid() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try ModelReplayLog(directory: directory)
    try log.append(record())

    let (records, skipped) = try ModelReplayLog.read(directory: directory)
    #expect(skipped.isEmpty)
    #expect(records.count == 1)

    let read = try #require(records.first)
    let replayed = ExposureModel.modelledGrid(
      inputs: read.inputs, through: read.transform, parameters: .baseline)
    // Tolerance, not equality: grids are rounded to 5 places on write.
    let tolerance = 1.0 / pow(10.0, Double(ModelReplayLog.decimals - 1))
    for cell in 0..<PanelGrid.cellCount {
      #expect(abs(replayed[cell] - read.modelledBaseline[cell]) < tolerance)
    }
  }

  @Test("window order survives the round trip, because it is the experiment")
  func windowOrderIsPreserved() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try ModelReplayLog(directory: directory)
    let owners = ["Zed", "Alacritty", "Books", "Music"]
    try log.append(record(owners: owners))

    let (records, _) = try ModelReplayLog.read(directory: directory)
    #expect(try #require(records.first).windows.map(\.owner) == owners)
  }

  @Test("the rotating cap holds and the oldest file is the one that goes")
  func rotationKeepsTheCap() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try ModelReplayLog(directory: directory, samplesPerFile: 2, filesKept: 3)
    for index in 0..<20 { try log.append(record(t: Double(index))) }

    let indices = try ModelReplayLog.existingIndices(in: directory).sorted()
    #expect(indices.count == 3)

    let (records, _) = try ModelReplayLog.read(directory: directory)
    // 3 files of 2 samples: the six most recent instants, oldest first.
    #expect(records.map(\.t) == [14, 15, 16, 17, 18, 19])
  }

  @Test("a tear splitting a multi-byte character costs its line, not its file")
  func tornLineDoesNotDiscardTheRun() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try ModelReplayLog(directory: directory)
    try log.append(record(t: 1))
    try log.append(record(t: 2))

    // Bytes, not String. The previous version of this test built its fixture
    // through `String(contentsOf:)` and `write(atomically:encoding:.utf8)`, so
    // the file stayed valid UTF-8 and a String-based reader passed it: it did
    // not exercise the tear it was written for. A capture killed mid-write
    // truncates wherever the write got to, and an owner name is the field most
    // likely to carry a multi-byte character.
    let file = directory.appendingPathComponent("replay-00001.jsonl")
    var bytes = try Data(contentsOf: file)
    bytes.append(contentsOf: Array("{\"v\":3,\"t\":3,\"windows\":[{\"owner\":\"Caf".utf8))
    bytes.append(contentsOf: [0xC3])  // the lead byte of "é" with its continuation lost
    bytes.append(0x0A)
    try bytes.write(to: file)

    let (records, skipped) = try ModelReplayLog.read(directory: directory)
    #expect(records.map(\.t) == [1, 2])
    #expect(skipped.damagedLines == 1)
    #expect(skipped.versionMismatchLines == 0)
    #expect(skipped.unreadableFiles == 0)
  }

  @Test("a record from a newer format is refused, and named as a version")
  func unknownVersionIsSkipped() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try ModelReplayLog(directory: directory)
    var future = record()
    future.v = ModelReplayRecord.formatVersion + 1
    try log.append(future)

    let (records, skipped) = try ModelReplayLog.read(directory: directory)
    #expect(records.isEmpty)
    #expect(skipped.versionMismatchLines == 1)
    #expect(skipped.damagedLines == 0)
    #expect(skipped.mismatchedVersions == [ModelReplayRecord.formatVersion + 1])
  }

  @Test("a newer record that will not decode at all is still called a version")
  func futureVersionMissingFieldsIsNotCalledDamage() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // A future tool that ADDS a required field writes a line this decoder
    // cannot build a record from. Deciding the version after the decode booked
    // that as damage, which sends the operator to rerun a capture when the fix
    // is to rebuild the tool.
    let file = directory.appendingPathComponent("replay-00001.jsonl")
    let line = "{\"v\":\(ModelReplayRecord.formatVersion + 2),\"onlyField\":true}\n"
    try Data(line.utf8).write(to: file)

    let (records, skipped) = try ModelReplayLog.read(directory: directory)
    #expect(records.isEmpty)
    #expect(skipped.versionMismatchLines == 1)
    #expect(skipped.damagedLines == 0)
    #expect(skipped.description.contains("format \(ModelReplayRecord.formatVersion + 2)"))
  }

  @Test("an unreadable file is not one skipped line")
  func unreadableFileIsCountedAsAFile() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try ModelReplayLog(directory: directory, samplesPerFile: 2)
    for index in 0..<4 { try log.append(record(t: Double(index))) }
    #expect(try ModelReplayLog.existingIndices(in: directory).count == 2)

    // Enumerated, then unopenable: the fit is polled DURING capture, and
    // pruning deletes files between the listing and the open. Chmod reproduces
    // that window deterministically, and a whole file of records must not
    // report as the single skip one torn line would.
    let second = directory.appendingPathComponent("replay-00002.jsonl")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: second.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: second.path)
    }

    let (records, skipped) = try ModelReplayLog.read(directory: directory)
    #expect(records.map(\.t) == [0, 1])
    #expect(skipped.unreadableFiles == 1)
    #expect(skipped.lostLines == 0)
    #expect(skipped.description.contains("unknown number of records"))
  }

  @Test("a restart starts a new file rather than growing the last one")
  func restartRotates() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // The reviewer's measurement: five restarts of ten appends with a cap of
    // 100. Resuming INTO the highest existing index put all fifty in
    // replay-00001 and rotated nothing, so `filesKept` bounded no disk at all.
    var t = 0.0
    for _ in 0..<5 {
      let log = try ModelReplayLog(directory: directory, samplesPerFile: 100, filesKept: 5)
      for _ in 0..<10 {
        try log.append(record(t: t))
        t += 1
      }
    }

    let indices = try ModelReplayLog.existingIndices(in: directory).sorted()
    #expect(indices == [1, 2, 3, 4, 5])
    for index in indices {
      let path = directory.appendingPathComponent(String(format: "replay-%05d.jsonl", index))
      let lines = try Data(contentsOf: path)
        .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).count
      #expect(lines == 10)
    }
    let (records, _) = try ModelReplayLog.read(directory: directory)
    #expect(records.count == 50)
  }

  @Test("restarts past the cap prune, so disk stays bounded")
  func restartsBeyondTheCapPrune() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var t = 0.0
    for _ in 0..<8 {
      let log = try ModelReplayLog(directory: directory, samplesPerFile: 100, filesKept: 3)
      for _ in 0..<2 {
        try log.append(record(t: t))
        t += 1
      }
    }
    #expect(try ModelReplayLog.existingIndices(in: directory).count == 3)
    let (records, _) = try ModelReplayLog.read(directory: directory)
    #expect(records.map(\.t) == [10, 11, 12, 13, 14, 15])
  }

  @Test("a big record rotates on bytes, so a file cannot grow past its cap")
  func rotationIsBoundedByBytes() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // 96x40 is a small stand-in for the shipped 384x161: same shape of record,
    // fast to write. samplesPerFile is deliberately far out of reach, so only
    // the byte cap can rotate this.
    let big = record(captureCols: 96, captureRows: 40)
    let recordBytes = try JSONEncoder().encode(big.roundedForLog()).count
    let cap = recordBytes * 3
    let log = try ModelReplayLog(
      directory: directory, samplesPerFile: 100_000, filesKept: 4, bytesPerFile: cap)
    for index in 0..<20 {
      try log.append(record(t: Double(index), captureCols: 96, captureRows: 40))
    }

    let indices = try ModelReplayLog.existingIndices(in: directory).sorted()
    #expect(indices.count == 4)
    var total = 0
    for index in indices {
      let path = directory.appendingPathComponent(String(format: "replay-%05d.jsonl", index))
      let size = try Data(contentsOf: path).count
      total += size
      // A file closes once it passes the cap, so it overshoots by at most the
      // record that pushed it over.
      #expect(size <= cap + recordBytes + 1)
    }
    #expect(total <= indices.count * (cap + recordBytes + 1))
  }

  @Test("the shipped defaults bound retained disk to what the comment claims")
  func defaultsBoundDisk() throws {
    // The old defaults were derived when a record was 11.5 KB. The capture
    // oversample went to 16 cells per grid-cell edge and nothing downstream was
    // re-derived: 2000 records across 5 files became about 6 GB. This pins the
    // arithmetic so the next change to either constant fails here.
    #expect(ModelReplayLog.retainedBytesCeiling <= 600 * 1024 * 1024)
    #expect(ModelReplayLog.defaultBytesPerFile <= 64 * 1024 * 1024)

    // And pins the per-record figure the bound rests on. The ceiling is the
    // square capture request, 384x384, which no panel here produces; the two
    // real shapes must sit under it with room to spare.
    let square = 24 * LuminanceReduction.captureOversample
    let encoder = JSONEncoder()
    let squareBytes = try encoder.encode(
      record(captureCols: square, captureRows: square).roundedForLog()
    ).count
    #expect(squareBytes <= ModelReplayLog.recordBytesCeiling)

    let (magCols, magRows) = LuminanceReduction.requestedSize(
      displayWidth: 3440, displayHeight: 1440)
    let magBytes = try encoder.encode(
      record(captureCols: magCols, captureRows: magRows).roundedForLog()
    ).count
    #expect(magBytes < ModelReplayLog.recordBytesCeiling)
    // Not a floor for its own sake: an estimate that drifts far ABOVE the truth
    // silently shrinks the retained history, which is the other way this bound
    // can be wrong.
    #expect(magBytes > 100_000)
  }

  @Test("a partial write costs its own record and not the next one")
  func partialWriteDoesNotCorruptTheFollowingRecord() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try ModelReplayLog(directory: directory)
    try log.append(record(t: 1))

    // A write that threw part way, exactly as a full disk leaves it: bytes on
    // disk with no closing newline. Without the seal the next append
    // concatenates onto these and produces ONE unparseable line spanning two
    // records, so the good record is lost with the torn one.
    let file = directory.appendingPathComponent("replay-00001.jsonl")
    var bytes = try Data(contentsOf: file)
    bytes.append(contentsOf: Array("{\"v\":3,\"t\":2,\"elap".utf8))
    try bytes.write(to: file)

    #expect(log.partialWrites == 0)
    try log.append(record(t: 3))
    #expect(log.partialWrites == 1)

    let (records, skipped) = try ModelReplayLog.read(directory: directory)
    #expect(records.map(\.t) == [1, 3])
    #expect(skipped.damagedLines == 1)
  }
}
