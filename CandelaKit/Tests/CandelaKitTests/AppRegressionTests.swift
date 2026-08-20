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
      gammaAfterOff: 1.0, ddcValuesAfterOff: [37],
      gammaAfterOn: 0.7875, ddcValuesAfterOn: [0],
      storedBrightnessAfter: 0.375
    )
    #expect(isInconclusive(outcome))
    #expect(detail(outcome).contains("floor"))
  }

  @Test func aGammaThatNeverReleasesIsTheD28Failure() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 0.7875, ddcValuesAfterOff: [37],
      gammaAfterOn: 0.7875, ddcValuesAfterOn: [0],
      storedBrightnessAfter: 0.375
    )
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("0.7875"))
  }

  @Test func anAbsentWriteAfterTheToggleIsTheFailureTheRuleExistsFor() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValuesAfterOff: [],
      gammaAfterOn: 0.7875, ddcValuesAfterOn: [0],
      storedBrightnessAfter: 0.375
    )
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("no DDC write"))
  }

  @Test func theWrongDDCValueAfterTheToggleFails() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValuesAfterOff: [12],
      gammaAfterOn: 0.7875, ddcValuesAfterOn: [0],
      storedBrightnessAfter: 0.375
    )
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("12"))
  }

  @Test func anotherPanelsInterleavedWritesDoNotBreakTheAssertion() {
    // The write record carries no display id, so a window tight enough to
    // catch the MAG's write catches the other panel's re-apply too (93 off,
    // 87 on, measured on the rig). The assertion is PRESENCE of the expected
    // value, never exclusivity: judging the last value in the window would
    // convict the app of another panel's behaviour.
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValuesAfterOff: [93, 37],
      gammaAfterOn: 0.7875, ddcValuesAfterOn: [87, 0],
      storedBrightnessAfter: 0.375
    )
    #expect(isPass(outcome))
  }

  @Test func aFloorThatDoesNotComeBackFails() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValuesAfterOff: [37],
      gammaAfterOn: 1.0, ddcValuesAfterOn: [0],
      storedBrightnessAfter: 0.375
    )
    #expect(isFail(outcome))
  }

  @Test func aStoredBrightnessThatMovedUnderTheToggleFails() {
    // The toggle changes how a value is applied, never the value itself. A
    // stored brightness that moved means the toggle drove the panel, which
    // would make the two gamma readings readings of different points.
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValuesAfterOff: [37],
      gammaAfterOn: 0.7875, ddcValuesAfterOn: [0],
      storedBrightnessAfter: 0.4375
    )
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("0.4375"))
  }

  @Test func anUnreadableStoredBrightnessIsInconclusiveRatherThanGreen() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValuesAfterOff: [37],
      gammaAfterOn: 0.7875, ddcValuesAfterOn: [0],
      storedBrightnessAfter: nil
    )
    #expect(isInconclusive(outcome))
  }

  @Test func theSessionThreeNumbersPass() {
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValuesAfterOff: [37],
      gammaAfterOn: 0.7875, ddcValuesAfterOn: [0],
      storedBrightnessAfter: 0.375
    )
    #expect(isPass(outcome))
  }

  @Test func gammaIsJudgedWithinItsToleranceAndNotBeyondIt() {
    // A gamma read is a float table entry, so the comparison has to be a
    // tolerance; the tolerance must still be tight enough to reject a real move.
    let inside = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875 + AppRegression.combinedGammaTolerance / 2, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValuesAfterOff: [37],
      gammaAfterOn: 0.7875, ddcValuesAfterOn: [0],
      storedBrightnessAfter: 0.375
    )
    #expect(isPass(inside))
    let outside = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875 + AppRegression.combinedGammaTolerance * 4, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0, ddcValuesAfterOff: [37],
      gammaAfterOn: 0.7875, ddcValuesAfterOn: [0],
      storedBrightnessAfter: 0.375
    )
    #expect(isFail(outside))
  }

  @Test func theReleasedGammaIsJudgedTighterThanTheFloor() {
    // Released gamma is the identity table's exact 1.0, so it earns a tighter
    // tolerance than the floor, which is a computed float. A reading four
    // released tolerances out is still inside the floor's tolerance, so this
    // fails only if the two really are separate numbers.
    #expect(AppRegression.combinedReleasedGammaTolerance < AppRegression.combinedGammaTolerance)
    let outcome = AppRegression.combinedToggleVerdict(
      gammaAtFloor: 0.7875, ddcFloorWriteSeen: true,
      gammaAfterOff: 1.0 - AppRegression.combinedReleasedGammaTolerance * 4,
      ddcValuesAfterOff: [37],
      gammaAfterOn: 0.7875, ddcValuesAfterOn: [0],
      storedBrightnessAfter: 0.375
    )
    #expect(isFail(outcome))
  }

  // MARK: - The crossover, above and below the switching point

  @Test func anUpDriveThatProducedNoWritesAtAllIsInconclusive() {
    // Zero writes in a drive window is a dead drive path, not a verdict about
    // where the DDC leg picks up: nothing was demonstrated either way.
    let outcome = AppRegression.combinedCrossoverVerdict(
      upWriteValues: [], gammaAtTop: 1.0,
      downWriteValues: [0], gammaBackAtFloor: 0.7875
    )
    #expect(isInconclusive(outcome))
    #expect(detail(outcome).contains("no DDC writes"))
  }

  @Test func aDownDriveThatProducedNoWritesAtAllIsInconclusive() {
    let outcome = AppRegression.combinedCrossoverVerdict(
      upWriteValues: [37], gammaAtTop: 1.0,
      downWriteValues: [], gammaBackAtFloor: 0.7875
    )
    #expect(isInconclusive(outcome))
  }

  @Test func anUpDriveWhoseWritesStayAtTheFloorIsTheCrossoverFailure() {
    // Above the switching point the DDC leg carries the whole value, so a
    // window of nothing but floor writes means it never took over.
    let outcome = AppRegression.combinedCrossoverVerdict(
      upWriteValues: [0, 0, 0], gammaAtTop: 1.0,
      downWriteValues: [0], gammaBackAtFloor: 0.7875
    )
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("switching point"))
  }

  @Test func aGammaStillScaledAtTheTopFails() {
    let outcome = AppRegression.combinedCrossoverVerdict(
      upWriteValues: [64], gammaAtTop: 0.9,
      downWriteValues: [0], gammaBackAtFloor: 0.7875
    )
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("0.9000"))
  }

  @Test func aFloorThatDoesNotComeBackOnTheWayDownFails() {
    let outcome = AppRegression.combinedCrossoverVerdict(
      upWriteValues: [64], gammaAtTop: 1.0,
      downWriteValues: [12], gammaBackAtFloor: 1.0
    )
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("floor"))
  }

  @Test func theCrossoverPassesWithAnotherPanelsWritesInTheWindow() {
    let outcome = AppRegression.combinedCrossoverVerdict(
      upWriteValues: [93, 0, 64], gammaAtTop: 1.0,
      downWriteValues: [87, 0], gammaBackAtFloor: 0.7875
    )
    #expect(isPass(outcome))
  }

  // MARK: - Walking the key grid onto a target

  @Test func aValueBelowTheTargetPressesUpAndAboveItPressesDown() {
    #expect(AppRegression.convergenceStep(current: 0.3125, target: 0.375) == .pressUp)
    #expect(AppRegression.convergenceStep(current: 0.75, target: 0.375) == .pressDown)
  }

  @Test func theTargetIsJudgedWithinAToleranceRatherThanByEquality() {
    // The stored value is read back as text and re-parsed, so a bare equality
    // would loop forever on a value that is the target to every digit that
    // matters.
    #expect(AppRegression.convergenceStep(current: 0.375, target: 0.375) == .arrived)
    #expect(
      AppRegression.convergenceStep(
        current: 0.375 + AppRegression.storedBrightnessTolerance / 2, target: 0.375) == .arrived)
    #expect(
      AppRegression.convergenceStep(
        current: 0.375 + AppRegression.storedBrightnessTolerance * 4, target: 0.375) != .arrived)
  }

  // MARK: - Reading fan-out sources out of a window

  private static let fanOutLines = [
    "Timestamp               Ty Process[PID:TID]",
    "2026-08-11 17:15:22.031 Df Candela[80328:9875ec] [com.rydersel.Candela:path] sync fan-out delta=-0.0306 from=1 to=3",
    "2026-08-11 17:15:22.032 Df Candela[80328:9875ec] [com.rydersel.Candela:path] sync fan-out delta=-0.0306 from=1 to=5",
    "2026-08-11 17:15:22.033 Df Candela[80328:9875ec] [com.rydersel.Candela:path] sync fan-out delta=0.0400 from=10 to=3",
    "2026-08-11 17:15:22.055 Df Candela[80328:998b3a] [com.rydersel.Candela:dragperf] ddc.write.end value=0 ok=true",
  ]

  @Test func everyFanOutLineYieldsItsSourceAndNothingElseDoes() {
    #expect(AppRegression.fanOutSources(fromLogLines: Self.fanOutLines) == [1, 1, 10])
  }

  @Test func aTwoDigitSourceIsNotReadAsItsFirstDigit() {
    // `from=10` and `from=1` differ by one character, so a prefix match would
    // count another display's fan-out as the built-in's and turn a
    // contaminated window into a pass.
    let sources = AppRegression.fanOutSources(fromLogLines: Self.fanOutLines)
    #expect(sources.count { $0 == 1 } == 2)
    #expect(sources.count { $0 == 10 } == 1)
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
