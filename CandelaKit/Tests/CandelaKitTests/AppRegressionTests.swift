import Foundation
import Testing
@testable import CandelaKit

/// The app-behaviour verdicts `candela-probe regress` judges its measurements
/// with. Each one is exercised three ways, because each has three results: a
/// control that did not fire (inconclusive), a control that fired over a wrong
/// measurement (fail), and the measured-healthy case (pass). An invariant never
/// observed failing is not yet a test, so the fail branch comes first.
///
/// The log-line fixtures are transcribed from a real window read on the rig
/// (`/usr/bin/log show --info --debug --style compact`), header line included
/// where it matters, so the parsers are tested against the bytes they will meet.
@Suite("App regression verdicts")
struct AppRegressionTests {
  private typealias PC = PlatformConformance

  private func detail(_ outcome: PC.Outcome) -> String {
    switch outcome {
    case let .pass(text), let .fail(text), let .skip(text), let .inconclusive(text): text
    }
  }

  private func isPass(_ outcome: PC.Outcome) -> Bool {
    if case .pass = outcome { return true }
    return false
  }

  private func isFail(_ outcome: PC.Outcome) -> Bool {
    if case .fail = outcome { return true }
    return false
  }

  private func isInconclusive(_ outcome: PC.Outcome) -> Bool {
    if case .inconclusive = outcome { return true }
    return false
  }

  // MARK: - The log window's own control

