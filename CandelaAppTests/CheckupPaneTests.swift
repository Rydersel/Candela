import CandelaKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

/// The pane's own two derivations: the plain-text document a report renders to,
/// and the strings the pane says. Both are read here rather than by eye, because
/// the document is what a person forwards to a seller and the pane is where an
/// overall verdict would creep in if one ever did (CK8).
@Suite("Checkup pane copy and summary text")
struct CheckupPaneTests {
  @Test func theSummaryTextOpensWithTheHeaderSentenceAndGroupsByFamily() throws {
    let report = CheckupReport(
      scenario: .newMonitor,
      identity: CheckupDisplayIdentity(identityKey: "k", vendorID: 1, modelID: 2, serial: nil, manufactureWeek: 51,
        manufactureYear: 2025, nativePixelWidth: 3840, nativePixelHeight: 2160, maxRefreshHz: 120,
        supportsPQEOTF: false, supportsHDRGammaEOTF: false, productName: "DELL U2725QE"),
      panelClass: .readsDDC, macOSBuild: "b", appBuild: "3",
      startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), endedAt: nil, completion: .complete,
      claims: [
        CheckupClaim(family: .identity, id: CheckupCheckID.identity, verdict: .observed("EDID parsed")),
        CheckupClaim(family: .visualField, id: "field.black", verdict: .selfReported("nothing seen"), detectedAt: 4),
      ],
      plant: CheckupPlantRecord(disclosed: true, detectedAtPixels: 4, missed: false), showings: ["field.black": 1], exposureBookingID: nil)
    let text = CheckupSummaryText.render(report)
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.first == CheckupReport.headerSentence)
    #expect(text.contains("DELL U2725QE"))
    #expect(text.contains("no serial reported"))
    #expect(text.contains("Identity"))
    #expect(text.contains("Visual fields"))
    #expect(text.contains("self-reported: nothing seen (control detected at 4 px)"))
    #expect(!text.contains("—"))
  }

  @Test func thePaneNamesTheRunButtonAndNeverAVerdict() {
    #expect(CheckupPaneCopy.run == "Run a checkup")
    #expect(CheckupPaneCopy.verify == "Verify a report")
    #expect(!CheckupPaneCopy.emptyHistory.lowercased().contains("pass"))
  }

  /// CK8 over the whole pane rather than over one string: nothing here hands
  /// the display a result, and the em dash rule is checked where the copy is
  /// defined.
  @Test func noPaneCopyCarriesAnEmDashOrAVerdictOnTheDisplay() {
    for sentence in CheckupPaneCopy.allStringsForTest {
      let lowered = sentence.lowercased()
      #expect(!sentence.contains("—"), "\(sentence)")
      #expect(!lowered.contains("passed"), "\(sentence)")
      #expect(!lowered.contains("failed"), "\(sentence)")
      #expect(!lowered.contains("grade"), "\(sentence)")
      #expect(!lowered.contains("score"), "\(sentence)")
    }
  }

  /// Layer 2 of AT4 for a new composition: build the pane over a store
  /// directory that does not exist and assert only that pixels came out at a
  /// plausible size. What it catches is a crash in `body` and a layout that
  /// collapses to nothing; appearance is a human's job.
  ///
  /// The directory is a temporary one, never `CheckupStore.defaultDirectory()`:
  /// a test that read the real store would report whatever this machine's own
  /// history happens to hold.
  @Test @MainActor func thePaneRendersWithNoStoredRuns() {
    let model = TestFixtures.appModel()
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("checkup-pane-\(UUID().uuidString)", isDirectory: true)
    let pane = CheckupPane(directory: directory)
      .environment(model)
      .environment(SettingsActions(model: model))
      .environment(\.settingsAccent, SettingsRegistry.descriptor(for: .checkup).accent)
      .frame(width: SettingsTheme.pageWidth + 64, height: 560)
    let image = ImageRenderer(content: pane).cgImage
    #expect(image != nil)
    #expect((image?.width ?? 0) > 20)
    #expect((image?.height ?? 0) > 20)
  }
}
