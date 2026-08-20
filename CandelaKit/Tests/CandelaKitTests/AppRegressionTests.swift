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

  // MARK: - R-B's third state: a control that fired over an inconclusive verdict

  private static let controlSentence =
    "a quiet 3 s pre-window carried no DDC writes, so the writes below are the posted keys"

  @Test func aControlThatDidNotFireIsInconclusiveAndRecordsAFailedControl() {
    let check = AppRegression.controlledCheck(
      name: "regress.instrument.keys", controlFired: false, control: "the log query is unproven"
    ) { .pass("never consulted") }
    #expect(isInconclusive(check.outcome))
    #expect(detail(check.outcome) == "the log query is unproven")
    #expect(check.control == .failed)
  }

  @Test func aFiredControlSurvivesAnInconclusiveVerdict() {
    // The whole point of the third state: the control demonstrably fired and
    // the measurement still could not be judged. Demoting the control here
    // both misreports the run and drops the evidence sentence, which is what
    // the operator needs to tell "the instrument is dead" from "the instrument
    // worked and the answer was unreadable".
    let check = AppRegression.controlledCheck(
      name: "regress.instrument.keys", controlFired: true, control: Self.controlSentence
    ) { .inconclusive("the targeting mode was not the pointer") }
    #expect(isInconclusive(check.outcome))
    #expect(check.control == .fired)
    #expect(detail(check.outcome).contains("the targeting mode was not the pointer"))
    #expect(detail(check.outcome).contains(Self.controlSentence))
  }

  @Test func aFiredControlSurvivesAnInconclusiveVerdictIntoTheRunRecord() {
    let report = PC.Report(platform: "test", checks: [
      AppRegression.controlledCheck(
        name: "regress.instrument.keys", controlFired: true, control: Self.controlSentence
      ) { .inconclusive("the targeting mode was not the pointer") },
    ])
    let record = report.runRecord(label: "regress", commit: "abc123", timestamp: Date())
    #expect(record.checks.count == 1)
    #expect(record.checks[0].outcome == "inconclusive")
    #expect(record.checks[0].control == "fired")
    #expect(record.inconclusive == 1)
  }

  @Test func aFiredControlAnnotatesAPassAndAFailAlike() {
    let passed = AppRegression.controlledCheck(
      name: "c", controlFired: true, control: Self.controlSentence) { .pass("measured") }
    #expect(isPass(passed.outcome))
    #expect(passed.control == .fired)
    #expect(detail(passed.outcome).contains(Self.controlSentence))

    let failed = AppRegression.controlledCheck(
      name: "c", controlFired: true, control: Self.controlSentence) { .fail("measured wrong") }
    #expect(isFail(failed.outcome))
    #expect(failed.control == .fired)
    #expect(detail(failed.outcome).contains(Self.controlSentence))
  }

  @Test func theVerdictIsNotConsultedWhenTheControlDidNotFire() {
    var consulted = false
    _ = AppRegression.controlledCheck(
      name: "c", controlFired: false, control: "no control"
    ) {
      consulted = true
      return .pass("should never run")
    }
    #expect(!consulted)
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
    #expect(detail(outcome).contains("\(AppRegression.combinedCrossoverDDCValue)"))
  }

  @Test func aPositiveWriteThatIsNotThisPanelsExpectedValueFails() {
    // The up leg anchors on a VALUE, the way the released leg anchors on 37.
    // Accepting any nonzero write would let another panel's re-apply stand in
    // for the register move this check exists to observe: 93 and 64 are both
    // positive and neither is what this panel writes at the crossover point.
    let outcome = AppRegression.combinedCrossoverVerdict(
      upWriteValues: [93, 0, 64], gammaAtTop: 1.0,
      downWriteValues: [87, 0], gammaBackAtFloor: 0.7875
    )
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("93"))
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
    // Presence, not exclusivity, on both legs: the expected value is in the
    // window alongside whatever else wrote, and the walk up carries the
    // intermediate grid points with it.
    let outcome = AppRegression.combinedCrossoverVerdict(
      upWriteValues: [93, 0, 12, 25, 37, AppRegression.combinedCrossoverDDCValue],
      gammaAtTop: 1.0,
      downWriteValues: [87, 0], gammaBackAtFloor: 0.7875
    )
    #expect(isPass(outcome))
  }

  @Test func theCrossoverValueIsTheDimmingMathsAnswerAtTheCrossoverBrightness() {
    // The constant is derived rather than transcribed, so the derivation is
    // pinned, and it is pinned through the SAME functions the app writes with
    // rather than through a hand-truncation that happens to agree today. A
    // change to the affine step or to where the truncation falls in
    // `valueToDDC` is then a failing test rather than a rig surprise.
    let split = DimmingMath.combinedSplit(
      value: AppRegression.combinedCrossoverBrightness,
      switching: DimmingMath.switchingValue(fromPoint: 0))
    #expect(split.sw == 1)
    #expect(
      DimmingMath.valueToDDC(
        split.ddc, minDDC: 0, maxDDC: AppRegression.assumedRegisterMaximum)
        == AppRegression.combinedCrossoverDDCValue)
  }

  @Test func theAssumedRegisterMaximumIsTheAppsOwnUntunedFallback() {
    // Couples the constant to the app rather than to a comment. Both
    // derivation pins take the register maximum as given, so a change to it
    // would otherwise leave them green while describing a mapping the app no
    // longer uses.
    //
    // What this binds, exactly: `CommandTuning.effectiveMaxDDC`'s fallback for
    // an untuned command with no read maximum supplied. It does NOT bind
    // `BrightnessController.assumedMaxDDC`, which is private and unreachable
    // from here, and it does not describe the live write path, which always
    // passes a real `readMax` taken from `maxDDCValue`. So it guards the
    // arithmetic premise the 37 and 50 derivations rest on, and the two
    // constants can still be wrong together if the panel's own maximum is not
    // the assumed one. That remains the run-card item.
    let untuned = CommandTuning(
      unavailableDDC: false, minDDCOverride: 0, maxDDCOverride: 0,
      curveIndex: 0, invert: false, remapCodes: [])
    #expect(untuned.effectiveMaxDDC(readMax: nil) == Int(AppRegression.assumedRegisterMaximum))
  }

  @Test func theReleasedValueIsTheSameMappingWithTheWholeRangeOnTheRegister() {
    // Combined dimming off puts the whole stored value on the register, so 37
    // is the same untuned mapping read at the floor brightness. Pinned beside
    // the crossover value because the two constants stand or fall together:
    // both assume a 0 to 100 linear, uninverted brightness command, which is
    // what `ddcTuningGate` refuses to assert through.
    #expect(
      DimmingMath.valueToDDC(
        AppRegression.combinedFloorBrightness, minDDC: 0,
        maxDDC: AppRegression.assumedRegisterMaximum)
        == AppRegression.combinedReleasedDDCValue)
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
      preWindowFanOuts: 4, fanOutLinesFromSource: 9, ddcWrites: 9,
      anyTargetInHardwareZone: true)
    #expect(isInconclusive(outcome))
    #expect(detail(outcome).contains("ambient"))
  }

  @Test func aBuiltInMoveThatFansOutToNothingFails() {
    let outcome = AppRegression.fanOutVerdict(
      preWindowFanOuts: 0, fanOutLinesFromSource: 0, ddcWrites: 0,
      anyTargetInHardwareZone: true)
    #expect(isFail(outcome))
  }

  @Test func aFanOutThatReachesNoPanelFails() {
    let outcome = AppRegression.fanOutVerdict(
      preWindowFanOuts: 0, fanOutLinesFromSource: 3, ddcWrites: 0,
      anyTargetInHardwareZone: true)
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("DDC"))
  }

  @Test func aFanOutIntoTheSoftwareZoneAloneCannotProduceAWrite() {
    // Every DDC panel sitting below its switching value is the state the two
    // combined-dimming checks LEAVE the rig in: a fan-out there computes the
    // register value the panel already holds, the coalescer drops the repeat,
    // and no write can appear whatever the app does. Convicting the app of
    // that is a false failure the run reaches by construction.
    let outcome = AppRegression.fanOutVerdict(
      preWindowFanOuts: 0, fanOutLinesFromSource: 3, ddcWrites: 0,
      anyTargetInHardwareZone: false)
    #expect(isInconclusive(outcome))
    #expect(detail(outcome).contains("switching value"))
  }

  @Test func theSoftwareZoneNeverExcusesAFanOutThatDidNotHappen() {
    // The zone explains an absent WRITE. It says nothing about an absent
    // fan-out line, which is the app failing to fan out at all.
    let outcome = AppRegression.fanOutVerdict(
      preWindowFanOuts: 0, fanOutLinesFromSource: 0, ddcWrites: 0,
      anyTargetInHardwareZone: false)
    #expect(isFail(outcome))
  }

  @Test func aCleanWindowWithFanOutAndWritesPasses() {
    let outcome = AppRegression.fanOutVerdict(
      preWindowFanOuts: 0, fanOutLinesFromSource: 3, ddcWrites: 2,
      anyTargetInHardwareZone: true)
    #expect(isPass(outcome))
  }

  // MARK: - The gamma table is not the only software leg

  @Test func anAbsentAvoidGammaKeyIsTheDefault() {
    #expect(AppRegression.avoidGammaGate(prefValue: nil, persistenceKey: "PK1") == nil)
    #expect(AppRegression.avoidGammaGate(prefValue: " 0 ", persistenceKey: "PK1") == nil)
  }

  @Test func avoidGammaMakesTheSoftwareLegUnreadable() {
    // With it set, the software leg goes to the shade overlay and the gamma
    // table stays at 1.0 at the floor. The DDC control still fires, so the
    // check would run to its verdict and FAIL a healthy app. Rigs arrive in
    // this state: accepting the gamma-interference prompt sets it.
    let reason = AppRegression.avoidGammaGate(prefValue: "1", persistenceKey: "PK1")
    #expect(reason?.contains("avoidGamma.PK1") == true)
    #expect(reason?.contains("overlay") == true)
  }

  // MARK: - The volume availability switch, spelled once

  @Test func theVolumeCommandIdentifierIsComposedAsTheSettingsPaneComposesIt() {
    // The app's composer pins this same string in the app suite. Two spellings
    // of one identifier agree until the day they do not, so both are pinned.
    #expect(
      AppRegression.volumeCommandIdentifier(persistenceKey: "PK1")
        == "unavailableDDC.volume.PK1")
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
      preSleepWrites: 0,
      sleepIntakeSeen: true, wakeIntakeSeen: false, quietWindowSeen: true, ddcWritesAfterWake: 0)
    #expect(isInconclusive(outcome))
    #expect(detail(outcome).contains("wake intake"))
  }

  @Test func aWriteBurstAfterWakeFails() {
    let outcome = AppRegression.wakeVerdict(
      preSleepWrites: 0,
      sleepIntakeSeen: true, wakeIntakeSeen: true, quietWindowSeen: true, ddcWritesAfterWake: 6)
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("6"))
  }

  @Test func aNoisyPreSleepWindowCannotBeChargedToTheWake() {
    // Measured on the rig: seven writes after wake as a descending register
    // ramp, from a run whose driven checks had just finished, against ZERO on
    // the same wake cycle on a quiet rig. The burst is a parked coalescer
    // remainder releasing on the wake refresh, not the restore path.
    let outcome = AppRegression.wakeVerdict(
      preSleepWrites: 12,
      sleepIntakeSeen: true, wakeIntakeSeen: true, quietWindowSeen: true, ddcWritesAfterWake: 7)
    #expect(isInconclusive(outcome))
    #expect(detail(outcome).contains("before the sleep"))
  }

  @Test func aQuietPreSleepWindowStillConvictsAWriteBurst() {
    // The signal this check exists for has to survive the contamination gate:
    // a quiet run in and a burst out is still the regression.
    let outcome = AppRegression.wakeVerdict(
      preSleepWrites: 0,
      sleepIntakeSeen: true, wakeIntakeSeen: true, quietWindowSeen: true, ddcWritesAfterWake: 7)
    #expect(isFail(outcome))
    #expect(detail(outcome).contains("7"))
  }

  @Test func theQuietWakePasses() {
    let outcome = AppRegression.wakeVerdict(
      preSleepWrites: 0,
      sleepIntakeSeen: true, wakeIntakeSeen: true, quietWindowSeen: true, ddcWritesAfterWake: 0)
    #expect(isPass(outcome))
  }

  // MARK: - Reading a sleep/wake window

  private static let sleepLine =
    "2026-08-18 09:12:01.001 Df Candela[80328:1] [com.rydersel.Candela:topology] sleep intake: epoch=41"
  private static let wakeLine =
    "2026-08-18 09:12:11.004 Df Candela[80328:2] [com.rydersel.Candela:topology] wake intake"
  private static let quietLine =
    "2026-08-18 09:12:12.010 Df Candela[80328:3] [com.rydersel.Candela:topology] topology quiet window elapsed, signaling refresh"
  private static func writeLine(_ value: Int, ok: Bool = true) -> String {
    "2026-08-18 09:12:13.000 Df Candela[80328:4] [com.rydersel.Candela:dragperf] ddc.write.end value=\(value) ok=\(ok)"
  }

  @Test func aQuietWakeReadsAsTheWholeTripleAndNoWrites() {
    let window = AppRegression.wakeWindow(
      fromLogLines: [Self.sleepLine, Self.wakeLine, Self.quietLine])
    #expect(window == AppRegression.WakeWindow(
      sleepIntakeSeen: true, wakeIntakeSeen: true, quietWindowSeen: true, ddcWritesAfterWake: 0))
  }

  @Test func aWakeIntakeAheadOfTheSleepIntakeIsNotThisRunsWake() {
    // The triple is read IN ORDER: a wake line left over from an earlier sleep
    // is not evidence that the sleep this check drove ever woke.
    let window = AppRegression.wakeWindow(
      fromLogLines: [Self.wakeLine, Self.quietLine, Self.sleepLine])
    #expect(window.sleepIntakeSeen)
    #expect(!window.wakeIntakeSeen)
    #expect(!window.quietWindowSeen)
  }

  @Test func aQuietWindowLineAheadOfTheWakeIsNotTheWakesOwn() {
    let window = AppRegression.wakeWindow(
      fromLogLines: [Self.sleepLine, Self.quietLine, Self.wakeLine])
    #expect(window.wakeIntakeSeen)
    #expect(!window.quietWindowSeen)
  }

  @Test func writesBeforeTheWakeAreNotChargedToIt() {
    let window = AppRegression.wakeWindow(fromLogLines: [
      Self.sleepLine, Self.writeLine(37), Self.wakeLine, Self.quietLine,
    ])
    #expect(window.ddcWritesAfterWake == 0)
  }

  @Test func acknowledgedWritesAfterTheWakeAreCounted() {
    let window = AppRegression.wakeWindow(fromLogLines: [
      Self.sleepLine, Self.wakeLine, Self.writeLine(37), Self.quietLine,
      Self.writeLine(50), Self.writeLine(93, ok: false),
    ])
    // The unacknowledged write drops out here as everywhere: a write the panel
    // did not acknowledge is not evidence of one landing.
    #expect(window.ddcWritesAfterWake == 2)
  }

  @Test func aWindowWithNoWakeAtAllChargesItNoWrites() {
    // There is nothing for a count to be a count of. The verdict reports the
    // missing triple as inconclusive, and a non-zero total here would invite
    // reading that silence as a result.
    let window = AppRegression.wakeWindow(fromLogLines: [Self.sleepLine, Self.writeLine(37)])
    #expect(!window.wakeIntakeSeen)
    #expect(window.ddcWritesAfterWake == 0)
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

  // MARK: - Reading a panel dump out of a window

  /// The bytes the Debug build actually writes: `paneldump=header` once per
  /// dump, then one `paneldump=row` per panel row, at `.info` in the
  /// `PanelDump` category.
  private static let dumpHeader = header(pass: 1)
  private static func header(pass: Int, rows: Int = 2) -> String {
    "2026-08-19 11:02:03.099 If Candela[9:1] [com.rydersel.Candela:PanelDump] paneldump=header pass=\(pass) rows=\(rows) builtIn=hidden externals=2 hiddenExternals=0 safeMode=no prefsRevision=4"
  }

  /// The built-in's row, which carries no volume verdict at all: the panel puts
  /// a name and a brightness slider there, so the dump reports both sliders as
  /// not rendered. It counts towards the header's `rows=` all the same, which
  /// is the difference between counting rows and counting verdicts.
  private static let builtInRow =
    "2026-08-19 11:02:03.100 If Candela[9:1] [com.rydersel.Candela:PanelDump] paneldump=row index=1 kind=builtIn title=\"Color LCD\" key=\"builtin\" displayID=1 brightness=0.500 hdrEngaged=no hdrSupported=no hdrMode=off volumeSlider=notRendered contrastSlider=notRendered"
  private static func dumpRow(
    title: String, volumeSupport: String, muteSupport: String = "unknown",
    volumeEnabled: String = "yes", volumeReason: String = "none"
  ) -> String {
    "2026-08-19 11:02:03.100 If Candela[9:1] [com.rydersel.Candela:PanelDump] paneldump=row index=1 kind=external title=\"\(title)\" key=\"abc\" displayID=3 brightness=0.375 hdrEngaged=no hdrSupported=yes hdrMode=off volumeSlider=shown volumeAvailable=yes hideVolumePref=no volumeEnabled=\(volumeEnabled) volumeSupport=\(volumeSupport) muteSupport=\(muteSupport) volumeReason=\"\(volumeReason)\" volume=0.500 muted=no contrastSlider=hidden contrastAvailable=no showContrastPref=no contrast=0.500"
  }
  private static let unrelatedLine =
    "2026-08-19 11:02:03.098 Df Candela[9:1] [com.rydersel.Candela:ddc] ddc.write.end value=50 ok=true"

  /// The rows the denying panel writes before and after its verdict lands. The
  /// pass=1 row is not a degraded copy of the pass=2 one: it is the app's
  /// honest not-yet-knowing, and it looks exactly like the D24 regression this
  /// check exists to catch.
  private static let dellBeforeVerdict = dumpRow(
    title: "DELL U2725QE", volumeSupport: "unknown")
  private static let dellAfterVerdict = dumpRow(
    title: "DELL U2725QE", volumeSupport: "unsupported", volumeEnabled: "no",
    volumeReason: "This display lists no volume command.")
  private static let magAnyPass = dumpRow(title: "MAG 341C OLED", volumeSupport: "unknown")

  /// One instrumented launch as the rig logs it: the window starts at launch,
  /// so it accumulates BOTH dumps and the older one comes first.
  private static let twoPassWindow = [
    header(pass: 1), magAnyPass, dellBeforeVerdict, unrelatedLine,
    header(pass: 2), magAnyPass, dellAfterVerdict,
  ]

  @Test func theControlCountsHeadersAsDumpOutput() {
    // A launch that emitted a header and no rows is still an instrumented
    // launch. Counting rows alone would read it as a clean control, which is
    // the one measurement this check cannot afford to get wrong.
    let count = AppRegression.panelDumpLines(fromLogLines: [
      Self.dumpHeader, Self.unrelatedLine,
    ]).count
    #expect(count == 1)
  }

  @Test func onlyRowsCarryADisplaysVerdict() {
    let rows = AppRegression.panelDumpRows(fromLogLines: [
      Self.dumpHeader, Self.unrelatedLine,
      Self.dumpRow(title: "MAG 341C OLED", volumeSupport: "unknown"),
      Self.dumpRow(title: "DELL U2725QE", volumeSupport: "unsupported"),
    ])
    #expect(rows.count == 2)
  }

  @Test func theLaunchDumpHasNotLandedAVerdictYet() {
    // pass=1 reports both panels unknown by construction: the capabilities
    // verdict lands asynchronously, so a run that judged the launch dump would
    // convict the denying panel of the app's own not-yet-knowing.
    let landed = AppRegression.panelDumpVerdictLanded(inLogLines: [
      Self.dumpHeader,
      Self.dumpRow(title: "MAG 341C OLED", volumeSupport: "unknown"),
      Self.dumpRow(title: "DELL U2725QE", volumeSupport: "unknown"),
    ])
    #expect(!landed)
  }

  @Test func aMuteVerdictIsNotAVolumeVerdict() {
    // The two fields sit beside each other on the same line, so a parser that
    // reads the line rather than the field lands a wait on the wrong verdict.
    let landed = AppRegression.panelDumpVerdictLanded(inLogLines: [
      Self.dumpRow(title: "DELL U2725QE", volumeSupport: "unknown", muteSupport: "supported"),
    ])
    #expect(!landed)
  }

  @Test func aDenyingPanelIsTheVerdictLanding() {
    let landed = AppRegression.panelDumpVerdictLanded(inLogLines: [
      Self.dumpRow(title: "MAG 341C OLED", volumeSupport: "unknown"),
      Self.dumpRow(title: "DELL U2725QE", volumeSupport: "unsupported"),
    ])
    #expect(landed)
  }

  // MARK: - Which dump in the window gets judged

  @Test func theWholeWindowSelectsTheDenyingPanelsPreVerdictRow() {
    // The defect this segmentation exists for, pinned so it cannot come back.
    // The window accumulates both dumps, so a search for the first line naming
    // the panel finds its pass=1 row, whose slider is enabled on an unknown
    // verdict: the shape of a D24 regression, on a rig where D24 is intact.
    let outcome = AppRegression.panelDumpVerdict(
      dumpLines: AppRegression.panelDumpRows(fromLogLines: Self.twoPassWindow),
      noVarDumpLineCount: 0, magTitleFragment: "MAG 341C", dellTitleFragment: "U2725QE")
    #expect(isFail(outcome))
  }

  @Test func theNewestDumpIsTheOneJudged() {
    let rows = AppRegression.newestPanelDumpRows(fromLogLines: Self.twoPassWindow)
    #expect(rows.count == 2)
    let outcome = AppRegression.panelDumpVerdict(
      dumpLines: rows, noVarDumpLineCount: 0,
      magTitleFragment: "MAG 341C", dellTitleFragment: "U2725QE")
    #expect(isPass(outcome))
  }

  @Test func aLandedVerdictInAnOlderDumpDoesNotEndTheWait() {
    // A later reconfiguration re-dumps, and the app can report unknown again
    // while it re-resolves. Waiting on the window rather than on its newest
    // segment would stop here and then judge rows that are not the ones the
    // wait was satisfied by.
    let window = Self.twoPassWindow + [
      Self.header(pass: 3), Self.magAnyPass, Self.dellBeforeVerdict,
    ]
    #expect(!AppRegression.panelDumpVerdictLanded(inLogLines: window))
  }

  @Test func aHeaderThatArrivedAheadOfItsRowsIsNotYetADump() {
    // The store persists a dump's lines in order but not atomically, so the
    // newest segment can be empty for a beat. Empty is not landed, so the poll
    // keeps waiting rather than judging nothing.
    let window = Self.twoPassWindow + [Self.header(pass: 3)]
    #expect(!AppRegression.panelDumpVerdictLanded(inLogLines: window))
    #expect(AppRegression.newestPanelDumpRows(fromLogLines: window).isEmpty)
  }

  @Test func aHalfFlushedSegmentIsNotLanded() {
    // The rows persist in the order the dump writes them, which is the panel's
    // own title order, so the DENYING panel's row can arrive before the
    // write-only panel's. Its unsupported verdict is exactly what the wait is
    // watching for, so a poll landing in that gap would stop, judge a segment
    // with no MAG row in it, and FAIL a healthy rig for a missing row. The
    // header already says how many rows are coming, so the count is what the
    // wait holds out for.
    let window = [Self.header(pass: 2, rows: 3), Self.dellAfterVerdict]
    #expect(!AppRegression.panelDumpVerdictLanded(inLogLines: window))
  }

  @Test func theCompletedSegmentLands() {
    let window = [
      Self.header(pass: 2, rows: 3), Self.builtInRow, Self.magAnyPass, Self.dellAfterVerdict,
    ]
    #expect(AppRegression.panelDumpVerdictLanded(inLogLines: window))
    // The built-in row carries no verdict of its own and still counts: the
    // header counts ROWS, and a count of verdicts would never reach three.
    #expect(AppRegression.newestPanelDumpRows(fromLogLines: window).count == 3)
  }

  @Test func aWindowThatMissedTheHeaderStillOffersItsRows() {
    // A window that opened mid-dump has one candidate segment and no header to
    // cut it at. Reporting no rows there would turn a readable dump into a
    // silent one.
    let rows = AppRegression.newestPanelDumpRows(fromLogLines: [
      Self.magAnyPass, Self.dellAfterVerdict,
    ])
    #expect(rows.count == 2)
  }

  // MARK: - Comparing two paths to the same file

  #if os(macOS)
    @Test func theTmpAliasNamesTheSameFile() {
      // `ps` reports a process's executable by its RESOLVED path, so a build
      // launched from a path spelled through /tmp comes back spelled through
      // /private/tmp. Compared as strings, a rig that IS in the state its
      // teardown claims reports that it is not. /tmp is a symlink on every
      // macOS, so these two literals are an honest fixture on this platform.
      #expect(AppRegression.sameFile("/tmp/candela/Candela.app", "/private/tmp/candela/Candela.app"))
    }

    @Test func twoDifferentPathsAreStillDifferentFiles() {
      // The other half of the control: a comparison that resolved everything
      // onto one answer would report every relaunch as correct.
      #expect(!AppRegression.sameFile("/tmp/candela/Candela.app", "/tmp/other/Candela.app"))
    }
  #endif

  @Test func aPathIsTheSameFileAsItself() {
    #expect(AppRegression.sameFile("/Applications/Candela.app", "/Applications/Candela.app"))
  }

  // MARK: - The ledger's filename

  private func date(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    return formatter.date(from: iso)!
  }

  @Test func theRecordFilenameIsTheDateInUTCAndSevenOfTheSha() {
    #expect(
      AppRegression.recordFilename(commit: "c1b0b4d4e5f60718", date: date("2026-08-19T23:30:00Z"))
        == "2026-08-19-c1b0b4d.json")
  }

  @Test func theDateIsUTCAndZeroPadded() {
    // The CI leg selects the newest record LEXICALLY. A machine-local date
    // rolls the day over at the wrong moment, and an unpadded month or day
    // sorts "2026-1-5" after "2026-10-05": either way the job reads a record
    // that is not the newest and reports an outstanding count for the wrong run.
    #expect(
      AppRegression.recordFilename(commit: "abcdef1234", date: date("2026-01-05T00:30:00Z"))
        == "2026-01-05-abcdef1.json")
  }

  @Test func aShortShaIsWrittenWhole() {
    #expect(
      AppRegression.recordFilename(commit: "abc", date: date("2026-08-19T12:00:00Z"))
        == "2026-08-19-abc.json")
  }

  @Test func aBlankShaIsNamedRatherThanLeftEmpty() {
    // A filename ending in a bare dash is a record nobody can attribute, and
    // the ledger's drift guard would redden on it without saying why.
    #expect(
      AppRegression.recordFilename(commit: "   ", date: date("2026-08-19T12:00:00Z"))
        == "2026-08-19-unknown.json")
  }
}