  @Test func aZeroLineWindowIsABrokenQueryRatherThanAQuietApp() {
    let outcome = AppRegression.logWindowControl(lineCount: 0)
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("zero lines"))
  }

  @Test func aNonEmptyWindowPassesAndCountsItsLines() {
    let outcome = AppRegression.logWindowControl(lineCount: 638)
    #expect(isPass(outcome))
    #expect(detail(outcome).contains("638"))
  }

  // MARK: - Reading DDC writes out of a window

  private static let writeLines = [
    "Timestamp               Ty Process[PID:TID]",
    "2026-08-11 17:15:22.031 Df Candela[80328:9875ec] [com.rydersel.Candela:path] sync fan-out delta=-0.0306 from=1 to=3",
    "2026-08-11 17:15:22.033 Df Candela[80328:998b3a] [com.rydersel.Candela:dragperf] ddc.write.start value=89",
    "2026-08-11 17:15:22.055 Df Candela[80328:998b3a] [com.rydersel.Candela:dragperf] ddc.write.end value=0 ok=true",
    "2026-08-11 17:15:22.057 Df Candela[80328:99dfc5] [com.rydersel.Candela:dragperf] ddc.write.end value=37 ok=true",
    "2026-08-11 17:15:22.061 Df Candela[80328:99dfc5] [com.rydersel.Candela:dragperf] ddc.write.end value=93 ok=false",
  ]

  @Test func onlyAcknowledgedWriteEndLinesYieldValues() {
    let values = AppRegression.ddcWriteValues(fromLogLines: Self.writeLines)
    // The start line, the fan-out line, the header and the failed write all
    // drop out: a write the panel did not acknowledge is not evidence of a
    // write landing, and a start line is not evidence of one completing.
    #expect(values == [0, 37])
  }

  @Test func aWindowWithNoWritesYieldsNothing() {
    #expect(AppRegression.ddcWriteValues(fromLogLines: [Self.writeLines[0], Self.writeLines[1]]).isEmpty)
  }

  @Test func multiDigitValuesSurviveTheParse() {
    let line = "2026-08-11 17:15:22.055 Df Candela[1:2] [com.rydersel.Candela:dragperf] ddc.write.end value=100 ok=true"
    #expect(AppRegression.ddcWriteValues(fromLogLines: [line]) == [100])
  }

  // MARK: - D28, both directions (the Session 3 numbers)

  @Test func aDeadFloorWriteMakesTheGammaReadingsMeanNothing() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: false,
      gammaAfterOff: 1.0, ddcValueAfterOff: 37,
      gammaAfterOn: 0.7875, ddcValueAfterOn: 0
    )
    #expect(isInconclusive(outcome))
    #expect(detail(outcome).contains("floor"))
  }

  @Test func aGammaThatNeverReleasesIsTheD28Failure() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 0.7875, ddcValueAfterOff: 37,
      gammaAfterOn: 0.7875, ddcValueAfterOn: 0
    )
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("0.7875"))
  }

  @Test func anAbsentWriteAfterTheToggleIsTheFailureTheRuleExistsFor() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValueAfterOff: nil,
      gammaAfterOn: 0.7875, ddcValueAfterOn: 0
    )
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("no DDC write"))
  }

  @Test func theWrongDDCValueAfterTheToggleFails() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValueAfterOff: 12,
      gammaAfterOn: 0.7875, ddcValueAfterOn: 0
    )
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("12"))
  }

  @Test func aFloorThatDoesNotComeBackFails() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValueAfterOff: 37,
      gammaAfterOn: 1.0, ddcValueAfterOn: 0
    )
    #expect(isFail(outcome))
  }

  @Test func theSessionThreeNumbersPass() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValueAfterOff: 37,
      gammaAfterOn: 0.7875, ddcValueAfterOn: 0
    )
    #expect(isPass(outcome))
  }

  @Test func gammaIsJudgedWithinItsToleranceAndNotBeyondIt() {
    // A gamma read is a float table entry, so the comparison has to be a
    // tolerance; the tolerance must still be tight enough to reject a real move.
    let inside = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875 + AppRegression.combinedGammaTolerance / 2, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValueAfterOff: 37,
      gammaAfterOn: 0.7875, ddcValueAfterOn: 0
    )
    #expect(isPass(inside))
    let outside = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875 + AppRegression.combinedGammaTolerance * 4, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValueAfterOff: 37,
      gammaAfterOn: 0.7875, ddcValueAfterOn: 0
    )
    #expect(isFail(outside))
  }

  // MARK: - The sync fan-out

  @Test func aNoisyPreWindowContaminatesTheFanOutMeasurement() {
    let outcome = AppRegression.fanOutVerdict(
      preWindowFanOuts: 4, fanOutLinesFromSource: 9, ddcWrites: 9)
    #expect(isInconclusive(outcome))
    #expect(detail(outcome).contains("ambient"))
  }

  @Test func aBuiltInMoveThatFansOutToNothingFails() {
    let outcome = AppRegression.fanOutVerdict(
      preWindowFanOuts: 0, fanOutLinesFromSource: 0, ddcWrites: 0)
    #expect(isFail(outcome))
  }

  @Test func aFanOutThatReachesNoPanelFails() {
    let outcome = AppRegression.fanOutVerdict(
      preWindowFanOuts: 0, fanOutLinesFromSource: 3, ddcWrites: 0)
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("DDC"))
  }

  @Test func aCleanWindowWithFanOutAndWritesPasses() {
    let outcome = AppRegression.fanOutVerdict(
      preWindowFanOuts: 0, fanOutLinesFromSource: 3, ddcWrites: 2)
    #expect(isPass(outcome))
  }

  // MARK: - D29, proven by outcome

  @Test func withoutTheMuteControlTheUnmuteProvesNothing() {
    let outcome = AppRegression.muteStrandVerdict(
      muteWriteSeen: false, unmuteWriteSeen: true, mutedAfter: false)
    #expect(isInconclusive(outcome))
  }

  @Test func aDisableThatFiresNoUnmuteIsTheStrandingFailure() {
    let outcome = AppRegression.muteStrandVerdict(
      muteWriteSeen: true, unmuteWriteSeen: false, mutedAfter: true)
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("unmute"))
  }

  @Test func anUnreadableMutedPrefIsInconclusiveRatherThanGreen() {
    let outcome = AppRegression.muteStrandVerdict(
      muteWriteSeen: true, unmuteWriteSeen: true, mutedAfter: nil)
    #expect(isInconclusive(outcome))
  }

  @Test func anUnmuteWriteThatLeavesThePrefMutedFails() {
    let outcome = AppRegression.muteStrandVerdict(
      muteWriteSeen: true, unmuteWriteSeen: true, mutedAfter: true)
    #expect(isFail(outcome))
  }

  @Test func theOrderingPassesByOutcomeAndNeverClaimsAudibility() {
    let outcome = AppRegression.muteStrandVerdict(
      muteWriteSeen: true, unmuteWriteSeen: true, mutedAfter: false)
    #expect(isPass(outcome))
    // The half this hardware cannot answer has to be said out loud in the
    // record, never quietly folded into the pass.
    #expect(detail(outcome).contains("not verifiable on this hardware"))
  }

  // MARK: - The quiet wake

  @Test func anIncompleteIntakeTripleIsInconclusive() {
    let outcome = AppRegression.wakeVerdict(
      sleepIntakeSeen: true, wakeIntakeSeen: false, quietWindowSeen: true, ddcWritesAfterWake: 0)
    #expect(isInconclusive(outcome))
    #expect(detail(outcome).contains("wake intake"))
  }

  @Test func aWriteBurstAfterWakeFails() {
    let outcome = AppRegression.wakeVerdict(
      sleepIntakeSeen: true, wakeIntakeSeen: true, quietWindowSeen: true, ddcWritesAfterWake: 6)
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("6"))
  }

  @Test func theQuietWakePasses() {
    let outcome = AppRegression.wakeVerdict(
      sleepIntakeSeen: true, wakeIntakeSeen: true, quietWindowSeen: true, ddcWritesAfterWake: 0)
    #expect(isPass(outcome))
  }

  // MARK: - D24 through the panel dump

  private static let magRow =
    "2026-08-17 11:02:03.100 Df Candela[9:1] [com.rydersel.Candela:panel] panel.row display=\"MAG 341C OLED\" volumeSlider=shown volumeEnabled=yes volumeSupport=unknown"
  private static let dellRow =
    "2026-08-17 11:02:03.101 Df Candela[9:1] [com.rydersel.Candela:panel] panel.row display=\"DELL U2725QE\" volumeSlider=shown volumeEnabled=no volumeSupport=unsupported volumeReason=\"This display lists no volume command.\""

  @Test func aControlWindowThatIsNotEmptyMakesTheDumpUnreadable() {
    let outcome = AppRegression.panelDumpVerdict(
      dumpLines: [Self.magRow, Self.dellRow], noVarDumpLineCount: 2,
      magTitleFragment: "MAG 341C", dellTitleFragment: "U2725QE")
    #expect(isInconclusive(outcome))
    #expect(detail(outcome).contains("control"))
  }

  @Test func noDumpLinesAtAllIsInconclusive() {
    let outcome = AppRegression.panelDumpVerdict(
      dumpLines: [], noVarDumpLineCount: 0,
      magTitleFragment: "MAG 341C", dellTitleFragment: "U2725QE")
    #expect(isInconclusive(outcome))
  }

  @Test func aGreyedSliderOnTheWriteOnlyPanelFails() {
    // D24 greys on the monitor's own denial. The write-only panel answers no
    // capabilities at all, so its verdict is unknown and its slider stays
    // enabled; greying it would be the app inventing a denial.
    let greyedMAG = Self.magRow
      .replacingOccurrences(of: "volumeEnabled=yes", with: "volumeEnabled=no")
    let outcome = AppRegression.panelDumpVerdict(
      dumpLines: [greyedMAG, Self.dellRow], noVarDumpLineCount: 0,
      magTitleFragment: "MAG 341C", dellTitleFragment: "U2725QE")
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("volumeEnabled=yes"))
  }

  @Test func aMissingRowFails() {
    let outcome = AppRegression.panelDumpVerdict(
      dumpLines: [Self.magRow], noVarDumpLineCount: 0,
      magTitleFragment: "MAG 341C", dellTitleFragment: "U2725QE")
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("U2725QE"))
  }

  @Test func aDenyingPanelWithoutItsOwnReasonFails() {
    let reasonless = Self.dellRow
      .replacingOccurrences(
        of: " volumeReason=\"This display lists no volume command.\"", with: "")
    let outcome = AppRegression.panelDumpVerdict(
      dumpLines: [Self.magRow, reasonless], noVarDumpLineCount: 0,
      magTitleFragment: "MAG 341C", dellTitleFragment: "U2725QE")
    #expect(isFail(outcome))
  }

  @Test func theMeasuredD24PairPasses() {
    let outcome = AppRegression.panelDumpVerdict(
      dumpLines: [Self.magRow, Self.dellRow], noVarDumpLineCount: 0,
      magTitleFragment: "MAG 341C", dellTitleFragment: "U2725QE")
    #expect(isPass(outcome))
  }
}
