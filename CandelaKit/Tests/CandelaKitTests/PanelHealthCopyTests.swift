import Foundation
import Testing

@testable import CandelaKit

@Suite("Panel health copy")
struct PanelHealthCopyTests {

  // MARK: - Hours

  /// The defect this type exists to remove: two surfaces, one quantity, two
  /// answers. 0.4 hours read "0.4 hours" in the pane and "24 minutes" in the
  /// leaderboard. There is now one answer, and it is the minutes one, because
  /// the sub-hour case is what both originals were trying to get right.
  @Test func subHourDurationsReadInMinutesEverywhere() {
    #expect(PanelHealthCopy.hours(0.4) == "24 minutes")
    #expect(PanelHealthCopy.hours(0.4, zeroPhrase: "none yet") == "24 minutes")
  }

  @Test func aFreshCounterNeverReadsAsStopped() {
    // The whole first hour of a newly enrolled display.
    #expect(PanelHealthCopy.hours(0.02) == "1 minute")
    #expect(PanelHealthCopy.hours(0.5) == "30 minutes")
    #expect(PanelHealthCopy.hours(0.999) == "60 minutes")
  }

  @Test func aDurationTooSmallToNameInMinutesSaysSo() {
    #expect(PanelHealthCopy.hours(0.001) == "under a minute")
  }

  @Test func oneDecimalBelowTenHoursAndWholeHoursAbove() {
    #expect(PanelHealthCopy.hours(1.0) == "1.0 hours")
    #expect(PanelHealthCopy.hours(9.94) == "9.9 hours")
    #expect(PanelHealthCopy.hours(10.4) == "10 hours")
    #expect(PanelHealthCopy.hours(341.6) == "342 hours")
  }

  /// The only difference the two call sites are allowed: a leaderboard row that
  /// does not exist yet is "none yet", a lifetime counter is "0 hours".
  @Test func theZeroPhraseIsTheCallersToChoose() {
    #expect(PanelHealthCopy.hours(0) == "0 hours")
    #expect(PanelHealthCopy.hours(0, zeroPhrase: "none yet") == "none yet")
  }

  @Test func nonFiniteAndNegativeDurationsTakeTheZeroPhrase() {
    #expect(PanelHealthCopy.hours(.nan) == "0 hours")
    #expect(PanelHealthCopy.hours(.infinity) == "0 hours")
    #expect(PanelHealthCopy.hours(-5) == "0 hours")
  }

  /// Not reachable from a real counter, but the singular is one comparison away
  /// from reading "1 hours" and nothing else would catch it.
  @Test func exactlyOneWholeHourIsSingular() {
    #expect(PanelHealthCopy.hours(1.4) == "1.4 hours")
    #expect(PanelHealthCopy.hours(10.0) == "10 hours")
  }

  // MARK: - Compact hours

  /// From ten hours up the number is the long form's own, rounded the same way.
  @Test func compactHoursAgreeWithTheLongFormAboveTenHours() {
    #expect(PanelHealthCopy.compactHours(341.6) == "342 h")
    #expect(PanelHealthCopy.hours(341.6) == "342 hours")
    #expect(PanelHealthCopy.compactHours(178.4) == "178 h")
    #expect(PanelHealthCopy.compactHours(10.4) == "10 h")
  }

  @Test func compactHoursAreWholeHoursFromOneUp() {
    #expect(PanelHealthCopy.compactHours(1.0) == "1 h")
    #expect(PanelHealthCopy.compactHours(1.4) == "1 h")
    #expect(PanelHealthCopy.compactHours(1.6) == "2 h")
  }

  /// A panel row has no room for minutes.
  @Test func compactHoursUnderOneHourSaySo() {
    #expect(PanelHealthCopy.compactHours(0.999) == "under 1 h")
    #expect(PanelHealthCopy.compactHours(0.4) == "under 1 h")
    #expect(PanelHealthCopy.compactHours(0.001) == "under 1 h")
  }

