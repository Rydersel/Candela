import Foundation

/// The app-behaviour invariants `candela-probe regress` asserts, as pure
/// verdicts over what the probe's instruments measured.
///
/// The DRIVERS live in the probe, because they shell out to the unified log,
/// the defaults domain, the media-key poster and the accessibility API, none of
/// which a unit test can reach. The JUDGEMENT lives here, because a judgement
/// that only ever runs on the rig is one nobody has watched fail.
///
/// Every verdict splits three ways. A check whose positive control did not fire
/// is `.inconclusive`: nothing was demonstrated, and the app was never observed
/// misbehaving. `.fail` is reserved for a control that fired over a measurement
/// that then came out wrong. A check whose failure mode is silence is not a
/// check.
public enum AppRegression {
  // MARK: - The measured constants the D28 verdict asserts

  /// Session 3's numbers, measured on the write-only ultrawide at stored
  /// brightness 0.375 with combined dimming on. They are this panel's, at that
  /// stored value: the driver converges to it before reading, and a check that
  /// cannot converge reports inconclusive rather than judging some other point.
  public static let combinedFloorGamma = 0.7875
  /// Combined dimming off: the software leg releases entirely and the DDC leg
  /// carries the whole value.
  public static let combinedReleasedGamma = 1.0
  /// A gamma read is a float table entry, so equality is a tolerance. Tight
  /// enough to reject the failure this check exists for (a gamma that never
  /// releases sits 0.2125 away).
  public static let combinedGammaTolerance = 0.0005
  /// Released gamma is the identity table's exact 1.0 rather than a computed
  /// scale, so it is held to a tighter tolerance than the floor: a leg that
  /// released ALMOST all the way is a leg that did not release.
  public static let combinedReleasedGammaTolerance = 0.0001
  public static let combinedFloorDDCValue: UInt16 = 0
  public static let combinedReleasedDDCValue: UInt16 = 37

  /// The register value this panel writes at stored brightness 0.75 with
  /// combined dimming on and the default switching point.
  ///
  /// Derived, not guessed. `DimmingMath.combinedSplit(value: 0.75, switching:
  /// 0.5)` puts the DDC portion at `(0.75 - 0.5) / (1 - 0.5) = 0.5`, and this
  /// panel's register maximum is 100: it answers no capabilities read at all,
  /// so `BrightnessController.assumedMaxDDC` stands, and three independent
  /// readings on the rig agree with it (37 at stored 0.375 with combined
  /// dimming OFF, which is 0.375 x 100 truncated; 87 at 0.9375 with it on,
  /// which is 0.875 x 100 truncated; 100 at 1.0). Half of 100 is exactly 50,
  /// with no rounding to argue about.
  ///
  /// Anchoring the up leg on a VALUE is the point. Accepting any positive
  /// write lets another panel's re-apply stand in for the register move this
  /// check exists to observe. Nothing else should be writing inside that
  /// window, since sync is staged off and no toggle fires, but a check that
  /// would still pass if something were is not asserting what it says.
  public static let combinedCrossoverDDCValue: UInt16 = 50

  /// The register maximum both of the values above were derived against. A
  /// symbol so the derivation's one assumption is not a 100 spelled out in
  /// several places.
  ///
  /// It is an ASSUMPTION about this panel, not a reading of it: the panel
  /// answers no capabilities read, so nothing here has ever seen its real
  /// maximum. The pin beside the derivations ties this to
  /// `CommandTuning.effectiveMaxDDC`'s untuned fallback, which is the same
  /// number by construction; it does not verify that the panel agrees.
  public static let assumedRegisterMaximum: Double = 100

  /// How close a native brightness write has to land to what it asked for
  /// before the read back counts as having achieved it.
  public static let nativeBrightnessLandingTolerance = 0.01

  /// The stored brightness the floor numbers above were measured at, and the
  /// point every driven check converges the panel to before and after it runs,
  /// so each check's precondition is the previous check's end state.
  public static let combinedFloorBrightness = 0.375
  /// Six key steps above the floor point, and above the switching point, where
  /// the DDC leg carries the whole value on its own.
  public static let combinedCrossoverBrightness = 0.75
  /// A stored brightness is written out as text and read back through
  /// `defaults`, so it is compared within a tolerance rather than by equality.
  /// Far below the 1/16 key grid, so two adjacent grid points can never both
  /// count as arrived.
  public static let storedBrightnessTolerance = 0.0005

  // MARK: - Composing a controlled check

