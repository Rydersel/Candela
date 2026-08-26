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
      plant: CheckupPlantRecord(disclosed: true, detectedAtPixels: 4, missed: false), showings: ["field.black": 1], exposureBookingID: nil,
      partiallyOccludedFields: [CheckupCheckID.field(.black)])
    let text = CheckupSummaryText.render(report)
    let lines = text.split(separator: "\n").map(String.init)
    #expect(lines.first == CheckupReport.headerSentence)
    #expect(text.contains("DELL U2725QE"))
    #expect(text.contains("no serial reported"))
    #expect(text.contains("Identity"))
    #expect(text.contains("Visual fields"))
    #expect(text.contains("self-reported: nothing seen (control detected at 4 px)"))
    // The three lines a reader of the file needs and a reader of the screen
    // gets from the room: what the attestations are worth, which fields were
    // shown under the strip, and how the run ended.
    #expect(text.contains(CheckupCopy.attestationNote))
    #expect(text.contains("instruction strip over their lower edge: black."))
    #expect(lines.last == CheckupCopy.completionLine(.complete))
    #expect(text.contains("Completion: complete."))
    #expect(!text.contains("—"))
  }

  /// CK30, measured claims only. A run abandoned before the identity leg still
  /// carries a placeholder identity, and printing it would have the document
  /// report a serial, a native size and a pair of EDID HDR flags that nothing
  /// ever read.
  @Test func aRunThatDidNotReadTheEDIDClaimsNothingFromIt() {
    let text = CheckupSummaryText.render(
      report(
        identityVerdict: .notObserved("no EDID exposed"), serial: nil, nativeWidth: 0,
        nativeHeight: 0, maxRefreshHz: nil))
    #expect(!text.contains("Serial:"))
    #expect(!text.contains("HDR flags"))
    #expect(!text.contains("0 by 0"))
    #expect(!text.contains("Manufactured:"))
    #expect(!text.contains("Maximum refresh:"))
    #expect(text.contains(CheckupCopy.identityNotRead))
    // The claim itself still stands, with its own reason.
    #expect(text.contains("not observed: no EDID exposed"))
    // Facts about the run rather than about the display, so they survive.
    #expect(text.contains("macOS: 26.0"))
  }

  /// A zero size is a placeholder that survived the read, not a panel that
  /// measures zero.
  @Test func aZeroNativeSizeReadsAsNotReported() {
    let text = CheckupSummaryText.render(
      report(identityVerdict: .observed("EDID parsed"), nativeWidth: 0, nativeHeight: 0))
    #expect(text.contains("Native resolution: not reported"))
    #expect(!text.contains("0 by 0"))
  }

  /// The built-in leads `allControlledStates`, so opening on the first display
  /// opens a fresh external's owner on a laptop panel nobody has checked while
  /// the run they just finished hides behind the picker.
  @Test func theHistoryOpensOnTheDisplayThatRanMostRecently() {
    let older = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let newer = Date(timeIntervalSinceReferenceDate: 800_000_000)
    #expect(
      CheckupHistoryScope.defaultKey([
        (key: "builtIn", isBuiltIn: true, latestRun: older),
        (key: "ext", isBuiltIn: false, latestRun: newer),
      ]) == "ext")
    // The newest run wins on its date, not on where its display sits.
    #expect(
      CheckupHistoryScope.defaultKey([
        (key: "builtIn", isBuiltIn: true, latestRun: newer),
        (key: "ext", isBuiltIn: false, latestRun: older),
      ]) == "builtIn")
    #expect(
      CheckupHistoryScope.defaultKey([
        (key: "builtIn", isBuiltIn: true, latestRun: nil),
        (key: "ext", isBuiltIn: false, latestRun: older),
      ]) == "ext")
    // Nothing stored anywhere: the first external, which is the display a
    // person just plugged in and came here about.
    #expect(
      CheckupHistoryScope.defaultKey([
        (key: "builtIn", isBuiltIn: true, latestRun: nil),
        (key: "a", isBuiltIn: false, latestRun: nil),
        (key: "b", isBuiltIn: false, latestRun: nil),
      ]) == "a")
    #expect(
      CheckupHistoryScope.defaultKey([(key: "builtIn", isBuiltIn: true, latestRun: nil)])
        == "builtIn")
    #expect(CheckupHistoryScope.defaultKey([]) == nil)
  }

  private func report(
    identityVerdict: CheckupVerdict, serial: String? = nil, nativeWidth: Int = 3840,
    nativeHeight: Int = 2160, maxRefreshHz: Double? = 120
  ) -> CheckupReport {
    CheckupReport(
      scenario: .newMonitor,
      identity: CheckupDisplayIdentity(
        identityKey: "k", vendorID: 0, modelID: 0, serial: serial, manufactureWeek: nil,
        manufactureYear: nil, nativePixelWidth: nativeWidth, nativePixelHeight: nativeHeight,
        maxRefreshHz: maxRefreshHz, supportsPQEOTF: false, supportsHDRGammaEOTF: false,
        productName: "MAG 341C OLED"),
      panelClass: .writeOnlyDDC, macOSBuild: "26.0", appBuild: "3",
      startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), endedAt: nil,
      completion: .incomplete(reason: CheckupCopy.closedReason),
      claims: [CheckupClaim(family: .identity, id: CheckupCheckID.identity, verdict: identityVerdict)],
      plant: nil, showings: [:], exposureBookingID: nil)
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
