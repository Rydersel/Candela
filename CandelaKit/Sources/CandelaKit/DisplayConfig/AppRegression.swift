import Foundation

/// The app-behaviour invariants `candela-probe regress` asserts, as pure
/// verdicts over what the probe's instruments measured.
///
/// The split is deliberate. The DRIVERS live in the probe, because they shell
/// out to the unified log, the defaults domain, the media-key poster and the
/// accessibility API, none of which a unit test can reach. The JUDGEMENT lives
/// here, because a judgement that only ever runs on the rig is a judgement
/// nobody has watched fail, and this repo's own history says an invariant
/// never observed failing is not yet a test.
///
/// Every verdict splits three ways rather than two. A check whose positive
/// control did not fire is `.inconclusive`: not a pass, because nothing was
/// demonstrated, and not a fail, because the app was never observed
/// misbehaving. `.fail` is reserved for a control that fired over a
/// measurement that then came out wrong. That is the whole point of the layer:
/// a check whose failure mode is silence is not a check.
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
  /// nothing reached the panel. A window full of floor writes is the real
  /// failure, and the two are told apart here rather than merged.
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
    if !upWriteValues.contains(where: { $0 > combinedFloorDDCValue }) {
      failures.append(
        "every DDC write on the way up to \(combinedCrossoverBrightness) carried \(combinedFloorDDCValue) (\(list(upWriteValues))): above the switching point the DDC leg carries the whole value, so the register never left its floor"
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

  // MARK: - The sync fan-out

  /// Brightness sync fans a change on one display out to the others. The
  /// control is a QUIET pre-window: the built-in's ambient auto-brightness
  /// fans out continuously when the room light moves, and fan-out lines from
  /// that source would be read as the ones this check drove.
  public static func fanOutVerdict(
    preWindowFanOuts: Int, fanOutLinesFromSource: Int, ddcWrites: Int
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

  /// Wake restores brightness by read resync, not by a burst of writes. The
  /// intake pair plus the quiet-window line is the control triple: without it
  /// the app never saw the sleep or the wake at all, and an absence of writes
  /// afterwards is an absence of everything.
  public static func wakeVerdict(
    sleepIntakeSeen: Bool, wakeIntakeSeen: Bool, quietWindowSeen: Bool, ddcWritesAfterWake: Int
  ) -> PlatformConformance.Outcome {
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