  /// The ONE rule for building a check that carries a positive control, kept
  /// here rather than in the driver so a test can watch it fail. In the probe it
  /// drifted: an inconclusive verdict was demoting the control to failed.
  ///
  /// Two states in, three out:
  ///
  /// - **The control did not fire.** The verdict is never consulted, the outcome
  ///   is inconclusive carrying the control's own reason, and the control
  ///   records as failed. Nothing was demonstrated.
  /// - **The control fired.** The control records as FIRED whatever the verdict
  ///   says, inconclusive included, and its evidence sentence is appended to the
  ///   detail. That separates "the instrument is dead" from "the instrument
  ///   worked and the answer could not be read".
  ///
  /// So no path pairs a pass with a failed control, and none reports a control
  /// as failed when it was observed firing.
  public static func controlledCheck(
    name: String, controlFired: Bool, control sentence: String,
    verdict: () -> PlatformConformance.Outcome
  ) -> PlatformConformance.Check {
    guard controlFired else {
      return .init(name: name, outcome: .inconclusive(sentence), control: .failed)
    }
    return .init(
      name: name, outcome: annotating(verdict(), with: "control: \(sentence)"), control: .fired)
  }

  /// Appends a measurement's aside to an outcome that carries a measurement.
  /// A skip's reason names why the check did not run at all, so it takes
  /// nothing; an inconclusive DOES take one, because under a fired control it
  /// is a result rather than an absence.
  public static func annotating(_ outcome: PlatformConformance.Outcome, with note: String)
    -> PlatformConformance.Outcome
  {
    switch outcome {
    case let .pass(detail): .pass("\(detail); \(note)")
    case let .fail(detail): .fail("\(detail); \(note)")
    case let .inconclusive(detail): .inconclusive("\(detail); \(note)")
    case .skip: outcome
    }
  }

  // MARK: - The log window's own control

  /// A window read that returns zero lines is a broken query, never a quiet
  /// app. Stated as a verdict because it has been got wrong in four different
  /// ways on this project: a case-sensitive `CONTAINS` that could not match, a
  /// predicate with no process filter that matched a test run instead, a
  /// category that does not exist, and a marker too short for `strings`.
  public static func logWindowControl(lineCount: Int) -> PlatformConformance.Outcome {
    guard lineCount > 0 else {
      return .fail(
        "the log window returned zero lines; a zero-line window is a broken query, never a quiet app (check the predicate, the process filter and that --info --debug are both set)"
      )
    }
    return .pass("the log window returned \(lineCount) lines")
  }

  // MARK: - D28, both directions

  /// Combined dimming propagates in both directions: the pref change has to
  /// re-run both legs, so turning it off releases the software floor AND sends
  /// the display's real value over DDC, and turning it back on restores both.
  ///
  /// The positive control is the floor write. Without a DDC write observed
  /// while converging to the floor, the drive path (key post, event tap,
  /// transport, log query) is unproven and the gamma numbers are just two
  /// readings of an unknown state.
  /// The DDC halves take every value the window carried rather than one
  /// value. The write record names no display, so a window tight enough to
  /// catch this panel's write catches whatever another panel re-applied in the
  /// same moment; the assertion is that the expected value is PRESENT, never
  /// that it is the only one there.
  public static func combinedToggleVerdict(
    gammaAtFloor: Double, ddcFloorWriteSeen: Bool,
    gammaAfterOff: Double, ddcValuesAfterOff: [UInt16],
    gammaAfterOn: Double, ddcValuesAfterOn: [UInt16],
    storedBrightnessAfter: Double?
  ) -> PlatformConformance.Outcome {
    guard ddcFloorWriteSeen else {
      return .inconclusive(
        "no DDC write was observed while converging to the floor, so the drive path is unproven and the gamma readings mean nothing either way"
      )
    }
    guard let storedBrightnessAfter else {
      return .inconclusive(
        "the panel's stored brightness did not answer after the toggle cycle, so what the two gamma readings were readings OF was never established"
      )
    }

    var failures: [String] = []
    if !within(gammaAtFloor, combinedFloorGamma) {
      failures.append(
        "gamma at the floor reads \(rounded(gammaAtFloor)), expected \(rounded(combinedFloorGamma))")
    }
    if !within(gammaAfterOff, combinedReleasedGamma, tolerance: combinedReleasedGammaTolerance) {
      failures.append(
        "combined dimming off left gamma at \(rounded(gammaAfterOff)), expected \(rounded(combinedReleasedGamma)): the software leg did not release"
      )
    }
    failures += ddcFailure(
      ddcValuesAfterOff, expected: combinedReleasedDDCValue,
      when: "combined dimming was turned off")
    if !within(gammaAfterOn, combinedFloorGamma) {
      failures.append(
        "combined dimming back on left gamma at \(rounded(gammaAfterOn)), expected \(rounded(combinedFloorGamma)): the floor did not come back"
      )
    }
    failures += ddcFailure(
      ddcValuesAfterOn, expected: combinedFloorDDCValue,
      when: "combined dimming was turned back on")
    if abs(storedBrightnessAfter - combinedFloorBrightness) > storedBrightnessTolerance {
      failures.append(
        "the stored brightness reads \(storedBrightnessAfter) after the toggle cycle, expected \(combinedFloorBrightness): the toggle governs how a value is applied and must not move the value itself"
      )
    }

    guard failures.isEmpty else { return .fail(failures.joined(separator: "; ")) }
    return .pass(
      "combined dimming propagates both ways at stored brightness \(combinedFloorBrightness): gamma \(rounded(gammaAtFloor)) with a DDC floor write, \(rounded(gammaAfterOff)) with DDC \(combinedReleasedDDCValue) released, \(rounded(gammaAfterOn)) with DDC \(combinedFloorDDCValue) restored"
    )
  }

