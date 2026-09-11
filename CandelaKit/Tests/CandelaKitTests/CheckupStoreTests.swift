import Foundation
import Testing
@testable import CandelaKit

@Suite("Checkup store")
struct CheckupStoreTests {
  private func report(started: TimeInterval, key: String = "k1") -> CheckupReport {
    CheckupReport(
      scenario: .newMonitor,
      identity: CheckupDisplayIdentity(identityKey: key, vendorID: 1, modelID: 2, serial: nil,
        manufactureWeek: nil, manufactureYear: nil, nativePixelWidth: 1, nativePixelHeight: 1,
        maxRefreshHz: nil, supportsPQEOTF: false, supportsHDRGammaEOTF: false, productName: "DELL U2725QE"),
      panelClass: .readsDDC, macOSBuild: "b", appBuild: "3",
      startedAt: Date(timeIntervalSinceReferenceDate: started), endedAt: nil, completion: .complete,
      claims: [], plant: nil, showings: [:], exposureBookingID: nil)
  }

  @Test func savesListsNewestFirstAndLoadsBack() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = CheckupStore(directory: dir)
    _ = try store.save(try CheckupReportEnvelope(report: report(started: 100)))
    let newer = try store.save(try CheckupReportEnvelope(report: report(started: 200)))
    _ = try store.save(try CheckupReportEnvelope(report: report(started: 150, key: "other")))
    let runs = try store.list(identityKey: "k1")
    #expect(runs.count == 2)
    #expect(runs.first?.url == newer)
    #expect(try store.load(url: newer).validate())
  }

  /// The control is the second assertion: a delete that took the whole store
  /// would satisfy the first one on its own.
  @Test func deleteRemovesOnlyTheRunItNames() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = CheckupStore(directory: dir)
    let older = try store.save(try CheckupReportEnvelope(report: report(started: 100)))
    let newer = try store.save(try CheckupReportEnvelope(report: report(started: 200)))
    _ = try store.save(try CheckupReportEnvelope(report: report(started: 150, key: "other")))
    try store.delete(url: newer)
    #expect(try store.list(identityKey: "k1").map(\.url) == [older])
    #expect(try store.list(identityKey: "other").count == 1)
  }

  /// Without the second assertion the test cannot tell a refusal from a delete
  /// that removed the file and threw afterwards.
  @Test func deleteRefusesAURLOutsideTheStore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = CheckupStore(directory: root.appendingPathComponent("store", isDirectory: true))
    let sibling = root.appendingPathComponent("store-elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let outside = sibling.appendingPathComponent("not-ours.json")
    try Data("{}".utf8).write(to: outside)
    #expect(throws: CheckupStoreError.self) { try store.delete(url: outside) }
    #expect(FileManager.default.fileExists(atPath: outside.path))
  }

  /// The identity folder holds a display's whole history and `removeItem` takes
  /// a directory with everything in it. The surviving run is the real assertion.
  @Test func deleteRefusesTheIdentityFolder() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = CheckupStore(directory: dir)
    let run = try store.save(try CheckupReportEnvelope(report: report(started: 100)))
    let folder = run.deletingLastPathComponent()
    #expect(throws: CheckupStoreError.notAStoredRun) { try store.delete(url: folder) }
    #expect(try store.list(identityKey: "k1").map(\.url) == [run])
  }

  /// A run file is a `json` name one level under an identity folder. Other
  /// shapes are inside the store too, so containment cannot be the whole guard.
  @Test func deleteRefusesANestedPathThatIsNotARunFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = CheckupStore(directory: dir)
    let run = try store.save(try CheckupReportEnvelope(report: report(started: 100)))
    let folder = run.deletingLastPathComponent()
    let notes = folder.appendingPathComponent("notes.txt")
    try Data("keep me".utf8).write(to: notes)
    let deeper = folder.appendingPathComponent("nested", isDirectory: true)
      .appendingPathComponent("run.json")
    try FileManager.default.createDirectory(
      at: deeper.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: deeper)
    // At a run's depth and with a run's extension, and still a directory.
    let folderNamedLikeARun = folder.appendingPathComponent("nested.json", isDirectory: true)
    try FileManager.default.createDirectory(at: folderNamedLikeARun, withIntermediateDirectories: true)
    #expect(throws: CheckupStoreError.notAStoredRun) { try store.delete(url: notes) }
    #expect(throws: CheckupStoreError.notAStoredRun) { try store.delete(url: deeper) }
    #expect(throws: CheckupStoreError.notAStoredRun) { try store.delete(url: folderNamedLikeARun) }
    #expect(FileManager.default.fileExists(atPath: notes.path))
    #expect(FileManager.default.fileExists(atPath: deeper.path))
    #expect(FileManager.default.fileExists(atPath: folderNamedLikeARun.path))
    #expect(try store.list(identityKey: "k1").map(\.url) == [run])
  }

  /// `save` and `list` reach their URLs by different routes, so a guard that
  /// skipped canonicalizing would refuse the URL the history hands it.
  @Test func deleteAcceptsTheURLListGaveBack() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = CheckupStore(directory: dir)
    _ = try store.save(try CheckupReportEnvelope(report: report(started: 100)))
    let run = try #require(try store.list(identityKey: "k1").first)
    #expect(throws: Never.self) { try store.delete(url: run.url) }
    #expect(try store.list(identityKey: "k1").isEmpty)
  }

  /// Spaces kept: this is what the save panel offers.
  @Test func exportFileNameCarriesModelAndDate() {
    let name = CheckupStore.exportFileName(for: report(started: 800_000_000))
    #expect(name.hasPrefix("Candela Checkup DELL U2725QE 2026-05-09"))
    #expect(name.hasSuffix(".candela-checkup.json"))
  }

  /// A product name is whatever the panel's EDID says. A slash in it would
  /// reach the save panel as a path separator.
  @Test func exportFileNameSanitizesTheModel() {
    var hostile = report(started: 800_000_000)
    hostile.identity = CheckupDisplayIdentity(
      identityKey: "k1", vendorID: 1, modelID: 2, serial: nil, manufactureWeek: nil,
      manufactureYear: nil, nativePixelWidth: 1, nativePixelHeight: 1, maxRefreshHz: nil,
      supportsPQEOTF: false, supportsHDRGammaEOTF: false, productName: "AW/34: DW")
    let name = CheckupStore.exportFileName(for: hostile)
    #expect(!name.contains("/"))
    #expect(!name.contains(":"))
    // The two path characters go; the space between them does not.
    #expect(name.hasPrefix("Candela Checkup AW_34_ DW 2026-05-09"))
  }

  /// A leading dot would hide the export in Finder.
  @Test func exportFileNameNeverStartsTheModelWithADot() {
    #expect(CheckupStore.safeFileName(".hidden") == "_hidden")
    #expect(CheckupStore.safeFileName("DELL U2725QE") == "DELL U2725QE")
  }

  @Test func theBookingGridIsUniformAtTheFieldLuminance() {
    let grid = CheckupExposureBooking.panelGrid(luminance: 0.25)
    #expect(grid.count == PanelGrid.cellCount)
    #expect(grid.allSatisfy { $0 == 0.25 })
  }
}
