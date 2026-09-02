import Foundation
import Testing

@testable import CandelaKit

/// The derivations the Health pane's cards and the OLED Care overview's cards
/// share. Both read one display's measurement and both must read it the
/// same way, so the sentence they join lives in one function and is pinned here.
///
/// The honesty precedence is what matters: `confidence` is a pure function of
/// the telemetry pref and the stored sample count, so it stays `.measured`
/// through a revoked Screen Recording grant and through Safe Mode. A card that
/// read the switch alone would keep claiming readings a session never took.
@Suite("Summary card copy")
struct HealthCardCopyTests {
  private func summary(
    _ confidence: PanelHealthSummary.Confidence,
    hottestRelative: Double? = nil,
    sampleCount: Int = 0
  ) -> PanelHealthSummary {
    PanelHealthSummary(
      confidence: confidence,
      observationEnabled: true,
      cells: [Double](repeating: 0, count: PanelGrid.cellCount),
      hottestRelative: hottestRelative,
      hottestOwner: nil,
      sampleCount: sampleCount,
      lastSample: nil,
      dominantOwnerByCell: nil,
      topOwnersByHours: [])
  }

  @Test func safeModeSaysNothingAboutReadings() {
    let line = OledCareCardCopy.measurementLine(
      hours: "12 hours", summary: summary(.measured, hottestRelative: 3.2),
      safeMode: true, grantPresent: true)
    // Not "hottest area": the pane-level Safe Mode note owns the reason, and
    // repeating a figure here would put a present-tense reading on a session
    // that has taken none.
    #expect(line == "12 hours")
  }

  @Test func aMissingGrantOutranksTheStoredConfidence() {
    let line = OledCareCardCopy.measurementLine(
      hours: "12 hours", summary: summary(.measured, hottestRelative: 3.2),
      safeMode: false, grantPresent: false)
    #expect(line == "12 hours · waiting on Screen Recording")
  }

  /// The one state a missing grant does NOT change: with measuring off there is
  /// no capture to be missing a permission for, so the card says the honest
  /// thing rather than blaming macOS.
  @Test func aMissingGrantIsSilentWhileMeasuringIsOff() {
    let line = OledCareCardCopy.measurementLine(
      hours: "12 hours", summary: summary(.estimated),
      safeMode: false, grantPresent: false)
    #expect(line == "12 hours · brightness not measured")
  }

  @Test func aMeasuredDisplayStatesItsHottestArea() {
    let line = OledCareCardCopy.measurementLine(
      hours: "12 hours", summary: summary(.measured, hottestRelative: 3.24),
      safeMode: false, grantPresent: true)
    #expect(line == "12 hours · hottest area 3.2× average")
  }

  /// `.measured` with no relative figure is reachable (an all-zero map has no
  /// hottest cell), and the card must fall back to the hours rather than draw a
  /// dangling separator.
  @Test func aMeasuredDisplayWithNoFigureSaysOnlyItsHours() {
    let line = OledCareCardCopy.measurementLine(
      hours: "12 hours", summary: summary(.measured),
      safeMode: false, grantPresent: true)
    #expect(line == "12 hours")
  }

  @Test func tooFewReadingsCountsTowardTheThreshold() {
    let line = OledCareCardCopy.measurementLine(
      hours: "1.5 hours", summary: summary(.insufficient, sampleCount: 12),
      safeMode: false, grantPresent: true)
    #expect(
      line
        == "1.5 hours · 12 of \(ExposureAccumulator.minimumSamplesForAnalysis) readings")
  }

  // MARK: - The findings card's gate

  /// `PanelHottestAreaCard` sits above the dimming settings it argues for, and
  /// its gate is the honesty rule for the card: the multiple is the one number
  /// this feature may state, and only a `.measured` history may state it.
  @Test func theHottestAreaCardStatesAMultipleOnlyWhenMeasured() {
    #expect(PanelHottestAreaCard.multiple(summary(.measured, hottestRelative: 3.24)) == "3.2×")
    #expect(PanelHottestAreaCard.multiple(summary(.measured)) == nil)
    #expect(
      PanelHottestAreaCard.multiple(summary(.insufficient, hottestRelative: 3.2, sampleCount: 12))
        == nil)
    #expect(PanelHottestAreaCard.multiple(summary(.estimated, hottestRelative: 3.2)) == nil)
  }
}