  private static func ddcFailure(
    _ values: [UInt16], expected: UInt16, when: String
  ) -> [String] {
    guard !values.isEmpty else {
      return [
        "no DDC write reached the panel after \(when): that is the propagation failure this check exists to catch"
      ]
    }
    guard !values.contains(expected) else { return [] }
    return [
      "the DDC writes after \(when) carried \(list(values)), none of them the expected \(expected)"
    ]
  }

  // MARK: - The crossover, above and below the switching point

  /// Above the switching point the DDC leg carries the whole value on its own:
  /// the software leg releases (gamma back to the identity table) and the
  /// register takes a value above its floor. Stepping back down restores the
  /// floor pair.
  ///
  /// A drive window with no writes at all is the dead-drive case and reports
  /// inconclusive: it says nothing about where the DDC leg picks up, only that
  /// nothing reached the panel. A window that carries writes but not the
  /// expected register value is the real failure, and the two are told apart
  /// here rather than merged.
  public static func combinedCrossoverVerdict(
    upWriteValues: [UInt16], gammaAtTop: Double,
    downWriteValues: [UInt16], gammaBackAtFloor: Double
  ) -> PlatformConformance.Outcome {
    guard !upWriteValues.isEmpty else {
      return .inconclusive(
        "the drive up to \(combinedCrossoverBrightness) carried no DDC writes at all, so the key drive never reached the app and nothing above the switching point was measured"
      )
    }
    guard !downWriteValues.isEmpty else {
      return .inconclusive(
        "the drive back down to \(combinedFloorBrightness) carried no DDC writes at all, so the return leg was never measured"
      )
    }

    var failures: [String] = []
    if !upWriteValues.contains(combinedCrossoverDDCValue) {
      failures.append(
        "the writes on the way up to \(combinedCrossoverBrightness) carried \(list(upWriteValues)) and never \(combinedCrossoverDDCValue), which is what this panel's register holds at that stored brightness: above the switching point the DDC leg carries the whole value, and any other positive value in the window belongs to something else"
      )
    }
    if !within(gammaAtTop, combinedReleasedGamma, tolerance: combinedReleasedGammaTolerance) {
      failures.append(
        "gamma at \(combinedCrossoverBrightness) reads \(rounded(gammaAtTop)), expected \(rounded(combinedReleasedGamma)): the software leg is still scaling above the switching point"
      )
    }
    if !downWriteValues.contains(combinedFloorDDCValue) {
      failures.append(
        "the drive back down to \(combinedFloorBrightness) carried \(list(downWriteValues)) and never the floor value \(combinedFloorDDCValue)"
      )
    }
    if !within(gammaBackAtFloor, combinedFloorGamma) {
      failures.append(
        "gamma back at \(combinedFloorBrightness) reads \(rounded(gammaBackAtFloor)), expected \(rounded(combinedFloorGamma)): the software floor did not come back"
      )
    }

    guard failures.isEmpty else { return .fail(failures.joined(separator: "; ")) }
    return .pass(
      "the crossover holds both ways: at \(combinedCrossoverBrightness) gamma reads \(rounded(gammaAtTop)) with the DDC register above its floor, and back at \(combinedFloorBrightness) gamma reads \(rounded(gammaBackAtFloor)) with a floor write"
    )
  }

  // MARK: - Walking the key grid onto a target

  /// Which media key moves a panel's stored brightness towards a target, or
  /// that it is already there.
  public enum ConvergenceStep: Sendable, Equatable {
    case pressUp
    case pressDown
    case arrived
  }

  /// Stated here rather than in the driver so the arrival tolerance is
  /// red-tested: a bare equality against a value that made a round trip
  /// through `defaults` never arrives, and a drive loop that never arrives
  /// reports a working app as inconclusive.
  public static func convergenceStep(current: Double, target: Double) -> ConvergenceStep {
    guard abs(current - target) > storedBrightnessTolerance else { return .arrived }
    return current < target ? .pressUp : .pressDown
  }

  // MARK: - Where a drive that steps DOWN can be aimed

  /// One media-key press, as the system actually moves brightness: a synthetic
  /// press lands on a 1/16 grid whatever modifiers ride with it [MEASURED].
  public static let keyGridStep = 0.0625

