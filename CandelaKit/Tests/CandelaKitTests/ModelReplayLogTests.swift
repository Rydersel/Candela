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

  private func record(t: Double = 100, owners: [String] = ["Ghostty", "Safari"])
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
        cols: 24, rows: 10,
        grid: (0..<240).map { Double($0) / 240.0 }),
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
    #expect(skipped == 0)
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

  @Test("a torn final line is skipped and counted, not thrown")
  func tornLineDoesNotDiscardTheRun() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try ModelReplayLog(directory: directory)
    try log.append(record(t: 1))
    try log.append(record(t: 2))

    let file = directory.appendingPathComponent("replay-00001.jsonl")
    var text = try String(contentsOf: file, encoding: .utf8)
    text += "{\"v\":1,\"t\":3,\"elapsed\"\n"
    try text.write(to: file, atomically: true, encoding: .utf8)

    let (records, skipped) = try ModelReplayLog.read(directory: directory)
    #expect(records.count == 2)
    #expect(skipped == 1)
  }

  @Test("a record from a newer format is refused rather than misread")
  func unknownVersionIsSkipped() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = try ModelReplayLog(directory: directory)
    var future = record()
    future.v = ModelReplayRecord.formatVersion + 1
    try log.append(future)

    let (records, skipped) = try ModelReplayLog.read(directory: directory)
    #expect(records.isEmpty)
    #expect(skipped == 1)
  }
}
