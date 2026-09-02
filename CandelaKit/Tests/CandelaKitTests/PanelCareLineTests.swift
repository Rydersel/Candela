import Foundation
import Testing

@testable import CandelaKit

@Suite("Panel care line")
struct PanelCareLineTests {
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

  private func line(
    enrolled: Bool, hours: Double, summary: PanelHealthSummary?, safeMode: Bool = false
  ) -> String? {
    PanelCareLine.text(enrolled: enrolled, hours: hours, summary: summary, safeMode: safeMode)
  }

  @Test func anEnrolledMeasuredDisplaySaysAllThree() {
    let line = line(
      enrolled: true, hours: 178.4, summary: summary(.measured, hottestRelative: 2.49))
    #expect(line == "OLED Care on · 178 h · hottest area 2.5×")
  }

  /// Hours banked before the pref went off stay: they are a fact about the
  /// panel. The claim goes, and so does the reading.
  @Test func anUnenrolledDisplayKeepsItsHoursAndNothingElse() {
    let line = line(
      enrolled: false, hours: 178.4, summary: summary(.measured, hottestRelative: 2.49))
    #expect(line == "178 h")
  }

  /// Absence is the signal; "off" under every display would be nagging.
  @Test func theLineNeverSaysOff() {
    for hours in [0.0, 0.4, 178.4] {
      let line = line(enrolled: false, hours: hours, summary: summary(.estimated))
      #expect(line?.localizedCaseInsensitiveContains("off") != true)
    }
  }

  @Test func anEnrolledDisplayWithNoReadingIsOnAndItsHours() {
    #expect(line(enrolled: true, hours: 178.4, summary: nil) == "OLED Care on · 178 h")
    // `.measured` with no figure is reachable: an all-zero map has no hottest cell.
    #expect(
      line(enrolled: true, hours: 178.4, summary: summary(.measured))
        == "OLED Care on · 178 h")
  }

  /// The Health card counts the readings toward the threshold; the panel says
  /// nothing about them.
  @Test func tooFewReadingsDropTheHottestSegmentWithoutCountingThem() {
    let line = line(
      enrolled: true, hours: 178.4,
      summary: summary(.insufficient, hottestRelative: 2.49, sampleCount: 12))
    #expect(line == "OLED Care on · 178 h")
  }

  /// The Health card says "brightness not measured"; the panel drops the segment.
  @Test func anEstimatedSummaryDropsTheHottestSegmentWithoutExplaining() {
    let line = line(
      enrolled: true, hours: 178.4, summary: summary(.estimated, hottestRelative: 2.49))
    #expect(line == "OLED Care on · 178 h")
  }

  /// Safe Mode first, as in the summary cards: the care loop is not running, so
  /// nothing produces "on" or a present-tense reading.
  @Test func safeModeIsHoursOnly() {
    let measured = summary(.measured, hottestRelative: 2.49)
    #expect(line(enrolled: true, hours: 178.4, summary: measured, safeMode: true) == "178 h")
    #expect(line(enrolled: true, hours: 0, summary: measured, safeMode: true) == nil)
  }

  @Test func theFirstHourReadsUnderOneHour() {
    #expect(line(enrolled: true, hours: 0.4, summary: nil) == "OLED Care on · under 1 h")
  }

  @Test func aFreshlyEnrolledDisplaySaysOnlyThatCareIsOn() {
    #expect(line(enrolled: true, hours: 0, summary: summary(.insufficient)) == "OLED Care on")
  }

  /// Nil, not an empty string: the header keeps its one-line height.
  @Test func nothingToSayIsNil() {
    #expect(line(enrolled: false, hours: 0, summary: nil) == nil)
    #expect(
      line(enrolled: false, hours: 0, summary: summary(.measured, hottestRelative: 2.49)) == nil)
    #expect(line(enrolled: false, hours: .nan, summary: nil) == nil)
    #expect(line(enrolled: false, hours: -3, summary: nil) == nil)
  }

  /// Same formatter as the Health card, so one reading cannot round two ways
  /// on two surfaces.
  @Test func theFigureIsTheHealthCardsOwn() {
    let line = line(enrolled: true, hours: 12, summary: summary(.measured, hottestRelative: 3.24))
    #expect(line == "OLED Care on · 12 h · hottest area 3.2×")
    #expect(line?.hasSuffix("hottest area \(PanelHealthCopy.multiple(3.24)!)") == true)
  }

  /// The same middle dot as the panel's size line, and no em dash anywhere.
  @Test func theSeparatorIsThePanelsMiddleDot() {
    #expect(PanelCareLine.separator == " \u{00B7} ")
    let produced = [
      line(enrolled: true, hours: 178.4, summary: summary(.measured, hottestRelative: 2.49)),
      line(enrolled: true, hours: 0.4, summary: nil),
      line(enrolled: false, hours: 5, summary: nil),
      line(enrolled: true, hours: 5, summary: nil, safeMode: true),
    ].compactMap { $0 }
    #expect(produced.count == 4)
    #expect(produced.allSatisfy { !$0.contains("—") })
  }
}