  /// Whether a panel at `stored` still reaches the DDC register after a
  /// one-step DOWNWARD move.
  ///
  /// Not the same question as "is this panel in the hardware zone", and the
  /// difference is a false failure measured on the rig. The zone is
  /// `stored >= switching`, but every drive presses DOWN first, so a panel
  /// sitting exactly ON the switching value crosses into the software zone on
  /// that press: no write, by design, and the press back up restores a register
  /// value the coalescer drops as a repeat. A healthy app then shows zero writes
  /// and the instrument blames the Accessibility grant, the event tap and the
  /// DDC path instead.
  ///
  /// So a drive needs a whole step of headroom rather than a boundary. One step
  /// is enough: the press lands ON the switching value, whose register portion
  /// is zero, a real delta from wherever it started.
  ///
  /// Compared exactly, not within a tolerance. Both sides are dyadic (a 1/16
  /// grid, a default switching value of 1/2), so a panel that arrived by key
  /// press sits on the boundary exactly and a tolerance would only widen the
  /// band this excludes.
  public static func survivesDownStep(stored: Double, switchingValue: Double) -> Bool {
    stored >= switchingValue + keyGridStep
  }

  // MARK: - The gates a driven check reads before it judges anything

  /// nil when the software dimming leg is observable through the gamma table on
  /// this display, otherwise why it is not.
  ///
  /// `avoidGamma` routes the software leg to the shade overlay instead of the
  /// gamma table, so a panel carrying it reads 1.0 at the floor with nothing
  /// wrong. The DDC control still fires, so the check would run all the way to
  /// its verdict and FAIL a healthy app on a gamma number that describes a leg
  /// it is no longer using. It is a state rigs ARRIVE in: accepting the app's
  /// own gamma-interference prompt sets it.
  ///
  /// Absent means default, so an unreadable key is the pass here, as in every
  /// other gate: the constants describe the default configuration and a gate
  /// that refused on silence would refuse on most rigs.
  public static func avoidGammaGate(prefValue: String?, persistenceKey: String) -> String? {
    guard let text = prefValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty, text != "0"
    else { return nil }
    return "avoidGamma.\(persistenceKey) reads \(text), so this panel's software dimming leg runs through the shade overlay rather than the gamma table; the gamma read would sit at 1.0 with the leg working perfectly, and the floor constants describe the gamma leg"
  }

  /// The accessibility identifier, and the on-disk key, of a display's volume
  /// availability switch.
  ///
  /// Composed here rather than in the driver so this spelling is pinned by a
  /// test on this side too. The settings pane composes the same string from
  /// `PrefName` and the command, and the app suite pins that: two spellings of
  /// one identifier agree until the day one of them quietly does not, and the
  /// symptom would be a check that reports a control missing on a rig where it
  /// is on screen.
  public static func volumeCommandIdentifier(persistenceKey: String) -> String {
    "unavailableDDC.volume.\(persistenceKey)"
  }

  // MARK: - The sync fan-out

  /// Brightness sync fans a change on one display out to the others. The
  /// control is a QUIET pre-window: the built-in's ambient auto-brightness
  /// fans out continuously when the room light moves, and fan-out lines from
  /// that source would be read as the ones this check drove.
  ///
  /// `anyTargetInHardwareZone` is whether any panel a fan-out could land on
  /// sits at or above its switching value. Below it, a fan-out computes the
  /// register value the panel already holds, the coalescer drops the repeat,
  /// and the line is logged BEFORE the value is applied: the window then
  /// carries fan-out lines and zero writes on a perfectly healthy app. That is
  /// not a hypothetical state, it is where the two combined-dimming checks
  /// leave the panel, so the zero-write branch softens to inconclusive naming
  /// the zone. It softens that branch and no other: an absent fan-out LINE is
  /// the app failing to fan out at all, which the zone explains nothing about.
  public static func fanOutVerdict(
    preWindowFanOuts: Int, fanOutLinesFromSource: Int, ddcWrites: Int,
    anyTargetInHardwareZone: Bool
  ) -> PlatformConformance.Outcome {
    guard preWindowFanOuts == 0 else {
      return .inconclusive(
        "the pre-window already carried \(preWindowFanOuts) sync fan-out lines; the built-in's ambient sensor is contaminating the measurement, so nothing observed in the drive window is attributable to it"
      )
    }
    guard fanOutLinesFromSource > 0 else {
      return .fail(
        "the source display's brightness moved and no sync fan-out line names it as the source")
    }
    guard ddcWrites > 0 else {
      guard anyTargetInHardwareZone else {
        return .inconclusive(
          "\(fanOutLinesFromSource) sync fan-out lines and no DDC write, with every DDC-capable panel below its switching value: down there a fan-out computes the register value the panel already holds and the coalescer drops the repeat, so no write can appear whatever the app does and an absent one says nothing about sync"
        )
      }
      return .fail(
        "\(fanOutLinesFromSource) sync fan-out lines and not one DDC write: the fan-out never reached a panel"
      )
    }
    return .pass(
      "\(fanOutLinesFromSource) fan-out lines from the source display and \(ddcWrites) DDC writes, on a clean pre-window"
    )
  }

