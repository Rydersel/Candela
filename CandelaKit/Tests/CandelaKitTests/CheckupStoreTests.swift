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

  @Test func exportFileNameCarriesModelAndDate() {
    let name = CheckupStore.exportFileName(for: report(started: 800_000_000))
    #expect(name.hasPrefix("Candela Checkup DELL_U2725QE 2026-05-09"))
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
    #expect(name.hasPrefix("Candela Checkup AW_34__DW 2026-05-09"))
  }

  @Test func theBookingGridIsUniformAtTheFieldLuminance() {
    let grid = CheckupExposureBooking.panelGrid(luminance: 0.25)
    #expect(grid.count == PanelGrid.cellCount)
    #expect(grid.allSatisfy { $0 == 0.25 })
  }
}