  /// Nil rather than "0 h": the caller drops the segment.
  @Test func compactHoursWithNothingCountedAreNil() {
    #expect(PanelHealthCopy.compactHours(0) == nil)
    #expect(PanelHealthCopy.compactHours(-5) == nil)
    #expect(PanelHealthCopy.compactHours(.nan) == nil)
    #expect(PanelHealthCopy.compactHours(.infinity) == nil)
  }

  // MARK: - Multiples

  @Test func aMultipleIsOneDecimalWithATimesSign() {
    #expect(PanelHealthCopy.multiple(3.24) == "3.2×")
    #expect(PanelHealthCopy.multiple(1.0) == "1.0×")
  }

  /// Answers nil rather than an em dash. The view used `return "—"` as a null
  /// glyph, which violates the no-em-dash rule and reads as nothing at all to
  /// VoiceOver; the caller now writes words or drops the row.
  @Test func anUnavailableMultipleIsNilNotAGlyph() {
    #expect(PanelHealthCopy.multiple(.nan) == nil)
    #expect(PanelHealthCopy.multiple(.infinity) == nil)
    #expect(PanelHealthCopy.multiple(0) == nil)
    #expect(PanelHealthCopy.multiple(-1) == nil)
  }

  // MARK: - Regions

  @Test func theFourCornersAreNamedAsCorners() {
    #expect(PanelHealthCopy.region(cell: 0) == "toward the top, on the left")
    #expect(PanelHealthCopy.region(cell: PanelGrid.cols - 1) == "toward the top, on the right")
    #expect(
      PanelHealthCopy.region(cell: (PanelGrid.rows - 1) * PanelGrid.cols)
        == "toward the bottom, on the left")
    #expect(
      PanelHealthCopy.region(cell: PanelGrid.cellCount - 1)
        == "toward the bottom, on the right")
  }

  @Test func theCentreIsNamedAsTheCentre() {
    let middle = (PanelGrid.rows / 2) * PanelGrid.cols + PanelGrid.cols / 2
    #expect(PanelHealthCopy.region(cell: middle) == "across the middle, in the center")
  }

  /// The thirds split must not depend on `PanelGrid` happening to be 24×10:
  /// this reimplemented `ExposureMap`'s indexing by comment, and a grid change
  /// would silently re-map every region name.
  @Test func theThirdsSplitFollowsTheGridItIsGiven() {
    #expect(
      PanelHealthCopy.region(cell: 0, cols: 3, rows: 3) == "toward the top, on the left")
    #expect(
      PanelHealthCopy.region(cell: 4, cols: 3, rows: 3) == "across the middle, in the center")
    #expect(
      PanelHealthCopy.region(cell: 8, cols: 3, rows: 3) == "toward the bottom, on the right")
  }

  @Test func anOutOfRangeCellHasNoRegion() {
    #expect(PanelHealthCopy.region(cell: -1) == nil)
    #expect(PanelHealthCopy.region(cell: PanelGrid.cellCount) == nil)
    #expect(PanelHealthCopy.region(cell: 0, cols: 0, rows: 0) == nil)
  }

  // MARK: - The rule these all serve

  /// House rule: no em dashes in user-visible copy. Every string this type can
  /// produce is user-visible, so the rule is checkable here instead of by
  /// grepping the views.
  @Test func noProducedStringContainsAnEmDash() {
    var produced: [String] = [
      PanelHealthCopy.hours(0), PanelHealthCopy.hours(0.001), PanelHealthCopy.hours(0.5),
      PanelHealthCopy.hours(1), PanelHealthCopy.hours(5.5), PanelHealthCopy.hours(500),
      PanelHealthCopy.hours(0, zeroPhrase: "none yet"),
    ]
    produced += (0..<PanelGrid.cellCount).compactMap { PanelHealthCopy.region(cell: $0) }
    produced += [1.0, 3.25, 99.9].compactMap { PanelHealthCopy.multiple($0) }
    produced += [0.5, 1, 178.4].compactMap { PanelHealthCopy.compactHours($0) }
    #expect(produced.allSatisfy { !$0.contains("—") })
  }
}