  // MARK: - D29, proven by outcome

  /// The mute strand, by OUTCOME rather than by log order. The write log
  /// carries the value but not the command byte, and pref persistence is not
  /// logged at all, so intra-operation ordering cannot be read from the log.
  /// The outcome separates the two orders anyway: in the wrong one the
  /// availability pref is already false when the unmute runs, the toggle
  /// refuses, and no write fires at all.
  ///
  /// The mute write is the positive control: it proves the volume command
  /// reaches this panel before anything is concluded from the unmute.
  public static func muteStrandVerdict(
    muteWriteSeen: Bool, unmuteWriteSeen: Bool, mutedAfter: Bool?
  ) -> PlatformConformance.Outcome {
    guard muteWriteSeen else {
      return .inconclusive(
        "the mute positive control never fired: no mute write was observed, so the volume command is unproven on this panel and the unmute half means nothing"
      )
    }
    guard unmuteWriteSeen else {
      return .fail(
        "the volume command was disabled and no unmute write fired: the availability pref was already false when the unmute ran, which is the order that strands the panel muted with no way back from inside the app"
      )
    }
    guard let mutedAfter else {
      return .inconclusive(
        "the muted pref did not answer after the unmute, so the achieved state was never read")
    }
    guard !mutedAfter else {
      return .fail("an unmute write fired but the muted pref still reads muted afterwards")
    }
    return .pass(
      "the unmute write fired before the volume command was disabled and the muted pref reads unmuted afterwards; the audible half is not verifiable on this hardware (nothing is connected to the panel's aux jack, and no panel here that answers DDC reads carries a volume command), so this proves the ordering by outcome and claims nothing about sound"
    )
  }

  // MARK: - The quiet wake

  /// Why a wake measurement cannot be charged to the wake path, or nil when it
  /// can.
  ///
  /// A run's own driven checks leave coalescer state parked on the panel, and
  /// the wake refresh releases it: measured on the rig on 2026-08-19 as seven
  /// writes in the 300 ms after the quiet-window line, a descending register
  /// ramp (25, 20, 16, 8, 4, 0) that is a remainder draining rather than a
  /// restore pass. The control that identifies it: the SAME wake cycle on a
  /// quiet rig, with the intake triple proving the window live, carried zero
  /// writes. So a noisy pre-sleep window makes the whole measurement
  /// unattributable, exactly as a noisy pre-window does for the fan-out.
  public static func wakeContaminationReason(preSleepWrites: Int) -> String? {
    guard preSleepWrites > 0 else { return nil }
    return "the 30 s window before the sleep already carried \(preSleepWrites) DDC writes, so the run's own drives had left coalescer state parked on the panel and the wake refresh releases it as a descending ramp: a burst after wake would not be attributable to the restore path. Re-run this check after a quiet interval, or run it before the driven checks"
  }

  /// Wake restores brightness by read resync, not by a burst of writes. The
  /// intake pair plus the quiet-window line is the control triple: without it
  /// the app never saw the sleep or the wake at all, and an absence of writes
  /// afterwards is an absence of everything.
  ///
  /// The premise is measured on both kinds of wake, which is worth stating
  /// because they are different code paths into the same restore: on a panel
  /// sleep and wake when the wake behaviour was first recorded, and again on
  /// 2026-08-19 with `pmset displaysleepnow` against the deployed build, where
  /// a quiet rig carried zero writes across the whole cycle.
  ///
  /// `preSleepWrites` guards ahead of everything else. It is not a control (the
  /// triple is): it is the question of whether this window belongs to the wake
  /// at all, and no later branch means anything until it is answered.
  public static func wakeVerdict(
    preSleepWrites: Int,
    sleepIntakeSeen: Bool, wakeIntakeSeen: Bool, quietWindowSeen: Bool, ddcWritesAfterWake: Int
  ) -> PlatformConformance.Outcome {
    if let reason = wakeContaminationReason(preSleepWrites: preSleepWrites) {
      return .inconclusive(reason)
    }
    var missing: [String] = []
    if !sleepIntakeSeen { missing.append("the sleep intake line") }
    if !wakeIntakeSeen { missing.append("the wake intake line") }
    if !quietWindowSeen { missing.append("the quiet-window line") }
    guard missing.isEmpty else {
      return .inconclusive(
        "the wake path's control triple is incomplete (\(missing.joined(separator: ", ")) never appeared), so an absence of DDC writes proves nothing"
      )
    }
    guard ddcWritesAfterWake == 0 else {
      return .fail(
        "\(ddcWritesAfterWake) DDC writes after wake; values come back by read resync, so a write burst here is the regression"
      )
    }
    return .pass(
      "sleep intake, wake intake and the quiet window all logged, with zero DDC writes after wake")
  }

