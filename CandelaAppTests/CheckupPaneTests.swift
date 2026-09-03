import CandelaKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

/// The document is what a person forwards to a seller and the pane is where a
/// verdict would creep in, so both are read here rather than by eye.
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
    // What a reader of the file needs that a reader of the screen gets from the room.
    #expect(text.contains(CheckupCopy.attestationNote))
    #expect(text.contains("instruction strip over their lower edge: black."))
    #expect(lines.last == CheckupCopy.completionLine(.complete))
    #expect(text.contains("Completion: complete."))
    #expect(!text.contains("—"))
  }

  /// A run abandoned before the identity leg carries a placeholder
  /// identity, and printing it would report a serial and flags nothing read.
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

  /// The built-in leads `allControlledStates`, so "first display" would hide a
  /// fresh external's run behind the picker.
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

  /// The sweep that feeds `defaultKey` decodes every stored run for every
  /// display, and the pane re-ran it every time the window came back to the
  /// front. It buys the default scope and nothing else.
  @Test func onlyTheDefaultScopeNeedsEveryDisplaysHistory() {
    #expect(CheckupHistoryScope.needsEveryDisplay(chosenByHand: false))
    #expect(!CheckupHistoryScope.needsEveryDisplay(chosenByHand: true))
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

  /// Two verifiers share one section, so their titles have to be tellable apart.
  @Test func theVerifySectionNamesItsTwoFilesApart() {
    #expect(CheckupPaneCopy.verify != ProvenanceCopy.check)
    #expect(ProvenanceCopy.check.lowercased().contains("provenance"))
    #expect(!CheckupPaneCopy.verify.lowercased().contains("provenance"))
    // Each answer names the kind of file it is about, so a reader who ran the
    // wrong button can see which one answered.
    #expect(CheckupPaneCopy.valid.contains("report"))
    #expect(ProvenanceCopy.intact.contains("record"))
  }

  /// The no-verdict rule over the whole pane: nothing hands the display a result.
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

  /// Layer 2: build the pane over a directory that does not exist and
  /// assert only that pixels came out. Never `CheckupStore.defaultDirectory()`,
  /// or the test reads this machine's own history.
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