  /// What one sleep/wake window carried, read in the order the lines appear.
  ///
  /// The window is `log show`'s output, which is chronological, so ORDER is
  /// what separates this run's wake from a leftover one: a wake line ahead of
  /// the sleep line belongs to an earlier sleep, and counting it would let a
  /// window that never woke report the whole control triple.
  public struct WakeWindow: Sendable, Equatable {
    public let sleepIntakeSeen: Bool
    public let wakeIntakeSeen: Bool
    public let quietWindowSeen: Bool
    /// Acknowledged DDC writes recorded after the wake intake line. Zero when
    /// there is no wake to charge them to, because a total with nothing to
    /// anchor it invites reading an absent wake as a quiet one.
    public let ddcWritesAfterWake: Int
  }

  public static func wakeWindow(fromLogLines lines: [String]) -> WakeWindow {
    func index(of marker: String, after start: Int?) -> Int? {
      guard let start else { return nil }
      return lines[start...].firstIndex { $0.contains(marker) }
    }
    let sleepIndex = index(of: "sleep intake: epoch=", after: lines.startIndex)
    let wakeIndex = index(of: "wake intake", after: sleepIndex.map { $0 + 1 })
    let quietIndex = index(of: "topology quiet window elapsed", after: wakeIndex.map { $0 + 1 })
    let afterWake = wakeIndex.map { ddcWriteValues(fromLogLines: Array(lines[($0 + 1)...])).count }
    return WakeWindow(
      sleepIntakeSeen: sleepIndex != nil,
      wakeIntakeSeen: wakeIndex != nil,
      quietWindowSeen: quietIndex != nil,
      ddcWritesAfterWake: afterWake ?? 0
    )
  }

  // MARK: - D24 through the panel dump

  /// A volume slider is greyed only by the monitor's own denial. The
  /// write-only panel answers no capabilities at all, so its verdict is
  /// unknown and its slider stays enabled; the panel whose capabilities parsed
  /// cleanly with no volume command is shown GREYED, never removed, carrying
  /// its own reason.
  ///
  /// The control is the launch WITHOUT the dump variable: it proves the query
  /// can come back empty, before an empty result is read as a panel with no
  /// rows. Whether both panels are attached is the driver's precondition, not
  /// this verdict's: a row missing from a dump that has other rows in it is a
  /// content failure.
  public static func panelDumpVerdict(
    dumpLines: [String], noVarDumpLineCount: Int,
    magTitleFragment: String, dellTitleFragment: String
  ) -> PlatformConformance.Outcome {
    guard noVarDumpLineCount == 0 else {
      return .inconclusive(
        "the control launch without the panel-dump variable still produced \(noVarDumpLineCount) dump lines, so the query cannot come back empty and an empty result would have proven nothing"
      )
    }
    guard !dumpLines.isEmpty else {
      return .inconclusive(
        "the instrumented launch produced no panel dump lines at all, so there is nothing to judge"
      )
    }

    var failures: [String] = []
    if let magRow = dumpLines.first(where: { $0.contains(magTitleFragment) }) {
      for fragment in ["volumeSlider=shown", "volumeEnabled=yes", "volumeSupport=unknown"]
      where !magRow.contains(fragment) {
        failures.append("the \(magTitleFragment) row does not carry \(fragment)")
      }
    } else {
      failures.append("no dump line names \(magTitleFragment)")
    }

    if let dellRow = dumpLines.first(where: { $0.contains(dellTitleFragment) }) {
      for fragment in [
        "volumeSlider=shown", "volumeEnabled=no", "volumeSupport=unsupported",
        "volumeReason=\"This display lists no volume command.\"",
      ] where !dellRow.contains(fragment) {
        failures.append("the \(dellTitleFragment) row does not carry \(fragment)")
      }
    } else {
      failures.append("no dump line names \(dellTitleFragment)")
    }

    guard failures.isEmpty else { return .fail(failures.joined(separator: "; ")) }
    return .pass(
      "the volume slider is greyed only by the monitor's own denial: \(magTitleFragment) shows an enabled slider on an unknown verdict, \(dellTitleFragment) shows a greyed one carrying the display's own reason"
    )
  }

  // MARK: - Reading a panel dump out of a window

  /// Every panel-dump line in a window, headers included.
  ///
  /// The CONTROL counts these rather than the rows. A launch that wrote a
  /// header and no rows is still an instrumented launch, and a control that
  /// counted rows alone would report it clean: the one measurement whose whole
  /// job is to prove the query can come back empty would be the one that
  /// cannot fail.
  public static func panelDumpLines(fromLogLines lines: [String]) -> [String] {
    lines.filter { $0.contains("paneldump=") }
  }

  /// The row lines alone, which are the ones carrying a display's title and its
  /// slider verdicts. The header carries neither, so judging it would look for
  /// a panel in a line that never names one.
  public static func panelDumpRows(fromLogLines lines: [String]) -> [String] {
    lines.filter { $0.contains("paneldump=row") }
  }

  /// The `volumeSupport=` value of every dump row, in line order. Parsed to the
  /// end of its own token, so `unsupported` is never read as a longer spelling
  /// of something else and a neighbouring `muteSupport=` is never read as this
  /// field.
  public static func panelDumpVolumeSupport(fromLogLines lines: [String]) -> [String] {
    panelDumpRows(fromLogLines: lines).compactMap { line in
      guard let marker = line.range(of: "volumeSupport=") else { return nil }
      let value = String(line[marker.upperBound...].prefix { !$0.isWhitespace })
      return value.isEmpty ? nil : value
    }
  }

  /// The rows of the NEWEST dump in a window, and the only rows anything should
  /// judge.
  ///
  /// A window accumulates every dump a launch produced, oldest first, and the
  /// launch dump reports each panel `unknown` by construction. A search through
  /// the whole window for the line naming a panel therefore finds that panel's
  /// PRE-VERDICT row: on a healthy rig the denying panel reads there as
  /// `volumeEnabled=yes volumeSupport=unknown`, which is the exact shape of the
  /// D24 regression this check exists to catch. Segmenting is what stops a
  /// correct wait from being spent on the wrong rows.
  ///
  /// Cut positionally at the last header, because that is the only boundary the
  /// format has: the pass number is a field inside a line, and a dump IS a
  /// header followed by its rows. A window carrying rows and no header opened
  /// mid-dump and has exactly one candidate segment, so its rows are handed
  /// back rather than dropped; reporting nothing there would turn a readable
  /// dump into a silent one.
  ///
  /// One passthrough is known and left alone: a display whose friendly name is
  /// literally `paneldump=header` would cut the segment at its own row. Names
  /// are user text and the dump quotes them without escaping their content, so
  /// this is the same class the field parsers here already handle by stopping
  /// at a token boundary. Recorded rather than defended against.
  public static func newestPanelDumpRows(fromLogLines lines: [String]) -> [String] {
    guard let header = lines.lastIndex(where: { $0.contains("paneldump=header") }) else {
      return panelDumpRows(fromLogLines: lines)
    }
    return panelDumpRows(fromLogLines: Array(lines[(header + 1)...]))
  }

  /// How many rows the newest header says its dump has, when the window carries
  /// a header at all.
  ///
  /// Searched with its leading space, so a future field whose name ENDS in
  /// `rows` cannot answer for this one, and parsed to the token boundary like
  /// every other field read here.
  public static func newestPanelDumpRowCount(fromLogLines lines: [String]) -> Int? {
    guard let header = lines.last(where: { $0.contains("paneldump=header") }),
          let marker = header.range(of: " rows=")
    else { return nil }
    return Int(header[marker.upperBound...].prefix { $0.isNumber })
  }

  /// Whether the NEWEST dump in a window is the one that knows.
  ///
  /// The capabilities verdict lands asynchronously, so the launch dump reports
  /// every panel `unknown` by construction; a run that judged it would convict
  /// the denying panel of the app's own not-yet-knowing. Waiting on a verdict
  /// rather than on the pass counter is deliberate: the counter says how many
  /// dumps have happened, and what the D24 pair needs is one that knows.
  ///
  /// Asked of the newest segment rather than of the window, for two halves of
  /// one reason. A landed verdict in an OLDER dump would end a wait whose rows
  /// are then judged from a newer dump nobody checked, and a reconfigure can
  /// re-dump `unknown` while the app re-resolves. A header whose rows have not
  /// persisted yet leaves the segment empty, which is not landed, so the poll
  /// waits for them instead of judging nothing.
  ///
  /// A segment is landed only once it is COMPLETE, which is the same problem
  /// one degree finer. The dump writes its rows in the panel's title order and
  /// the store persists them in that order, so the denying panel's row can
  /// arrive before the write-only panel's, and that row carries the very
  /// verdict the wait is watching for. A poll landing in the gap would stop on
  /// a segment with no MAG row in it and FAIL a healthy rig for a missing row.
  /// The header already says how many rows are coming, so the count is what the
  /// wait holds out for. A window with no header has nothing to count against
  /// and falls back to the verdict alone.
  public static func panelDumpVerdictLanded(inLogLines lines: [String]) -> Bool {
    let rows = newestPanelDumpRows(fromLogLines: lines)
    if let expected = newestPanelDumpRowCount(fromLogLines: lines), rows.count != expected {
      return false
    }
    return panelDumpVolumeSupport(fromLogLines: rows).contains { $0 != "unknown" }
  }

  // MARK: - Comparing two paths to the same file

  /// Whether two paths name the same file, symlink aliases included.
  ///
  /// `ps` reports a process's executable by its RESOLVED path, while the path a
  /// check was handed is whatever a person typed. On macOS `/tmp` is a symlink
  /// to `/private/tmp`, as `/var` is to `/private/var`, so a build launched from
  /// a worktree under `/tmp` comes back spelled `/private/tmp`. Compared as
  /// strings, a rig that IS in the state its teardown claims reports that it is
  /// not.
  public static func sameFile(_ lhs: String, _ rhs: String) -> Bool {
    resolvedPath(lhs) == resolvedPath(rhs)
  }

  /// A path with its symlinks resolved and its components standardized, so that
  /// two spellings of one file compare equal.
  ///
  /// Resolved from the deepest ancestor that EXISTS, with the rest of the path
  /// re-appended, because `resolvingSymlinksInPath` leaves a path alone when
  /// its own components are not on disk [MEASURED: `/tmp/x/y` stayed `/tmp/x/y`
  /// while `/tmp` alone resolves]. Anchoring on the ancestor makes the answer
  /// the same for a bundle that is there and for one that is not, which is what
  /// stops this from being a comparison that only works on the happy path.
  public static func resolvedPath(_ path: String) -> String {
    var missing: [String] = []
    var url = URL(fileURLWithPath: path)
    while !FileManager.default.fileExists(atPath: url.path) {
      let parent = url.deletingLastPathComponent()
      guard parent.path != url.path else { break }
      missing.append(url.lastPathComponent)
      url = parent
    }
    var resolved = url.resolvingSymlinksInPath()
    for component in missing.reversed() { resolved.appendPathComponent(component) }
    return resolved.path
  }

  // MARK: - The ledger's filename

  /// `<yyyy-MM-dd>-<sha7>.json`, in UTC.
  ///
  /// Pure, and pinned by a test, because a ledger reader selects the newest
  /// record LEXICALLY and treats any filename in the directory that does not
  /// match this shape as drift. A date that followed the running
  /// machine's time zone would roll the day over at the wrong moment, and an
  /// unpadded month or day would sort `2026-1-5` after `2026-10-05`: either way
  /// the job reads a record that is not the newest and reports an outstanding
  /// count for the wrong run. This function is the one definition of the shape.
  ///
  /// It does not validate the token it is handed, deliberately: a mistyped
  /// `--commit` lands in the ledger as a well-formed filename naming a build
  /// that does not exist. A reader catches that by resolving the record's
  /// `commit` field with `git cat-file -e`. Rejecting it
  /// here would be a second definition of what a commit is, in the layer least
  /// able to answer.
  public static func recordFilename(commit: String, date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    let trimmed = commit.trimmingCharacters(in: .whitespacesAndNewlines)
    // Never a bare trailing dash: a record nobody can attribute is one the
    // drift guard reddens on without saying why.
    let sha = trimmed.isEmpty ? "unknown" : String(trimmed.prefix(7))
    return "\(formatter.string(from: date))-\(sha).json"
  }

  // MARK: - Reading the window

  /// Values from `ddc.write.end value=<v> ok=true` records.
  ///
  /// Acknowledged writes only, and end records only: a start line is not
  /// evidence of a write completing, and a write the panel did not
  /// acknowledge is not evidence of one landing. The line carries no command
  /// byte and no display id, which is why every check built on it works by
  /// keeping the window tight rather than by filtering.
  public static func ddcWriteValues(fromLogLines lines: [String]) -> [UInt16] {
    lines.compactMap { line in
      guard let marker = line.range(of: "ddc.write.end ") else { return nil }
      let tail = line[marker.upperBound...]
      guard tail.contains("ok=true"), let value = tail.range(of: "value=") else { return nil }
      return UInt16(tail[value.upperBound...].prefix { $0.isNumber })
    }
  }

  /// The source display of every `sync fan-out` record in a window.
  ///
  /// The whole digit run is parsed and handed back as a number, so the caller
  /// compares by VALUE: `from=1` and `from=10` differ by one character, and a
  /// substring match would count another display's fan-out as the built-in's,
  /// turning a contaminated window into a pass.
  public static func fanOutSources(fromLogLines lines: [String]) -> [UInt32] {
    lines.compactMap { line in
      guard let marker = line.range(of: "sync fan-out ") else { return nil }
      let tail = line[marker.upperBound...]
      guard let from = tail.range(of: "from=") else { return nil }
      return UInt32(tail[from.upperBound...].prefix { $0.isNumber })
    }
  }

  // MARK: - Helpers

  private static func within(
    _ measured: Double, _ expected: Double, tolerance: Double = combinedGammaTolerance
  ) -> Bool {
    abs(measured - expected) <= tolerance
  }

  private static func rounded(_ value: Double) -> String {
    String(format: "%.4f", value)
  }

  private static func list(_ values: [UInt16]) -> String {
    values.map(String.init).joined(separator: ", ")
  }
}
