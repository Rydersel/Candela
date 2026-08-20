import ApplicationServices
import CandelaKit
import CoreGraphics
import Foundation

/// `candela-probe regress`: the app-behaviour regression pass.
///
/// `conform` asks whether the PLATFORM still behaves as this app assumes.
/// `regress` asks whether the APP still behaves as its rulings say it must,
/// against the build that is actually running, with nobody at the keyboard.
/// The two share one report type and one exit-code rule and stay separate
/// commands: their failures mean different things and their baselines are
/// different files.
///
/// This file is the driver half. It shells out to the unified log, the
/// defaults domain and the media-key poster, and it drives the accessibility
/// layer through the C API in process, so none of it is unit-testable; the
/// judgement it feeds lives in `AppRegression`, where every verdict is
/// red-tested including its inconclusive third state.
///
/// The one rule the whole command encodes: a check whose failure mode is
/// silence is not a check. Every branch that cannot run reports a named skip
/// or a named inconclusive, and nothing here is allowed to pass quietly.
enum Regress {
  // MARK: - Inputs

  /// One online display, with the persistence key its prefs are stored under
  /// when it has one (the built-in and any panel that is not DDC-capable does
  /// not appear in the DDC pool, so the key is optional).
  struct Display {
    let id: CGDirectDisplayID
    /// The probe's own label, which carries the display id (`MAG 341C OLED
    /// [2]`). Good prose for a detail string, and never an accessibility
    /// description: nothing in the app publishes it.
    let name: String
    /// The bare title the APP publishes: its sidebar row's accessibility
    /// description and its window title. Threaded from the DDC pool rather than
    /// stripped back out of the label, because a decorated string is a display
    /// name plus a decoration nobody can reliably take off again.
    let title: String
    let persistenceKey: String?
    let isBuiltIn: Bool
  }

  struct Options {
    /// Checks that reconfigure the machine (sleeping every display, quitting
    /// and relaunching the app) run only with this.
    var applyDestructive = false
    var jsonPath: String?
    var recordDir: String?
    var commit: String?
    var toolsDir = "tools/hardware-pass"
    var debugAppPath: String?
  }

  struct UsageError: Error {
    let message: String
  }

  /// A setup step that did not hold, carrying the sentence the record prints.
  /// A setup miss never fails the app: it leaves the check inconclusive with
  /// the step that missed named.
  struct SetupFailure: Error {
    let reason: String
  }

  /// Argument parsing, returning the usage message rather than exiting, so the
  /// dispatch site owns the exit code the way every other subcommand does.
  static func parseOptions(_ arguments: [String]) -> Result<Options, UsageError> {
    var options = Options()
    var index = 0
    func value(for flag: String) -> String? {
      guard index + 1 < arguments.count else { return nil }
      index += 1
      return arguments[index]
    }
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--apply":
        options.applyDestructive = true
      case "--json":
        guard let path = value(for: argument) else { return .failure(UsageError(message: "regress: --json needs a path")) }
        options.jsonPath = path
      case "--record":
        guard let path = value(for: argument) else { return .failure(UsageError(message: "regress: --record needs a directory")) }
        options.recordDir = path
      case "--commit":
        guard let sha = value(for: argument) else { return .failure(UsageError(message: "regress: --commit needs a sha")) }
        options.commit = sha
      case "--tools":
        guard let path = value(for: argument) else { return .failure(UsageError(message: "regress: --tools needs a directory")) }
        options.toolsDir = path
      case "--debug-app":
        guard let path = value(for: argument) else { return .failure(UsageError(message: "regress: --debug-app needs a path to a Debug Candela.app")) }
        options.debugAppPath = path
      default:
        return .failure(UsageError(message: "regress: unknown argument \(argument)"))
      }
      index += 1
    }
    // A record is a verdict about ONE build. Without the commit under test it
    // is a verdict that outlives its build, which is exactly how a fixed bug
    // gets rediscovered weeks later.
    if options.recordDir != nil, options.commit == nil {
      return .failure(UsageError(message: "regress: --record needs --commit <sha>; a run record without the commit under test is not a record of anything"))
    }
    return .success(options)
  }

  // MARK: - Check builders

  /// Whether a driven check's positive control fired, carrying the sentence
  /// that goes into the record either way.
  enum Control {
    case fired(String)
    case didNotFire(String)
  }

  /// The ONE builder for a driven check, adapting this file's `Control` enum
  /// onto `AppRegression.controlledCheck`, where the rule itself lives and is
  /// red-tested. The rule used to live here, which is exactly why it could
  /// drift unobserved: it was demoting a FIRED control to failed whenever the
  /// verdict came back inconclusive, so a caveated measurement recorded as a
  /// dead instrument and lost the control's evidence sentence.
  static func controlledCheck(
    name: String, control: Control, verdict: () -> PlatformConformance.Outcome
  ) -> PlatformConformance.Check {
    switch control {
    case let .didNotFire(reason):
      return AppRegression.controlledCheck(
        name: name, controlFired: false, control: reason, verdict: verdict)
    case let .fired(fired):
      return AppRegression.controlledCheck(
        name: name, controlFired: true, control: fired, verdict: verdict)
    }
  }

  /// A check that IS its own control: the instrument checks below assert that
  /// an instrument answers at all, so there is no second measurement to
  /// control them with.
  static func plainCheck(name: String, outcome: PlatformConformance.Outcome)
    -> PlatformConformance.Check
  {
    .init(name: name, outcome: outcome)
  }

  static func skippedCheck(name: String, reason: String) -> PlatformConformance.Check {
    .init(name: name, outcome: .skip(reason))
  }

  // MARK: - The run

  /// What the preflights established, for the driven checks that come after
  /// them. A driven check whose instrument is unproven reports
  /// `.inconclusive`, never `.fail`: an unproven instrument cannot convict the
  /// app of anything.
  struct Preflight {
    let checks: [PlatformConformance.Check]
    /// Exactly one Candela was running and every instrument addressed it. Not
    /// "the app is running": two instances is a refused rig, not a healthy one,
    /// and a field that read true for both would invite a driven check to
    /// proceed against whichever instance the process table listed first.
    let soleInstanceBound: Bool
    let logProven: Bool
    let gammaProven: Bool
    let keysProven: Bool
    let identifiersProven: Bool
    let prefsProven: Bool
    /// The panel the media keys were aimed at, when one was found.
    let keyTarget: Display?
  }

  static func run(options: Options, displays: [Display]) -> PlatformConformance.Report {
    var report = PlatformConformance.Report(
      platform: ProcessInfo.processInfo.operatingSystemVersionString)
    let instruments = RegressInstruments(toolsDir: options.toolsDir)
    let preflight = preflight(instruments: instruments, displays: displays)
    report.checks += preflight.checks
    // The order is deliberate: each driven check leaves the panel at the floor
    // brightness the next one needs, so the run walks the rig forward instead
    // of dragging it back three times. Every check still MEASURES that
    // precondition rather than inheriting it, because a check that assumes
    // where it started reports its predecessor's state as its own.
    report.checks.append(
      combinedDimmingCheck(instruments: instruments, preflight: preflight, displays: displays))
    report.checks.append(
      crossoverCheck(instruments: instruments, preflight: preflight, displays: displays))
    report.checks.append(
      fanOutCheck(instruments: instruments, preflight: preflight, displays: displays))
    // The mute check touches no brightness at all, so it neither needs nor
    // disturbs the floor point the three above hand each other; it needs a
    // QUIET window instead, which is why nothing else posts a key while it
    // runs.
    report.checks.append(
      muteStrandCheck(instruments: instruments, preflight: preflight, displays: displays))
    // Last, and only under --apply: it blanks every display, so anything after
    // it would measure a rig that had just been slept.
    report.checks.append(
      wakeCheck(instruments: instruments, preflight: preflight, options: options))
    // Last of all: it quits the deployed app and runs another build in its
    // place, so every check that measures the deployed build has to be behind
    // it, and the preflight that bound one instance describes a rig this check
    // deliberately changes.
    report.checks.append(
      panelDumpCheck(instruments: instruments, preflight: preflight, options: options))
    return report
  }

  // MARK: - The run record

  /// The commit a `--json` record names when the run did not carry one. Spelled
  /// out rather than left empty: a reader has to be able to tell an unnamed
  /// build from a sha, and the ledger's own leg refuses `--record` without
  /// `--commit` precisely so this can never reach it quietly.
  static let unnamedCommit = "unspecified"

  /// Writes the run record wherever the flags asked for it, and hands back the
  /// paths so the run says out loud where its verdict landed.
  ///
  /// Both destinations carry the SAME bytes, from the same `Report` the printed
  /// lines come from, so a ledger record and an ad-hoc dump can never disagree
  /// about what a run found. A write that cannot happen is a hard failure with
  /// its reason, never a flag that accepts a path and quietly does nothing.
  static func writeRecords(
    report: PlatformConformance.Report, options: Options, timestamp: Date
  ) -> Result<[String], UsageError> {
    guard options.jsonPath != nil || options.recordDir != nil else { return .success([]) }
    let commit = options.commit ?? unnamedCommit
    let data: Data
    do {
      data = try report.jsonData(label: "regress", commit: commit, timestamp: timestamp)
    } catch {
      return .failure(UsageError(message: "regress: the run record could not be encoded: \(error)"))
    }

    var written: [String] = []
    if let directory = options.recordDir {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
            isDirectory.boolValue
      else {
        // Never created here: a typo would otherwise leave a stray directory
        // holding the one record of a run nobody can find again.
        return .failure(UsageError(
          message: "regress: --record \(directory) is not an existing directory; create the ledger directory first"
        ))
      }
      // The filename's shape is the ledger's contract, so it comes from the one
      // function a test pins rather than from a format string spelled here.
      let path = (directory as NSString).appendingPathComponent(
        AppRegression.recordFilename(commit: commit, date: timestamp))
      if let failure = write(data, to: path) {
        return .failure(UsageError(message: "regress: the run record could not be written to \(path): \(failure)"))
      }
      written.append(path)
    }
    if let path = options.jsonPath {
      if let failure = write(data, to: path) {
        return .failure(UsageError(message: "regress: the run record could not be written to \(path): \(failure)"))
      }
      written.append(path)
    }
    return .success(written)
  }

  private static func write(_ data: Data, to path: String) -> String? {
    do {
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
      return nil
    } catch {
      return "\(error)"
    }
  }

  // MARK: Preflight

  /// Six instrument checks, each a REPORTED check rather than a silent
  /// precondition. Every later check consumes them, and a suite whose
  /// instruments were never asserted is a suite whose green means nothing.
  static func preflight(instruments: RegressInstruments, displays: [Display]) -> Preflight {
    var checks: [PlatformConformance.Check] = []

    // 1. Is EXACTLY ONE app running? Everything else asks questions about a
    //    process, so this one gates the rest, and "a process" has to mean one
    //    nameable binary. Two instances is refused rather than resolved: the
    //    accessibility layer would walk whichever the process table listed
    //    first, `open -b` would reach LaunchServices' choice, and the log
    //    predicate merges both instances' records under one process name, so
    //    every reading downstream would be of a build nobody named.
    let instances = instruments.runningInstances()
    let runningOutcome: PlatformConformance.Outcome
    switch instances.count {
    case 0:
      runningOutcome = .fail(
        "no Candela process is running; there is no build to assert anything about")
    case 1:
      runningOutcome = .pass("Candela is running: \(instances[0].described)")
    default:
      runningOutcome = .fail(
        "\(instances.count) Candela instances are running (\(instances.map(\.described).joined(separator: "; "))); quit all but the build under test. Only one DDC writer may run at a time, the accessibility layer cannot say which instance it walked, and the log predicate filters on the process NAME, so both instances' records merge into one window: a multi-instance run is unusable evidence end to end"
      )
    }
    checks.append(plainCheck(name: "regress.app.running", outcome: runningOutcome))
    guard instances.count == 1 else {
      let reason = instances.isEmpty
        ? "unreachable while the app is not running (see regress.app.running)"
        : "unreachable while \(instances.count) Candela instances are running (see regress.app.running)"
      checks += [
        "regress.instrument.log", "regress.instrument.gamma", "regress.instrument.keys",
        "regress.instrument.identifiers", "regress.instrument.prefs",
      ].map { skippedCheck(name: $0, reason: reason) }
      return Preflight(
        checks: checks, soleInstanceBound: false, logProven: false, gammaProven: false,
        keysProven: false, identifiersProven: false, prefsProven: false, keyTarget: nil)
    }

    // 2. Can the log window see the app at all? Everything downstream reads
    //    the window, and a query that cannot match looks exactly like a quiet
    //    app: same zero lines, same exit code 0.
    //
    //    Widening rather than one fixed window, measured on the rig: an app
    //    nobody has touched for five minutes really does log nothing, and a
    //    fixed five-minute window turns that into a broken-instrument verdict.
    //    Any non-empty window proves the predicate matches this app's records,
    //    which is the whole claim, so the first one that answers wins and the
    //    detail says which it was. Twelve hours of this predicate costs about
    //    four seconds [MEASURED].
    var answeredCount = 0
    var answeredSpan = ""
    var queryFailure: String?
    for (interval, span) in [(300.0, "5 minutes"), (3600.0, "1 hour"), (43200.0, "12 hours")] {
      let window = instruments.logWindow(since: Date().addingTimeInterval(-interval))
      answeredSpan = span
      // A query that FAILED and a quiet app both come back empty, so the tool's
      // own exit status is read before the emptiness is read into anything.
      if window.queryFailed {
        queryFailure = window.failureReason
        break
      }
      answeredCount = window.count
      if !window.isEmpty { break }
    }
    let logOutcome: PlatformConformance.Outcome = queryFailure.map {
      .fail("the log query itself failed over the last \(answeredSpan): \($0)")
    } ?? AppRegression.annotating(
      AppRegression.logWindowControl(lineCount: answeredCount),
      with: "window: the last \(answeredSpan)")
    checks.append(plainCheck(name: "regress.instrument.log", outcome: logOutcome))
    // Everything that reads an EMPTY window as evidence depends on this: until
    // one window has come back non-empty, an empty one proves nothing.
    let logProven = isPass(logOutcome)

    // 3. Does the gamma table answer on every online display? The software
    //    dimming leg is only observable through it.
    var readings: [String] = []
    var unreadable: [String] = []
    for display in displays {
      if let top = instruments.gammaTop(display.id) {
        readings.append("\(display.id):\(String(format: "%.4f", top))")
      } else {
        unreadable.append("\(display.name) [\(display.id)]")
      }
    }
    let gammaOutcome: PlatformConformance.Outcome = displays.isEmpty
      ? .fail("no online displays to read a gamma table from")
      : (unreadable.isEmpty
        ? .pass("every online display answers a gamma read (\(readings.joined(separator: " ")))")
        : .fail("no gamma table from \(unreadable.joined(separator: ", "))"))
    checks.append(plainCheck(name: "regress.instrument.gamma", outcome: gammaOutcome))

    // 4. The one live check that proves four things at once: the posting
    //    host's Accessibility grant, the app's event tap, the DDC path, and
    //    the log query. When it does not pass, every driven check reports
    //    inconclusive rather than fail.
    let target = keyDriveTarget(instruments: instruments, displays: displays)
    let keysCheck = keysInstrumentCheck(
      instruments: instruments, target: target, logProven: logProven,
      targetingCaveat: keyTargetingGate(instruments))
    checks.append(keysCheck)
    let keysProven = isPass(keysCheck.outcome)

    // 5. Are the controls addressable by identifier? Layer B is built on this,
    //    and the accessibility layer has answered confidently and wrongly
    //    about a different attribute twice already, so the reader is asked to
    //    show both answers on every run: present on a control that must carry
    //    one, absent on the window's own close button.
    let identifiersCheck = identifierInstrumentCheck(instruments: instruments)
    checks.append(identifiersCheck)

    // 6. Do the prefs read back? The app's persisted state is the other half
    //    of nearly every assertion, and it is read through cfprefsd because an
    //    in-process snapshot can be stale against a value just written.
    let prefsCheck = prefsInstrumentCheck(instruments: instruments, displays: displays)
    checks.append(prefsCheck)

    return Preflight(
      checks: checks,
      soleInstanceBound: true,
      logProven: logProven,
      gammaProven: isPass(gammaOutcome),
      keysProven: keysProven,
      identifiersProven: isPass(identifiersCheck.outcome),
      prefsProven: isPass(prefsCheck.outcome),
      keyTarget: target?.display
    )
  }

  /// Where the key-drive instrument aims, and whether that panel is in the
  /// half of its range where a press must reach the DDC register.
  ///
  /// Not simply the first external. A brightness key inside a panel's SOFTWARE
  /// zone computes the DDC value the register already holds, the coalescer
  /// drops the repeat, and the window carries no write at all [MEASURED:
  /// `coalescer.target ddc(raw: 0)` and no `ddc.write.end`, on a panel at
  /// stored 0.375 with a switching value of 0.5]. Aimed there, an instrument
  /// that asserts writes reports a healthy app as a dead drive path, and every
  /// check gated on it goes inconclusive for a reason that is not true. So it
  /// prefers a panel that is above its switching value, and when none is, it
  /// still returns one so the check can say WHY it cannot be exercised rather
  /// than reporting nothing at all.
  private static func keyDriveTarget(
    instruments: RegressInstruments, displays: [Display]
  ) -> (display: Display, inHardwareZone: Bool)? {
    let candidates = displays.filter { $0.persistenceKey != nil && !$0.isBuiltIn }
    guard let first = candidates.first else { return nil }
    for display in candidates {
      guard let key = display.persistenceKey,
            let text = instruments.defaultsRead("combinedBrightness.\(key)"),
            let stored = Double(text)
      else { continue }
      let point = instruments.defaultsRead("combinedSwitchingPoint.\(key)").flatMap(Int.init) ?? 0
      if stored >= DimmingMath.switchingValue(fromPoint: point) { return (display, true) }
    }
    return (first, false)
  }

  /// `targetingCaveat` is what the key-targeting gate found when the pointer
  /// is not what a brightness key follows. This check is NOT gated on it, and
  /// deliberately: in the every-display mode the writes really are the posted
  /// keys', which is the whole of what this instrument claims, so refusing to
  /// run would withhold a true answer. What is no longer true is the word
  /// "aimed", so the claim says so instead. The driven checks that DO depend
  /// on the aim are gated on the same finding.
  ///
  /// It reaches exactly two places, and the split matters. Every outcome gains
  /// the caveat as a note. Only ONE branch changes its verdict under it, the
  /// zero-write shortfall, and that softening happens inside the verdict
  /// closure where the branch and the mode are both known: a poster that never
  /// ran and a log query that failed are faults of the instrument itself, and
  /// rewriting either under a zero-write rationale would file an explanation
  /// that does not describe what happened.
  private static func keysInstrumentCheck(
    instruments: RegressInstruments, target: (display: Display, inHardwareZone: Bool)?,
    logProven: Bool, targetingCaveat: KeyTargetingCaveat?
  ) -> PlatformConformance.Check {
    let name = "regress.instrument.keys"
    guard let (target, inHardwareZone) = target else {
      return skippedCheck(
        name: name,
        reason: "no DDC-capable external display is attached, so no key post can produce a DDC write")
    }
    guard instruments.mediaKeyScript != nil else {
      return plainCheck(name: name, outcome: .fail(
        "the media-key poster was not found: \(instruments.mediaKeySearchDescription); pass --tools <dir>"
      ))
    }

    // The control is a QUIET pre-window, and a quiet window only means
    // anything once the query has been shown able to return a line at all.
    // Brightness sync amplifies the built-in's ambient auto-brightness into
    // DDC traffic on every external, and those writes would be read as the
    // ones this check drove.
    let control: Control
    if !logProven {
      control = .didNotFire(
        "the log query has not been shown able to return a line (see regress.instrument.log), so an empty pre-window is not evidence of a quiet app")
    } else if !inHardwareZone {
      control = .didNotFire(
        "every DDC-capable panel sits below its switching value, inside the software zone, where a brightness key computes the DDC value the register already holds and the coalescer drops the repeat: no write can appear there whatever the app does, so an absent write would say nothing about the drive path")
    } else {
      let quietStart = Date()
      Thread.sleep(forTimeInterval: 3)
      let preWindow = instruments.logWindow(since: quietStart)
      let preWrites = AppRegression.ddcWriteValues(fromLogLines: preWindow.lines).count
      if preWindow.queryFailed {
        control = .didNotFire(
          "the pre-window query failed, so its emptiness is the query's and not the app's: \(preWindow.failureReason)")
      } else if preWrites > 0 {
        control = .didNotFire(
          "the 3 s pre-window already carried \(preWrites) DDC writes, so a write in the drive window would not be attributable to the posted keys; brightness sync fans the built-in's ambient auto-brightness out to every external, so turn it off before this run")
      } else {
        control = .fired(
          "the log query is proven live and a quiet 3 s pre-window carried no DDC writes, so the writes below are the posted keys")
      }
    }

    let check = controlledCheck(name: name, control: control) {
      let start = Date()
      let aim = instruments.warpPointer(toCenterOf: target.id)
      guard aim.landed else {
        return .inconclusive(
          "the pointer could not be aimed at \(target.name) [\(target.id)]: \(aim.describedForDetail); the keys would go to whichever display the pointer is actually on, so neither a write nor its absence would be about this panel"
        )
      }
      // brightnessDown then brightnessUp: the pair leaves the panel where it
      // found it on the 1/16 key grid, so the instrument does not move the rig
      // it measures.
      let down = instruments.postMediaKey("brightnessDown", count: 1)
      Thread.sleep(forTimeInterval: 1)
      let up = instruments.postMediaKey("brightnessUp", count: 1)
      Thread.sleep(forTimeInterval: 2)
      guard down, up else {
        return .fail(
          "the media-key poster failed to run (brightnessDown ran: \(down), brightnessUp ran: \(up)): \(instruments.posterFailureSummary ?? "no reason reported")"
        )
      }
      // Flush-tolerant: this window was measured coming back holding two
      // records of a three-record write, two seconds after the press that made
      // them, where the same query moments later carried all six. A drive path
      // reported dead because the store had not caught up is exactly the
      // false conviction this whole command is built against.
      let window = instruments.logWindowAllowingForFlush(since: start)
      guard !window.queryFailed else {
        return .fail("the drive window's log query failed: \(window.failureReason)")
      }
      let writes = AppRegression.ddcWriteValues(fromLogLines: window.lines)
      guard writes.count >= 2 else {
        let shortfall =
          "brightnessDown then brightnessUp aimed at \(target.name) produced \(writes.count) DDC writes in a \(window.count)-line window"
        // Only THIS branch softens under a targeting caveat, and only with the
        // sentence that is true of the mode actually in effect. The poster
        // failing to run and the log query failing are failures of the
        // instrument itself; rewriting either as inconclusive under a
        // zero-write rationale would put an explanation in the record that
        // does not describe what happened.
        guard let targetingCaveat else {
          return .fail(
            "\(shortfall); the Accessibility grant, the app's event tap or the DDC path is down")
        }
        return .inconclusive(
          "\(shortfall), with brightness keys targeting \(targetingCaveat.mode) rather than the display under the pointer: \(targetingCaveat.zeroWriteExplanation)"
        )
      }
      return .pass(
        "brightnessDown then brightnessUp aimed at \(target.name) produced \(writes.count) DDC writes (values \(writes.map(String.init).joined(separator: ", ")))"
      )
    }
    guard let targetingCaveat else { return check }
    // The caveat is a note on every outcome and a downgrade on none: a pass
    // keeps its pass, because the writes really are the posted keys' whatever
    // they landed on, and the one branch that had to soften did so inside the
    // verdict where the branch is known.
    return note(
      check,
      "the word aimed does not hold on this rig and these writes may belong to panels this check never pointed at: \(targetingCaveat.reason)")
  }

  private static func identifierInstrumentCheck(
    instruments: RegressInstruments
  ) -> PlatformConformance.Check {
    let name = "regress.instrument.identifiers"
    let wanted = "enableBrightnessSync"
    guard instruments.openSettingsWindow() else {
      return plainCheck(name: name, outcome: .fail(
        "the settings window did not open within 10 s of `open -b com.rydersel.Candela`, or it could not be selected: \(instruments.lastAXError ?? "no error reported")"
      ))
    }
    // The pref lives on the General pane, so the window has to be showing it.
    // The title is read back rather than trusted: clicking an inert sidebar
    // header leaves the title on the previous pane while every call reports
    // success.
    let title = instruments.settingsWindowName()
    if title != "General", !instruments.axNavigateSidebar(rowNamed: "General") {
      return plainCheck(name: name, outcome: .fail(
        "the settings window is showing \(title.map { "\"\($0)\"" } ?? "an unreadable pane") and it could not be navigated to General, where \(wanted) lives: \(instruments.lastAXError ?? "no sidebar row published that accessibility description")"
      ))
    }
    guard let audit = instruments.axIdentifierAudit(identifier: wanted) else {
      return plainCheck(name: name, outcome: .fail(
        "the accessibility walk failed: \(instruments.lastAXError ?? "no error reported")"))
    }

    // The control is the READER, not the app: it has to be shown answering
    // both ways in the same walk before either answer is believed. Present is
    // demonstrated by any element carrying a present identifier, absent by the
    // window's own close button, which carries none. An unreadable answer
    // counts as neither.
    let control: Control
    switch audit.closeButtonIdentifier {
    case _ where audit.walked == 0:
      control = .didNotFire("the accessibility walk reached zero elements, so nothing was read")
    case _ where audit.identifiersSeen == 0:
      control = .didNotFire(
        "not one of the \(audit.walked) elements walked carries a readable accessibility identifier (\(audit.identifiersUnreadable) answered unreadably), so the reader was never shown a present one and present cannot be told from absent")
    case _ where !audit.closeButtonFound:
      control = .didNotFire(
        "the window's close button was not found, so the reader was never shown an element that must have no identifier")
    case let .text(carried):
      control = .didNotFire(
        "the window's close button carries the identifier \(carried), so an absent reading can no longer be told from a present one on this platform")
    case let .unreadable(reason):
      control = .didNotFire(
        "the window's close button's identifier came back unreadable (\(reason)), so the absent half of the reader is unproven")
    default:
      control = .fired(
        "\(audit.identifiersSeen) of \(audit.walked) walked elements carry an identifier and the close button carries none, so the reader answers both ways")
    }

    return controlledCheck(name: name, control: control) {
      guard let value = audit.targetValue else {
        return .fail(
          "no element in the settings window carries the accessibility identifier \(wanted) (\(audit.walked) elements walked on the General pane); three causes to tell apart: the running build predates the identifier pass, the composer no longer emits the bare pref name for an app-level pref, or the reader cannot see identifiers set through SwiftUI on this build"
        )
      }
      return .pass("the General pane's \(wanted) control carries that identifier, reading \(value)")
    }
  }

  private static func prefsInstrumentCheck(
    instruments: RegressInstruments, displays: [Display]
  ) -> PlatformConformance.Check {
    let name = "regress.instrument.prefs"
    let keys = displays.compactMap(\.persistenceKey)
    guard !keys.isEmpty else {
      return skippedCheck(
        name: name,
        reason: "no attached display carries a persistence key, so there is no per-display pref to read back")
    }
    var reads: [String] = []
    for key in keys {
      let prefKey = "combinedBrightness.\(key)"
      if let value = instruments.defaultsRead(prefKey) { reads.append("\(prefKey)=\(value)") }
    }
    guard !reads.isEmpty else {
      return plainCheck(name: name, outcome: .fail(
        "none of \(keys.count) attached displays has a stored combinedBrightness value; either the defaults domain is unreadable or the app has never persisted a brightness for these panels"
      ))
    }
    return plainCheck(name: name, outcome: .pass(reads.joined(separator: " ")))
  }

  // MARK: - The driven checks

  /// The panel every D28 constant was measured on. Matched by name fragment
  /// rather than by persistence key: the key is a hardware identity that moves
  /// with the cable, and these numbers belong to a panel, not to a port.
  static let magNameFragment = "MAG 341C"

  /// The panel whose capabilities string parsed cleanly with no volume command,
  /// which is the only reason D24 ever greys a slider. Matched by name fragment
  /// for the same reason the write-only panel is: the verdict belongs to a
  /// monitor, not to a port.
  static let dellNameFragment = "U2725QE"

  /// The General pane's two app-level switches, addressed by the accessibility
  /// identifier the pref composer emits.
  ///
  /// Read the combined one carefully. `disableCombinedBrightness` is the
  /// identifier, because identifiers are composed from on-disk pref names, but
  /// the control it names is "Dim past the display's minimum", whose value is
  /// the POSITIVE accessor over that inverted key (D1). So an accessibility
  /// value of 1 means combined dimming is ON, and driving it to 0 is what
  /// turns combined dimming off. Getting that backwards would drive every leg
  /// of this check into the opposite state while every call reported success.
  static let combinedDimmingIdentifier = "disableCombinedBrightness"
  static let syncIdentifier = "enableBrightnessSync"
  /// "Allow a fully dark display", direct polarity: 1 lets the software leg
  /// run to black. It moves the floor these checks assert, so they hold it off.
  static let allowZeroIdentifier = "allowZeroSwBrightness"

  /// One media-key press, as the system actually moves brightness: a synthetic
  /// press lands on a 1/16 grid whatever modifiers ride with it [MEASURED].
  /// Also the fan-out drive's step, which clears the 0.03 sync deadband with
  /// margin from any residual.
  static let keyGridStep = 0.0625

  /// Which preflight instruments a driven check consumes.
  ///
  /// Stated per check rather than assumed, because gating a check on an
  /// instrument it never touches reports a check that could have run as one
  /// that could not: the fan-out drive goes through DisplayServices, and the
  /// wake check reads nothing but the log.
  struct InstrumentNeed: OptionSet {
    let rawValue: Int
    static let log = InstrumentNeed(rawValue: 1 << 0)
    static let gamma = InstrumentNeed(rawValue: 1 << 1)
    static let keys = InstrumentNeed(rawValue: 1 << 2)
    static let identifiers = InstrumentNeed(rawValue: 1 << 3)
    static let prefs = InstrumentNeed(rawValue: 1 << 4)
    /// What the three combined-dimming checks consume: all five.
    static let all: InstrumentNeed = [.log, .gamma, .keys, .identifiers, .prefs]
  }

  /// Which preflight instruments a driven check needs and did not get, named
  /// rather than counted: "the setup did not hold" is the same silence this
  /// command refuses everywhere else.
  private static func unprovenInstruments(
    _ preflight: Preflight, needing needs: InstrumentNeed
  ) -> String? {
    var missing: [String] = []
    if needs.contains(.log), !preflight.logProven {
      missing.append("the log window (regress.instrument.log)")
    }
    if needs.contains(.gamma), !preflight.gammaProven {
      missing.append("the gamma read (regress.instrument.gamma)")
    }
    if needs.contains(.keys), !preflight.keysProven {
      missing.append("the key drive (regress.instrument.keys)")
    }
    if needs.contains(.identifiers), !preflight.identifiersProven {
      missing.append("the identifier reader (regress.instrument.identifiers)")
    }
    if needs.contains(.prefs), !preflight.prefsProven {
      missing.append("the pref readback (regress.instrument.prefs)")
    }
    return missing.isEmpty ? nil : missing.joined(separator: ", ")
  }

  /// nil once the settings window is open and showing `row`, otherwise why it
  /// is not. The General pane is where every app-level switch these checks
  /// stage lives; a display's own row is where its per-display controls do.
  private static func settingsPane(
    _ instruments: RegressInstruments, showing row: String
  ) -> String? {
    guard instruments.openSettingsWindow() else {
      return "the settings window could not be bound: \(instruments.lastAXError ?? "no reason reported")"
    }
    let title = instruments.settingsWindowName()
    if title == row { return nil }
    guard instruments.axNavigateSidebar(rowNamed: row) else {
      return "the settings window is showing \(title.map { "\"\($0)\"" } ?? "an unreadable pane") and it could not be navigated to \(row): \(instruments.lastAXError ?? "no sidebar row published that accessibility description")"
    }
    return nil
  }

  /// Reads a switch's state, drives it, and hands back what it read BEFORE the
  /// drive, so the teardown restores what was actually there rather than what
  /// the check would prefer.
  ///
  /// The pre-state is read three-state on purpose. The toggle instrument
  /// presses whenever the pre-read is not the wanted value, and an unreadable
  /// pre-read is not the wanted value: gating here is what stops a press
  /// against a control whose state nobody established.
  private static func recordAndSet(
    _ instruments: RegressInstruments, identifier: String, to desired: Bool
  ) -> Result<Bool, SetupFailure> {
    let before = instruments.axReading(identifier: identifier)
    guard let text = before.presentText, text == "0" || text == "1" else {
      return .failure(SetupFailure(
        reason: "the General pane's \(identifier) switch read \(before.describedForDetail), so its state before the drive is unknown and pressing it would be pressing blind"
      ))
    }
    guard instruments.axToggle(identifier: identifier, to: desired) else {
      return .failure(SetupFailure(
        reason: "\(identifier) could not be set to \(desired ? "1" : "0"): \(instruments.lastAXError ?? "no reason reported")"
      ))
    }
    return .success(text == "1")
  }

  /// Puts the General switches back to what they read before a check drove
  /// them, and says so in the record when it cannot.
  ///
  /// A failed restore downgrades a PASS to inconclusive. The check itself
  /// measured what it measured, but the run then leaves the rig in a state
  /// nobody recorded and every later check inherits it; printing that green
  /// next to a rig it silently changed is the shape this command exists to
  /// refuse.
  /// Restored in the reverse of the order they were driven, so a pref whose
  /// propagation depends on another's is put back under the same conditions it
  /// was changed under.
  private static func restore(
    _ instruments: RegressInstruments, check: PlatformConformance.Check,
    switches: [(identifier: String, initial: Bool)]
  ) -> PlatformConformance.Check {
    var notes: [String] = []
    for entry in switches.reversed()
    where !instruments.axToggle(identifier: entry.identifier, to: entry.initial) {
      notes.append(
        "teardown: \(entry.identifier) could not be put back to \(entry.initial ? "1" : "0"): \(instruments.lastAXError ?? "no reason reported")"
      )
    }
    guard !notes.isEmpty else { return check }
    return note(check, notes.joined(separator: "; "), downgradingPass: true)
  }

  /// Drives one General switch, recording what it was so the teardown can put
  /// it back. On a miss the check is already finished: it reports inconclusive
  /// naming the step, and the switches driven so far are restored.
  ///
  /// A setup miss is never the app's fault, which is why every one of these
  /// lands as inconclusive rather than as a failure.
  private static func stage(
    _ instruments: RegressInstruments, name: String, identifier: String, to desired: Bool,
    recording switches: inout [(identifier: String, initial: Bool)]
  ) -> PlatformConformance.Check? {
    switch recordAndSet(instruments, identifier: identifier, to: desired) {
    case let .failure(setup):
      return restore(
        instruments,
        check: plainCheck(name: name, outcome: .inconclusive("setup: \(setup.reason)")),
        switches: switches)
    case let .success(initial):
      switches.append((identifier, initial))
      return nil
    }
  }

  /// The three General switches every combined-dimming check needs held, in
  /// the order they are driven.
  ///
  /// - sync OFF: it fans the built-in's ambient hunting out to every external
  ///   as DDC writes, and those would be read as the check's own.
  /// - combined dimming ON: the floor these checks measure does not exist
  ///   without it. Note the inversion at `combinedDimmingIdentifier`.
  /// - a fully dark display OFF: the software leg is transformed onto
  ///   `[0.15, 1]` with it off and onto `[0, 1]` with it on, which moves the
  ///   floor gamma from 0.7875 to 0.7500 at the same stored brightness. The
  ///   constants describe the first configuration, so the check establishes it
  ///   rather than convicting the app of the operator's preference. Measured
  ///   on the rig, where this pref was on.
  private static func stageCombinedPreconditions(
    _ instruments: RegressInstruments, name: String,
    recording switches: inout [(identifier: String, initial: Bool)]
  ) -> PlatformConformance.Check? {
    for (identifier, desired) in [
      (syncIdentifier, false), (combinedDimmingIdentifier, true), (allowZeroIdentifier, false),
    ] {
      if let refusal = stage(
        instruments, name: name, identifier: identifier, to: desired, recording: &switches) {
        return refusal
      }
    }
    return nil
  }

  /// Appends a sentence to a check's detail, whichever outcome it carries.
  /// `AppRegression.annotating` leaves exactly one outcome alone, the skip,
  /// whose reason names why the check never ran at all; a teardown note
  /// belongs on all four, because it is about the rig and not about the
  /// reading.
  private static func note(
    _ check: PlatformConformance.Check, _ text: String, downgradingPass: Bool = false
  ) -> PlatformConformance.Check {
    let outcome: PlatformConformance.Outcome
    switch check.outcome {
    case let .pass(detail):
      outcome = downgradingPass
        ? .inconclusive(
          "\(detail); \(text), so the rig is not in the state this record says it was left in")
        : .pass("\(detail); \(text)")
    case let .fail(detail): outcome = .fail("\(detail); \(text)")
    case let .inconclusive(detail): outcome = .inconclusive("\(detail); \(text)")
    case let .skip(detail): outcome = .skip("\(detail); \(text)")
    }
    return .init(name: check.name, outcome: outcome, control: check.control)
  }

  // MARK: Walking a panel onto a stored brightness

  /// What one convergence drive did, measured rather than counted.
  struct Convergence {
    let arrived: Bool
    let lastRead: Double?
    let presses: Int
    /// Every acknowledged DDC write in the drive's window. Not this panel's
    /// alone: the write record names no display, so the check reads PRESENCE
    /// out of this and never exclusivity.
    let ddcValues: [UInt16]
    /// Why it did not arrive, or why its window cannot be read.
    let failure: String?
  }

  /// Walks a panel's stored brightness onto `target` with posted media keys,
  /// re-reading the stored value after every press.
  ///
  /// By measurement, never by arithmetic. The key grid snaps a press onto the
  /// nearest sixteenth rather than adding to where the panel was, and the sync
  /// deadband clamp discards remainders, so counting presses describes a panel
  /// that is not there.
  ///
  /// Two rules the loop is built around, both of them incidents:
  ///
  /// - **Re-aim before every press, not once per drive.** A brightness key
  ///   goes to the display under the pointer, so an aim taken once is an
  ///   assumption that nothing moved the pointer for the twenty seconds that
  ///   follow. On the rig a drive was measured landing on the built-in
  ///   instead, which walked THAT panel most of the way to black while the
  ///   panel under test barely moved.
  /// - **Stop when the panel stops moving.** Three presses with no change in
  ///   the stored value means the keys are not reaching this display, and
  ///   pressing on to the limit does not discover that, it just drives
  ///   whatever IS receiving them further. The reason says so, so the record
  ///   names the real fault rather than a count.
  private static func converge(
    instruments: RegressInstruments, display: Display, persistenceKey: String,
    to target: Double, limit: Int
  ) -> Convergence {
    let key = "combinedBrightness.\(persistenceKey)"
    let mark = instruments.posterFailureMark
    let start = Date()
    var presses = 0
    var last: Double?
    var stalled = 0
    var arrived = false
    var failure: String?

    while true {
      guard let text = instruments.defaultsRead(key), let value = Double(text) else {
        failure = "the stored brightness \(key) did not answer after \(presses) posted keys"
        break
      }
      if let previous = last, presses > 0 {
        stalled = abs(previous - value) <= AppRegression.storedBrightnessTolerance ? stalled + 1 : 0
      }
      last = value
      let step = AppRegression.convergenceStep(current: value, target: target)
      if step == .arrived {
        arrived = true
        break
      }
      guard stalled < 3 else {
        failure =
          "\(display.name) did not move under 3 consecutive posted keys (it reads \(value), heading for \(target)): the keys are not reaching this display, so pressing on would only drive whichever display is receiving them"
        break
      }
      guard presses < limit else {
        failure =
          "\(limit) posted keys did not walk the stored brightness onto \(target); it last read \(value)"
        break
      }
      let name = step == .pressUp ? "brightnessUp" : "brightnessDown"
      // Re-aimed every time and CHECKED every time: a key press is addressed
      // by pointer position, an aim taken once is an aim nobody re-checked,
      // and an aim nobody read back is not an aim at all.
      let aim = instruments.warpPointer(toCenterOf: display.id)
      guard aim.landed else {
        failure =
          "the pointer could not be aimed at \(display.name) [\(display.id)] before press \(presses + 1): \(aim.describedForDetail); a brightness key goes to the display under the pointer, so pressing now would move a panel this check does not name"
        break
      }
      guard instruments.postMediaKey(name, count: 1) else {
        failure =
          "the media-key poster failed on press \(presses + 1): \(instruments.posterFailureSummary(since: mark) ?? "no reason reported")"
        break
      }
      presses += 1
      Thread.sleep(forTimeInterval: 0.8)
    }

    let window = instruments.logWindowAllowingForFlush(since: start)
    if window.queryFailed {
      return Convergence(
        arrived: false, lastRead: last, presses: presses, ddcValues: [],
        failure: "the drive window's log query failed: \(window.failureReason)")
    }
    return Convergence(
      arrived: arrived, lastRead: last, presses: presses,
      ddcValues: AppRegression.ddcWriteValues(fromLogLines: window.lines), failure: failure)
  }

  /// Walks the panel onto the floor point BY WAY OF the hardware zone, and
  /// hands back the descent, whose window is where the floor write lives.
  ///
  /// The floor write exists only on a CROSSING [MEASURED]. Inside the software
  /// zone every press computes the same DDC value the register already holds,
  /// the coalescer drops the repeat, and the window carries no write at all.
  /// A drive that started below the switching point would therefore produce a
  /// floor gamma with no floor write beside it, and the checks whose positive
  /// control is that write would report a healthy app as a dead drive path.
  /// Going up first and coming down makes both the crossing and the write
  /// unconditional, whatever the panel was at when the run began.
  private static func convergeToFloorFromAbove(
    instruments: RegressInstruments, display: Display, persistenceKey: String
  ) -> Convergence {
    let above = converge(
      instruments: instruments, display: display, persistenceKey: persistenceKey,
      to: AppRegression.combinedCrossoverBrightness, limit: 24)
    guard above.arrived else { return above }
    return converge(
      instruments: instruments, display: display, persistenceKey: persistenceKey,
      to: AppRegression.combinedFloorBrightness, limit: 24)
  }

  /// The floor gamma these checks assert is `swTransform(v / s)`, so it is a
  /// reading of the panel's switching point as much as of its brightness. The
  /// constants were measured at the default point (pref 0, s = 0.5); at any
  /// other the same healthy app produces a different number, and asserting the
  /// constant anyway would convict it of the operator's setting.
  ///
  /// Absent means default, so an unreadable key is the pass here, not a miss.
  private static func switchingPointGate(
    _ instruments: RegressInstruments, _ persistenceKey: String
  ) -> String? {
    let key = "combinedSwitchingPoint.\(persistenceKey)"
    guard let text = instruments.defaultsRead(key) else { return nil }
    guard text.trimmingCharacters(in: .whitespaces) != "0" else { return nil }
    return "\(key) reads \(text) rather than the default 0; the floor gamma \(AppRegression.combinedFloorGamma) is that default's number, so this panel's software leg divides by a different switching point and the constant does not describe it"
  }

  /// Walks the panel back to the floor point whatever the check did with it,
  /// so an abort halfway through a drive does not leave it parked wherever it
  /// stopped. Both combined-dimming checks pass THROUGH the hardware zone on
  /// their way to the floor, so an abort can strand the panel at 0.75 as
  /// easily as anywhere else; before this, only the fan-out check walked home.
  ///
  /// By measurement, like every other drive here, and a walk that cannot
  /// finish is noted rather than assumed.
  /// `syncEnabledDuringWalk` is named in the failure note rather than acted
  /// on. With sync on, the built-in's ambient hunting fans out onto this panel
  /// and can push it back as fast as the keys walk it, so a walk that stalls
  /// with sync on and a walk that stalls with sync off are two different
  /// faults wearing one message. The note says which.
  ///
  /// It is a three-state on purpose, and callers are expected to READ it back
  /// rather than pass what they asked for. Reporting the value a restore was
  /// asked to write lets one detail say sync could not be put back and then
  /// say the walk ran with sync in the state it failed to reach, which are
  /// contradictory sentences in one line. Unreadable is its own answer and
  /// says so.
  private static func walkHome(
    _ instruments: RegressInstruments, check: PlatformConformance.Check,
    display: Display, persistenceKey: String, syncEnabledDuringWalk: Bool?
  ) -> PlatformConformance.Check {
    let home = converge(
      instruments: instruments, display: display, persistenceKey: persistenceKey,
      to: AppRegression.combinedFloorBrightness, limit: 24)
    guard !home.arrived else { return check }
    let contention = switch syncEnabledDuringWalk {
    case .some(true):
      "brightness sync read ON for this walk, so the built-in's ambient hunting was free to fan out onto this panel while the keys walked it"
    case .some(false):
      "brightness sync read off for this walk, so nothing was pushing the panel back"
    case .none:
      "brightness sync could not be read for this walk, so whether anything was pushing the panel back is unknown"
    }
    return note(
      check,
      "teardown: \(display.name) was not walked back to \(AppRegression.combinedFloorBrightness): \(home.failure ?? "the stored brightness never reached it"); \(contention)",
      downgradingPass: true)
  }

  /// The register values these checks assert (37 released, 50 at the
  /// crossover) are the untuned mapping's answers: `valueToDDC` over a 0 to
  /// 100 range, linear, not inverted. Every one of those is an operator
  /// setting with a documented escape hatch, and a panel carrying a tuned one
  /// writes a different value for the same brightness while behaving perfectly.
  ///
  /// So this reads the tuning rather than asserting through it. A non-default
  /// row is inconclusive naming the key, never a fail: convicting the app of
  /// the operator's own tuning is the one reachable false failure both
  /// constants still had. Absent means default, so unreadable keys are the
  /// pass here.
  ///
  /// It CALLS the app's own resolution rather than restating it. `CommandTuning`
  /// decides what an override means (one at or below the minimum is not an
  /// override) and what a curve index means (0 and 5 are both linear), and a
  /// copy of those rules living here would agree with them until the day it
  /// quietly did not. A second definition of "default" is exactly the drift
  /// that turns a gate into a false verdict.
  private static func ddcTuningGate(
    _ instruments: RegressInstruments, _ persistenceKey: String
  ) -> String? {
    func integer(_ name: String) -> Int {
      instruments.defaultsRead("\(name).brightness.\(persistenceKey)").flatMap(Int.init) ?? 0
    }
    let tuning = CommandTuning(
      unavailableDDC: false,
      minDDCOverride: integer("minDDCOverride"),
      maxDDCOverride: integer("maxDDCOverride"),
      curveIndex: integer("curveDDC"),
      invert: integer("invertDDC") != 0,
      remapCodes: []
    )
    // readMax nil is this panel's own situation stated honestly: it answers no
    // capabilities read, so there is no read maximum and the resolution falls
    // back to the assumed one, which is the number the constants were derived
    // against.
    let maximum = tuning.effectiveMaxDDC(readMax: nil)

    var tuned: [String] = []
    if tuning.minDDCOverride != 0 {
      tuned.append("minDDCOverride.brightness reads \(tuning.minDDCOverride), not 0")
    }
    if maximum != Int(AppRegression.assumedRegisterMaximum) {
      tuned.append(
        "maxDDCOverride.brightness makes the range end at \(maximum), not \(Int(AppRegression.assumedRegisterMaximum))")
    }
    if tuning.curveMultiplier != 1 {
      tuned.append(
        "curveDDC.brightness reads \(tuning.curveIndex), a curve of \(tuning.curveMultiplier) rather than linear")
    }
    if tuning.invert { tuned.append("invertDDC.brightness is set") }

    guard !tuned.isEmpty else { return nil }
    return "this panel's brightness command is tuned away from the mapping these constants describe (\(tuned.joined(separator: "; "))), so the register values \(AppRegression.combinedReleasedDDCValue) and \(AppRegression.combinedCrossoverDDCValue) are not what a healthy app would write here"
  }

  /// The panel these constants belong to, plus its persistence key, or the
  /// reason this run cannot ask the question of any attached display.
  private static func magPanel(_ displays: [Display]) -> Result<(Display, String), SetupFailure> {
    guard let mag = displays.first(where: { $0.name.contains(magNameFragment) }) else {
      return .failure(SetupFailure(
        reason: "no \(magNameFragment) panel is attached; the gamma floor and the DDC values asserted here were measured on that panel at stored brightness \(AppRegression.combinedFloorBrightness) and are not general numbers"
      ))
    }
    guard let key = mag.persistenceKey else {
      return .failure(SetupFailure(
        reason: "\(mag.name) carries no persistence key, so its stored brightness cannot be read back"))
    }
    return .success((mag, key))
  }

  /// The gates every driven check shares: one instance, proven instruments,
  /// and a settings window on the pane the switches live on.
  /// What a non-default brightness-key targeting mode costs this run.
  ///
  /// The mode is carried, not just the reason, because the two consumers need
  /// different sentences out of it: the driven checks refuse outright, while
  /// the key instrument softens ONE of its branches and has to say which mode
  /// produced the softening. A single reason string was making the record
  /// claim the focused-display story under every mode.
  struct KeyTargetingCaveat {
    let mode: String
    let reason: String
    /// Why a zero-write window is not a reading of the aimed panel's drive
    /// path, true for this mode specifically.
    let zeroWriteExplanation: String
  }

  /// The pointer aim only decides anything in the pointer-targeted mode.
  ///
  /// `multiKeyboardBrightness` redirects a brightness key to every display, or
  /// to the display holding the active window. In either of those the aim is
  /// inert: the drive lands on panels the check never names, and the aim
  /// readback reports success while it happens, so the readback cannot catch
  /// this one.
  ///
  /// Read from the pref rather than driven through its control, deliberately.
  /// That control is a pop-up on the Keyboard pane, not a switch on General,
  /// and its accessibility value is an item title rather than the 0 or 1 every
  /// drive here handles; staging it blind would be a setup step that compiles,
  /// reports success and does something else. Absent means the default, which
  /// is the mode these checks need.
  private static func keyTargetingGate(_ instruments: RegressInstruments)
    -> KeyTargetingCaveat?
  {
    guard let raw = instruments.defaultsRead("multiKeyboardBrightness") else { return nil }
    let text = raw.trimmingCharacters(in: .whitespaces)
    guard text != "0" else { return nil }
    let mode: String
    let zeroWrite: String
    switch text {
    case "1":
      mode = "every display"
      zeroWrite =
        "the keys reached every display rather than the one this check aimed at, so the window is not a reading of the aimed panel's drive path; a dead transport would look the same here and this measurement cannot tell the two apart"
    case "2":
      mode = "the display holding the active window"
      zeroWrite =
        "the keys followed the active window rather than the pointer, and where that window sits on a display with a native brightness path the app moves it without writing DDC at all, so a zero-write window is what a healthy app produces"
    default:
      mode = "an unrecognised mode"
      zeroWrite =
        "the targeting mode is one this check does not recognise, so where the keys went is unknown and the window cannot be read as the aimed panel's drive path"
    }
    return KeyTargetingCaveat(
      mode: mode,
      reason: "multiKeyboardBrightness reads \(text) (\(mode)) rather than the pointer-targeted default; a posted brightness key would not go to the panel this check aims at, so the drive would move displays the record does not name. The Keyboard pane's brightness-key target has to be back on the display under the pointer before this check can measure anything",
      zeroWriteExplanation: zeroWrite
    )
  }

  /// What stops a posted MUTE key from reaching the aimed panel, or nil.
  ///
  /// Two prefs decide it and neither is the app misbehaving, which is why this
  /// is a setup gate rather than a verdict. `keyboardVolume` decides whether
  /// the app watches the media mute key at all: on the custom-shortcut mode
  /// and on disabled it does not, and the press goes to macOS. Then
  /// `multiKeyboardVolume` decides which display the press lands on, and only
  /// its pointer-targeted default makes the aim decide anything.
  ///
  /// Read from the prefs rather than driven through their controls, for the
  /// brightness gate's reason: both are pop-ups on the Keyboard pane whose
  /// accessibility value is an item title rather than the 0 or 1 every drive
  /// here handles. Absent means the default, and both defaults are what this
  /// check needs.
  private static func muteKeyGate(
    _ instruments: RegressInstruments, persistenceKey: String
  ) -> String? {
    let watched = instruments.defaultsRead("keyboardVolume")?
      .trimmingCharacters(in: .whitespaces) ?? "0"
    // media (0) and both (2) are the modes that watch the media key; custom
    // (1) and disabled (3) leave it to macOS.
    if watched != "0", watched != "2" {
      return "keyboardVolume reads \(watched), a mode in which the app does not watch the media mute key, so a posted mute key would go to macOS and never reach this panel. The Keyboard pane's volume-key mode has to include the media keys before this check can measure anything"
    }
    // The override that demotes the mute strategy also disarms the key:
    // `VolumeSliderPolicy.acceptsMuteKey` refuses on `.forceNone`, so the press
    // reaches the app and is dropped there rather than reaching the panel. The
    // mute check refuses earlier, and for the more specific reason (a mute that
    // lands on the volume register is not the wire it reads); this clause is
    // what keeps the sentence true for any other volume-key drive built on
    // this gate.
    if instruments.defaultsRead("audioSinkOverride.\(persistenceKey)")?
      .trimmingCharacters(in: .whitespaces) == "1" {
      return "audioSinkOverride.\(persistenceKey) reads 1, the always-off override, which refuses the mute key on this display as well as greying its volume control: a posted mute key would reach the app and be dropped there rather than reaching the panel"
    }
    guard let raw = instruments.defaultsRead("multiKeyboardVolume") else { return nil }
    let text = raw.trimmingCharacters(in: .whitespaces)
    guard text != "0" else { return nil }
    let mode = switch text {
    case "1": "every display"
    case "2": "the display matching the audio output device"
    default: "an unrecognised mode"
    }
    return "multiKeyboardVolume reads \(text) (\(mode)) rather than the pointer-targeted default; a posted mute key would not go to the panel this check aims at, so the mute would land on displays the record does not name. The Keyboard pane's volume-key target has to be back on the display under the pointer before this check can measure anything"
  }

  /// Which family of media keys a driven check posts, and therefore which
  /// targeting prefs decide where they land. The two families are separately
  /// configurable, so a check must name its own: refusing the mute drive over
  /// the brightness keys' targeting would file a reason that is true of the
  /// rig and false about this check.
  enum KeyFamily {
    case brightness
    /// The volume family's gates are partly per display, so it carries the
    /// panel it is about: the always-off override that disarms the mute key is
    /// a per-display pref, not an app-level one.
    case volume(persistenceKey: String)
  }

  private static func targetingReason(
    _ instruments: RegressInstruments, family: KeyFamily
  ) -> String? {
    switch family {
    case .brightness: keyTargetingGate(instruments)?.reason
    case let .volume(persistenceKey): muteKeyGate(instruments, persistenceKey: persistenceKey)
    }
  }

  /// `sidebarRow` is the pane the check's controls live on, or nil for a check
  /// that drives no control: the wake check opens no settings window at all,
  /// and refusing it because one could not be bound would withhold an answer
  /// it did not need the window to reach.
  private static func drivenGate(
    name: String, instruments: RegressInstruments, preflight: Preflight,
    needing needs: InstrumentNeed, keyTargeting: KeyFamily?, sidebarRow: String?
  ) -> PlatformConformance.Check? {
    guard preflight.soleInstanceBound else {
      return skippedCheck(
        name: name,
        reason: "unreachable without exactly one Candela running (see regress.app.running)")
    }
    if let keyTargeting, let reason = targetingReason(instruments, family: keyTargeting) {
      return plainCheck(name: name, outcome: .inconclusive("setup: \(reason)"))
    }
    if let missing = unprovenInstruments(preflight, needing: needs) {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: \(missing) did not pass, so nothing driven here could convict the app of anything"))
    }
    if let sidebarRow, let reason = settingsPane(instruments, showing: sidebarRow) {
      return plainCheck(name: name, outcome: .inconclusive("setup: \(reason)"))
    }
    return nil
  }

  // MARK: D28, the combined-dimming propagation

  static func combinedDimmingCheck(
    instruments: RegressInstruments, preflight: Preflight, displays: [Display]
  ) -> PlatformConformance.Check {
    let name = "regress.d28.combined"
    let mag: Display
    let key: String
    switch magPanel(displays) {
    case let .failure(setup): return skippedCheck(name: name, reason: setup.reason)
    case let .success(panel): (mag, key) = panel
    }
    if let refusal = drivenGate(
      name: name, instruments: instruments, preflight: preflight,
      needing: .all, keyTargeting: .brightness, sidebarRow: "General") {
      return refusal
    }

    var switches: [(identifier: String, initial: Bool)] = []
    if let refusal = stageCombinedPreconditions(
      instruments, name: name, recording: &switches) {
      return refusal
    }

    // Walked home BEFORE the switches go back: the floor point is defined
    // under the staged prefs, and a drive that aborted mid-walk has to be
    // brought back under the same conditions it left.
    let check = walkHome(
      instruments,
      check: combinedDimmingDrive(instruments: instruments, mag: mag, persistenceKey: key),
      display: mag, persistenceKey: key, syncEnabledDuringWalk: false)
    return restore(instruments, check: check, switches: switches)
  }

  private static func combinedDimmingDrive(
    instruments: RegressInstruments, mag: Display, persistenceKey: String
  ) -> PlatformConformance.Check {
    let name = "regress.d28.combined"
    for gate in [switchingPointGate, ddcTuningGate] {
      if let reason = gate(instruments, persistenceKey) {
        return plainCheck(name: name, outcome: .inconclusive("setup: \(reason)"))
      }
    }
    let floor = AppRegression.combinedFloorBrightness
    let convergence = convergeToFloorFromAbove(
      instruments: instruments, display: mag, persistenceKey: persistenceKey)
    guard convergence.arrived else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: \(convergence.failure ?? "the stored brightness never reached \(floor)"); the panel is not at the point these constants describe, so nothing was judged"
      ))
    }
    guard let gammaAtFloor = instruments.gammaTop(mag.id) else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: \(mag.name) answered no gamma table at the floor, so the software leg cannot be observed at all"
      ))
    }

    let floorWriteSeen = convergence.ddcValues.contains(AppRegression.combinedFloorDDCValue)
    let seen = convergence.ddcValues.map(String.init).joined(separator: ", ")
    let control: Control = floorWriteSeen
      ? .fired(
        "\(convergence.presses) posted keys walked \(mag.name) down onto \(floor) from above the switching point and produced a DDC write of \(AppRegression.combinedFloorDDCValue)")
      : .didNotFire(
        "\(convergence.presses) posted keys walked \(mag.name) down onto \(floor) but no write in the window carried the floor value \(AppRegression.combinedFloorDDCValue) (values seen: \(seen.isEmpty ? "none" : seen)), so the key drive to this panel is unproven and the gamma readings mean nothing either way"
      )

    return controlledCheck(name: name, control: control) {
      // 0 is combined dimming OFF: the identifier is the inverted on-disk key,
      // the control's value is the positive accessor over it.
      let offStart = Date()
      guard instruments.axToggle(identifier: combinedDimmingIdentifier, to: false) else {
        return .inconclusive(
          "setup: combined dimming could not be turned off: \(instruments.lastAXError ?? "no reason reported")"
        )
      }
      Thread.sleep(forTimeInterval: 2)
      let offWindow = instruments.logWindowAllowingForFlush(since: offStart)
      guard !offWindow.queryFailed else {
        return .inconclusive(
          "the window after combined dimming was turned off failed to read: \(offWindow.failureReason)"
        )
      }
      guard let gammaAfterOff = instruments.gammaTop(mag.id) else {
        return .inconclusive(
          "\(mag.name) answered no gamma table after combined dimming was turned off")
      }

      let onStart = Date()
      guard instruments.axToggle(identifier: combinedDimmingIdentifier, to: true) else {
        return .inconclusive(
          "setup: combined dimming could not be turned back on: \(instruments.lastAXError ?? "no reason reported")"
        )
      }
      Thread.sleep(forTimeInterval: 2)
      let onWindow = instruments.logWindowAllowingForFlush(since: onStart)
      guard !onWindow.queryFailed else {
        return .inconclusive(
          "the window after combined dimming was turned back on failed to read: \(onWindow.failureReason)"
        )
      }
      guard let gammaAfterOn = instruments.gammaTop(mag.id) else {
        return .inconclusive(
          "\(mag.name) answered no gamma table after combined dimming was turned back on")
      }

      return AppRegression.combinedToggleVerdict(
        gammaAtFloor: gammaAtFloor, ddcFloorWriteSeen: floorWriteSeen,
        gammaAfterOff: gammaAfterOff,
        ddcValuesAfterOff: AppRegression.ddcWriteValues(fromLogLines: offWindow.lines),
        gammaAfterOn: gammaAfterOn,
        ddcValuesAfterOn: AppRegression.ddcWriteValues(fromLogLines: onWindow.lines),
        storedBrightnessAfter: instruments
          .defaultsRead("combinedBrightness.\(persistenceKey)").flatMap(Double.init)
      )
    }
  }

  // MARK: The crossover, above and below the switching point

  static func crossoverCheck(
    instruments: RegressInstruments, preflight: Preflight, displays: [Display]
  ) -> PlatformConformance.Check {
    let name = "regress.combined.crossover"
    let mag: Display
    let key: String
    switch magPanel(displays) {
    case let .failure(setup): return skippedCheck(name: name, reason: setup.reason)
    case let .success(panel): (mag, key) = panel
    }
    if let refusal = drivenGate(
      name: name, instruments: instruments, preflight: preflight,
      needing: .all, keyTargeting: .brightness, sidebarRow: "General") {
      return refusal
    }

    var switches: [(identifier: String, initial: Bool)] = []
    if let refusal = stageCombinedPreconditions(
      instruments, name: name, recording: &switches) {
      return refusal
    }

    // This check deliberately parks the panel at 0.75 partway through, so a
    // mid-drive abort strands it there with nothing to bring it back. The walk
    // home runs on every path, not only the ones that finished.
    let check = walkHome(
      instruments,
      check: crossoverDrive(instruments: instruments, mag: mag, persistenceKey: key),
      display: mag, persistenceKey: key, syncEnabledDuringWalk: false)
    return restore(instruments, check: check, switches: switches)
  }

  private static func crossoverDrive(
    instruments: RegressInstruments, mag: Display, persistenceKey: String
  ) -> PlatformConformance.Check {
    let name = "regress.combined.crossover"
    for gate in [switchingPointGate, ddcTuningGate] {
      if let reason = gate(instruments, persistenceKey) {
        return plainCheck(name: name, outcome: .inconclusive("setup: \(reason)"))
      }
    }
    let floor = AppRegression.combinedFloorBrightness
    let top = AppRegression.combinedCrossoverBrightness

    // The starting point is measured, not inherited from the check before it.
    let atFloor = convergeToFloorFromAbove(
      instruments: instruments, display: mag, persistenceKey: persistenceKey)
    guard atFloor.arrived else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: \(atFloor.failure ?? "the stored brightness never reached \(floor)"); this check starts from the floor and the panel is not on it"
      ))
    }
    guard let gammaBefore = instruments.gammaTop(mag.id) else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: \(mag.name) answered no gamma table at the floor"))
    }

    // The control is the floor pair itself: a DDC write at the floor value and
    // a scaled gamma together prove the keys reach this panel AND that combined
    // dimming is actually in effect, which is what makes the release above the
    // switching point mean anything.
    let floorWriteSeen = atFloor.ddcValues.contains(AppRegression.combinedFloorDDCValue)
    let floorGammaHolds =
      abs(gammaBefore - AppRegression.combinedFloorGamma) <= AppRegression.combinedGammaTolerance
    let control: Control = floorWriteSeen && floorGammaHolds
      ? .fired(
        "the panel starts on the floor pair: gamma \(formatted(gammaBefore)) with a DDC write of \(AppRegression.combinedFloorDDCValue) at stored \(floor)")
      : .didNotFire(
        "the panel did not start on the floor pair (gamma reads \(formatted(gammaBefore)), expected \(formatted(AppRegression.combinedFloorGamma)); a floor DDC write was \(floorWriteSeen ? "seen" : "not seen")), so combined dimming was not observably in effect below the switching point and its release above one proves nothing"
      )

    return controlledCheck(name: name, control: control) {
      let up = converge(
        instruments: instruments, display: mag, persistenceKey: persistenceKey, to: top, limit: 12)
      guard up.arrived else {
        return .inconclusive(
          "the drive up to \(top) did not arrive: \(up.failure ?? "the stored brightness never reached it")"
        )
      }
      guard let gammaAtTop = instruments.gammaTop(mag.id) else {
        return .inconclusive("\(mag.name) answered no gamma table at \(top)")
      }
      let down = converge(
        instruments: instruments, display: mag, persistenceKey: persistenceKey, to: floor,
        limit: 12)
      guard down.arrived else {
        return .inconclusive(
          "the drive back down to \(floor) did not arrive: \(down.failure ?? "the stored brightness never reached it")"
        )
      }
      guard let gammaBack = instruments.gammaTop(mag.id) else {
        return .inconclusive("\(mag.name) answered no gamma table back at \(floor)")
      }
      return AppRegression.combinedCrossoverVerdict(
        upWriteValues: up.ddcValues, gammaAtTop: gammaAtTop,
        downWriteValues: down.ddcValues, gammaBackAtFloor: gammaBack)
    }
  }

  // MARK: The sync fan-out

  static func fanOutCheck(
    instruments: RegressInstruments, preflight: Preflight, displays: [Display]
  ) -> PlatformConformance.Check {
    let name = "regress.sync.fanout"
    guard let builtIn = displays.first(where: \.isBuiltIn) else {
      return skippedCheck(
        name: name,
        reason: "no built-in panel is attached, so there is no display with a native brightness path to move as the sync source")
    }
    guard displays.contains(where: { $0.persistenceKey != nil && !$0.isBuiltIn }) else {
      return skippedCheck(
        name: name,
        reason: "no DDC-capable external display is attached, so a fan-out has nowhere to land")
    }
    // needsKeyDrive is true even though the DRIVE goes through DisplayServices:
    // the teardown walks the panel home with posted keys, so a run whose key
    // path is dead cannot leave the rig where the record says it did.
    if let refusal = drivenGate(
      name: name, instruments: instruments, preflight: preflight,
      needing: .all, keyTargeting: .brightness, sidebarRow: "General") {
      return refusal
    }

    // The pre-window control, read BEFORE sync is touched: the built-in's
    // ambient sensor fans out continuously when the room light moves, and those
    // lines would be read as the ones this check drove. Thirty seconds of
    // silence is what makes the drive window attributable.
    let preWindow = instruments.logWindow(since: Date().addingTimeInterval(-30))
    guard !preWindow.queryFailed else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: the pre-window log query failed, so its silence is the query's and not the app's: \(preWindow.failureReason)"
      ))
    }
    let preFanOuts = AppRegression.fanOutSources(fromLogLines: preWindow.lines).count

    var switches: [(identifier: String, initial: Bool)] = []
    if let refusal = stage(
      instruments, name: name, identifier: syncIdentifier, to: true, recording: &switches) {
      return refusal
    }

    let driven = fanOutDrive(
      instruments: instruments, builtIn: builtIn, preWindowFanOuts: preFanOuts)

    // Sync goes back BEFORE the walk home, which is the opposite of the other
    // two checks and for a reason particular to this one: the switch it staged
    // is sync itself, not a pref the floor point is defined under, so nothing
    // about the walk needs sync held on.
    //
    // What the order buys is bounded, and worth stating exactly. `restore`
    // returns sync to the RECORDED initial state, not to off, so this only
    // guarantees a walk free of interference the CHECK introduced: when sync
    // was found off, the walk now runs with it off instead of with the staged
    // on. When sync was found ON, the walk still runs with it on and can still
    // be fought by the built-in's ambient hunting. That case is diagnosable
    // rather than fixed: the walk's failure note names sync's state.
    var check = restore(instruments, check: driven, switches: switches)
    // Read back, never the value the restore was ASKED to write: a restore
    // that failed and a walk that stalled would otherwise print one detail
    // saying sync could not be put back and, in the same breath, describing
    // the walk as having run with sync in the state it never reached.
    let syncAfterRestore = instruments.axReading(identifier: syncIdentifier).presentText
      .flatMap { $0 == "1" ? true : ($0 == "0" ? false : nil) }

    // Leave the panel where the next check expects to find it, by measurement:
    // the deadband clamp discards remainders, so where the fan-out left this
    // panel is not the arithmetic the source moved by.
    if case let .success(panel) = magPanel(displays) {
      check = walkHome(
        instruments, check: check, display: panel.0, persistenceKey: panel.1,
        syncEnabledDuringWalk: syncAfterRestore)
    }
    return check
  }

  private static func fanOutDrive(
    instruments: RegressInstruments, builtIn: Display, preWindowFanOuts: Int
  ) -> PlatformConformance.Check {
    let name = "regress.sync.fanout"
    guard let before = instruments.nativeBrightness(builtIn.id) else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: the built-in's native brightness did not answer, so the sync source can neither be moved nor put back"
      ))
    }

    // One key step, comfortably past the 0.03 deadband from any residual and
    // small enough that no external lands anywhere near its floor. Away from
    // whichever end the panel is nearer: a step DOWN from a panel already at
    // the bottom clamps to where it already was, and a source that did not
    // move cannot be fanned out.
    let target = before >= keyGridStep ? before - keyGridStep : min(1, before + keyGridStep)
    let start = Date()
    instruments.setNativeBrightness(target, for: builtIn.id)
    Thread.sleep(forTimeInterval: 2)
    let observed = instruments.nativeBrightness(builtIn.id)

    // The control is the source having actually MOVED, read back rather than
    // inferred from the setter's return, and moved far enough to leave the
    // deadband. Both halves are needed: a write that returned success and
    // achieved nothing is this project's most repeated defect, and a move
    // smaller than the band is one sync is designed to swallow. Either would
    // otherwise present as the app failing to fan out.
    let control: Control
    let landed = observed
      .map { abs($0 - target) <= AppRegression.nativeBrightnessLandingTolerance } ?? false
    let cleared = observed.map { abs($0 - before) >= SyncDeadband.threshold } ?? false
    if let observed, landed, cleared {
      control = .fired(
        "the built-in moved from \(formatted(before)) to \(formatted(observed)), past the \(SyncDeadband.threshold) deadband and confirmed by a read back rather than by the write's own return"
      )
    } else {
      control = .didNotFire(
        "the built-in was written \(formatted(target)) and reads back \(observed.map(formatted) ?? "nothing") against \(formatted(before)) before it: the source \(landed ? "did not clear the \(SyncDeadband.threshold) deadband" : "never moved"), so an absent fan-out would say nothing about sync"
      )
    }

    var check = controlledCheck(name: name, control: control) {
      let window = instruments.logWindowAllowingForFlush(since: start)
      guard !window.queryFailed else {
        return .inconclusive("the drive window's log query failed: \(window.failureReason)")
      }
      let fromBuiltIn = AppRegression.fanOutSources(fromLogLines: window.lines)
        .count { $0 == builtIn.id }
      return AppRegression.fanOutVerdict(
        preWindowFanOuts: preWindowFanOuts,
        fanOutLinesFromSource: fromBuiltIn,
        ddcWrites: AppRegression.ddcWriteValues(fromLogLines: window.lines).count)
    }

    // The source goes back whatever the verdict was, and the restore is read
    // back too rather than assumed.
    instruments.setNativeBrightness(before, for: builtIn.id)
    Thread.sleep(forTimeInterval: 1.5)
    let restored = instruments.nativeBrightness(builtIn.id)
    if restored == nil || abs(restored! - before) > AppRegression.nativeBrightnessLandingTolerance {
      check = note(
        check,
        "teardown: the built-in was written back to \(formatted(before)) and reads \(restored.map(formatted) ?? "nothing")",
        downgradingPass: true)
    }
    return check
  }

  // MARK: D29, the mute strand proven by outcome

  /// The two values the mute wire carries, as the write record spells them:
  /// 1 mutes and 2 unmutes. The record names no command byte and no display,
  /// so both are read out of a window kept deliberately quiet rather than
  /// filtered out of a busy one.
  static let muteWireValue: UInt16 = 1
  static let unmuteWireValue: UInt16 = 2

  /// The switch that makes the volume command unavailable, which is the
  /// control D29 rule 1 governs. Composed the way the app composes it: the
  /// on-disk pref name, the command, then the display's persistence key.
  static func volumeCommandIdentifier(_ persistenceKey: String) -> String {
    "unavailableDDC.volume.\(persistenceKey)"
  }

  static func mutedPrefKey(_ persistenceKey: String) -> String { "muted.\(persistenceKey)" }

  /// Which register a mute on this display would actually land on, as far as
  /// pref reads can see it, plus both prefs as they read for the record.
  struct MuteStrategy {
    /// True where a mute goes out over the display's own mute command rather
    /// than as a volume-register write of zero.
    let dedicated: Bool
    let described: String
  }

  /// Read the way `VolumeSliderPolicy.usesDedicatedMuteCommand` computes it,
  /// never from the pref alone: `enableMuteUnmute` ASKS for the display's own
  /// mute command, and the always-off override refuses it, demoting the mute
  /// to the volume register. A pref-only reading would judge this check's
  /// wire values on a register the write does not touch.
  ///
  /// That function takes a third input this cannot: the display's own verdict
  /// for the mute command, which is live app state with no pref behind it. On
  /// the panel these checks address it can refuse nothing, because that panel
  /// answers no capabilities read at all and an unknown verdict resolves to
  /// enabled. The two-pref reading is sound HERE for that reason, and would
  /// not be on a panel that answers reads.
  private static func muteStrategy(
    _ instruments: RegressInstruments, persistenceKey: String
  ) -> MuteStrategy {
    let pref = readsOne(instruments, "enableMuteUnmute.\(persistenceKey)")
    let override = instruments.defaultsRead("audioSinkOverride.\(persistenceKey)")?
      .trimmingCharacters(in: .whitespaces)
    // Raw 1 is the always-off override. Absent and any unrecognised raw both
    // resolve to the automatic default, which is the fallback the pref
    // accessor itself applies.
    return MuteStrategy(
      dedicated: pref == true && override != "1",
      described: "enableMuteUnmute.\(persistenceKey) reads \(describedReading(pref)) and audioSinkOverride.\(persistenceKey) reads \(override ?? "nothing (absent, which is its default 0: automatic)")"
    )
  }

  /// D29 rule 1, proven by OUTCOME rather than by log order.
  ///
  /// The write record carries a value and no command byte, and pref
  /// persistence is not logged at all, so which happened first inside the
  /// operation cannot be read from the log. It does not have to be: in the
  /// wrong order the availability pref is already false when the unmute runs,
  /// `toggleMute` refuses, and NO write fires. The presence of the unmute
  /// write is therefore the discriminator, and the muted pref reading 0
  /// afterwards is its other half.
  ///
  /// What this cannot reach, said plainly because the pass says it too: the
  /// achieved mute state. Nothing is connected to this panel's aux jack, it
  /// answers no DDC read, and the one panel here that does answer reads
  /// carries no volume command at all.
  static func muteStrandCheck(
    instruments: RegressInstruments, preflight: Preflight, displays: [Display]
  ) -> PlatformConformance.Check {
    let name = "regress.d29.mute"
    let mag: Display
    let key: String
    switch magPanel(displays) {
    case let .failure(setup): return skippedCheck(name: name, reason: setup.reason)
    case let .success(panel): (mag, key) = panel
    }

    // The mute STRATEGY is this check's whole subject. Where it is not in
    // force a mute is a volume-register write of zero rather than the
    // display's own mute command, so there is no value=1 to control anything
    // with and no value=2 to look for. Both prefs behind it go into the record
    // either way.
    let strategy = muteStrategy(instruments, persistenceKey: key)
    guard strategy.dedicated else {
      return skippedCheck(
        name: name,
        reason: "\(strategy.described), so \(mag.name) mutes by writing its volume register to zero rather than over the display's own mute command; the value=\(muteWireValue) and value=\(unmuteWireValue) writes this check reads belong to that command, so there would be nothing here to measure"
      )
    }

    if let refusal = drivenGate(
      name: name, instruments: instruments, preflight: preflight,
      needing: [.log, .keys, .identifiers, .prefs],
      keyTargeting: .volume(persistenceKey: key), sidebarRow: "General") {
      return refusal
    }

    // Sync OFF for the whole window, staged from General because that is the
    // pane its switch lives on. The built-in's ambient hunting fans out as DDC
    // brightness writes, and a brightness write carrying 1 or 2 is
    // indistinguishable from the mute wire in a record that names no command
    // byte.
    var switches: [(identifier: String, initial: Bool)] = []
    if let refusal = stage(
      instruments, name: name, identifier: syncIdentifier, to: false, recording: &switches) {
      return refusal
    }

    var check = muteStrandDrive(instruments: instruments, mag: mag, persistenceKey: key)
    // Sync goes back from the pane it lives on, and the drive leaves the
    // window on the display's Advanced page, where that switch is not in the
    // tree at all: restoring from there would report it missing rather than
    // put it back.
    if let reason = settingsPane(instruments, showing: "General") {
      check = note(
        check,
        "teardown: brightness sync was left as this check staged it because the settings window could not be returned to General: \(reason)",
        downgradingPass: true)
    } else {
      check = restore(instruments, check: check, switches: switches)
    }
    return check
  }

  private static func muteStrandDrive(
    instruments: RegressInstruments, mag: Display, persistenceKey: String
  ) -> PlatformConformance.Check {
    let name = "regress.d29.mute"
    let identifier = volumeCommandIdentifier(persistenceKey)
    let mutedKey = mutedPrefKey(persistenceKey)

    if let reason = advancedPage(instruments, display: mag, showing: identifier) {
      return plainCheck(name: name, outcome: .inconclusive("setup: \(reason)"))
    }
    if let refusal = clearAnyStandingMute(
      instruments, name: name, display: mag, persistenceKey: persistenceKey) {
      return refusal
    }

    // The positive control: ONE posted mute key, aimed at this panel, in a
    // window with no other post in it and no brightness drive anywhere near
    // it. Both halves are read: the wire value proves the command reached the
    // panel, and the pref proves the app believes it muted.
    let start = Date()
    let aim = instruments.warpPointer(toCenterOf: mag.id)
    guard aim.landed else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: the pointer could not be aimed at \(mag.name) [\(mag.id)]: \(aim.describedForDetail); a mute key goes to the display under the pointer, so the press would mute a panel this check does not name"
      ))
    }
    let mark = instruments.posterFailureMark
    // Every return from here down runs the unmute teardown first. The press is
    // what can leave this panel silent over 0x8D, and a return that reports why
    // it could not finish while leaving the panel muted is the exact state D29
    // exists to prevent. `knownMuted: false` on both: nothing here established
    // a mute, so the teardown posts only where the pref says the panel is
    // muted and says so where it cannot tell.
    guard instruments.postMediaKey("mute", count: 1) else {
      // A poster failure is not proof the press did not land: the script can
      // fail after posting as easily as before it.
      return leaveUnmuted(
        instruments,
        check: plainCheck(name: name, outcome: .inconclusive(
          "setup: the media-key poster failed on the mute press: \(instruments.posterFailureSummary(since: mark) ?? "no reason reported")"
        )),
        display: mag, persistenceKey: persistenceKey, knownMuted: false)
    }
    Thread.sleep(forTimeInterval: 2)
    let window = instruments.logWindowAllowingForFlush(since: start)
    guard !window.queryFailed else {
      // The press landed and only the reading of it failed, so this is the
      // branch most likely to be holding a muted panel.
      return leaveUnmuted(
        instruments,
        check: plainCheck(name: name, outcome: .inconclusive(
          "the mute window's log query failed: \(window.failureReason)")),
        display: mag, persistenceKey: persistenceKey, knownMuted: false)
    }
    let muteWriteSeen = AppRegression.ddcWriteValues(fromLogLines: window.lines)
      .contains(muteWireValue)
    let mutedNow = readsOne(instruments, mutedKey)

    let control: Control = muteWriteSeen && mutedNow == true
      ? .fired(
        "one posted mute key aimed at \(mag.name) produced a value=\(muteWireValue) write and left \(mutedKey) reading 1")
      : .didNotFire(
        "one posted mute key aimed at \(mag.name) left \(mutedKey) reading \(describedReading(mutedNow)) and the \(window.count)-line window \(muteWriteSeen ? "carried a" : "carried no") value=\(muteWireValue) write, so the display's own mute command is unproven on this panel and nothing the unmute half does would mean anything"
      )

    var check = controlledCheck(name: name, control: control) {
      // The disabling control, driven the way a person drives it: turning the
      // volume command off is what rule 1 governs. In the right order the app
      // unmutes first and a value=2 write appears; in the wrong one the
      // availability pref is already false, `toggleMute` refuses, and the
      // window carries no write at all.
      //
      // What the record cannot separate, stated rather than papered over: a
      // volume-register write carrying 2 in this same window would read
      // identically, because the line names no command byte. The window is
      // kept to one action, the pre-window is quiet, and the muted pref
      // readback carries the half a value alone cannot.
      let unmuteStart = Date()
      // Read the polarity carefully before touching this line. The identifier
      // is the on-disk pref name `unavailableDDC`, and the control it names is
      // the grid's "On" switch, whose value is the POSITIVE accessor over that
      // inverted key. So 0 is the command DISABLED, and `to: false` is what
      // makes the volume command unavailable. "Correcting" this to `to: true`
      // would drive the opposite state while every call reported success, and
      // the check would measure nothing while passing.
      guard instruments.axToggle(identifier: identifier, to: false) else {
        return .inconclusive(
          "setup: the volume command's switch could not be turned off (\(identifier)): \(instruments.lastAXError ?? "no reason reported")"
        )
      }
      Thread.sleep(forTimeInterval: 2)
      let unmuteWindow = instruments.logWindowAllowingForFlush(since: unmuteStart)
      guard !unmuteWindow.queryFailed else {
        return .inconclusive(
          "the window after the volume command was turned off failed to read: \(unmuteWindow.failureReason)"
        )
      }
      return AppRegression.muteStrandVerdict(
        muteWriteSeen: muteWriteSeen,
        unmuteWriteSeen: AppRegression.ddcWriteValues(fromLogLines: unmuteWindow.lines)
          .contains(unmuteWireValue),
        mutedAfter: readsOne(instruments, mutedKey)
      )
    }

    // Teardown, in rule 2's order: the availability pref is cleared BEFORE any
    // unmute is attempted, never after, because `toggleMute` refuses outright
    // while the volume command is unavailable. Both halves run on every path,
    // including the ones that never reached the toggle: the mute press may
    // have landed even where its write was not observed.
    if !instruments.axToggle(identifier: identifier, to: true) {
      check = note(
        check,
        "teardown: the volume command could not be turned back on for \(mag.name) (\(identifier)): \(instruments.lastAXError ?? "no reason reported")",
        downgradingPass: true)
    }
    return leaveUnmuted(
      instruments, check: check, display: mag, persistenceKey: persistenceKey,
      knownMuted: muteWriteSeen && mutedNow == true)
  }

  /// nil once the display's Advanced page is showing the volume command's own
  /// switch, otherwise why it is not.
  ///
  /// The readback is the switch, not the window title: a display's title names
  /// the display on its hub and on every page pushed from it, so the title
  /// cannot say which of the two is on screen. Reading the switch first also
  /// makes the window's retained sub-page path a non-issue, since a window
  /// that came back already on Advanced needs no press at all.
  private static func advancedPage(
    _ instruments: RegressInstruments, display: Display, showing identifier: String
  ) -> String? {
    // The sidebar row publishes the display's bare title, not the probe's
    // label: searching for the label found no row at all and reported the
    // check inconclusive on a rig where the row was right there.
    if let reason = settingsPane(instruments, showing: display.title) { return reason }
    if instruments.axReading(identifier: identifier).presentText != nil { return nil }
    guard instruments.axPress(describedAs: "Advanced") else {
      return "the Advanced row could not be pressed on \(display.name)'s page: \(instruments.lastAXError ?? "no reason reported")"
    }
    let reading = instruments.axReading(identifier: identifier)
    guard reading.presentText != nil else {
      return "the Advanced row was pressed on \(display.name)'s page and the switch carrying \(identifier) reads \(reading.describedForDetail) afterwards, so the page this check drives is not on screen"
    }
    return nil
  }

  /// A panel that is ALREADY muted turns the mute key into an unmute, so the
  /// value=1 control could not fire whatever the app did. Cleared with the
  /// same key and read back, rather than recorded as a dead instrument.
  private static func clearAnyStandingMute(
    _ instruments: RegressInstruments, name: String, display: Display, persistenceKey: String
  ) -> PlatformConformance.Check? {
    let mutedKey = mutedPrefKey(persistenceKey)
    guard readsOne(instruments, mutedKey) == true else { return nil }
    let mark = instruments.posterFailureMark
    let aim = instruments.warpPointer(toCenterOf: display.id)
    guard aim.landed, instruments.postMediaKey("mute", count: 1) else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: \(display.name) was already muted (\(mutedKey) reads 1) and the unmute could not be posted: \(aim.landed ? instruments.posterFailureSummary(since: mark) ?? "no reason reported" : aim.describedForDetail)"
      ))
    }
    Thread.sleep(forTimeInterval: 2)
    let after = readsOne(instruments, mutedKey)
    guard after == false else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: \(display.name) was already muted and one posted mute key left \(mutedKey) reading \(describedReading(after)); the mute key toggles, so the control press could only have unmuted this panel"
      ))
    }
    return nil
  }

  /// This check ends with the panel unmuted, or the record says so.
  ///
  /// The mute key toggles rather than sets, so the state is READ before the
  /// key is posted and read again after it. A pref that does not answer is not
  /// treated as unmuted: pressing on a state nobody established could mute a
  /// panel this check found quiet, so it posts only where the mute is known,
  /// either from the pref or from having driven it.
  private static func leaveUnmuted(
    _ instruments: RegressInstruments, check: PlatformConformance.Check,
    display: Display, persistenceKey: String, knownMuted: Bool
  ) -> PlatformConformance.Check {
    let mutedKey = mutedPrefKey(persistenceKey)
    let reading = readsOne(instruments, mutedKey)
    if reading == false { return check }
    guard reading == true || knownMuted else {
      return note(
        check,
        "teardown: \(mutedKey) reads \(describedReading(reading)) and nothing this check drove says the panel is muted, so no unmute was posted and whether it was left muted is unknown",
        downgradingPass: true)
    }
    let mark = instruments.posterFailureMark
    let aim = instruments.warpPointer(toCenterOf: display.id)
    guard aim.landed, instruments.postMediaKey("mute", count: 1) else {
      return note(
        check,
        "teardown: \(display.name) is muted and the unmute could not be posted (\(aim.landed ? instruments.posterFailureSummary(since: mark) ?? "no reason reported" : aim.describedForDetail)); the way back is the display's own unmute in the settings window",
        downgradingPass: true)
    }
    Thread.sleep(forTimeInterval: 2)
    let after = readsOne(instruments, mutedKey)
    guard after == false else {
      return note(
        check,
        "teardown: one posted mute key left \(mutedKey) reading \(describedReading(after)), so \(display.name) may still be muted; the way back is the display's own unmute in the settings window",
        downgradingPass: true)
    }
    return note(check, "teardown: \(display.name) was left unmuted (\(mutedKey) reads 0)")
  }

  /// A boolean pref as `defaults` prints it, three-state: true, false, or nil
  /// where the key did not answer at all.
  private static func readsOne(_ instruments: RegressInstruments, _ key: String) -> Bool? {
    guard let text = instruments.defaultsRead(key)?.trimmingCharacters(in: .whitespaces)
    else { return nil }
    return switch text {
    case "1": true
    case "0": false
    default: nil
    }
  }

  private static func describedReading(_ value: Bool?) -> String {
    value.map { $0 ? "1" : "0" } ?? "nothing"
  }

  // MARK: The quiet wake

  /// `startupAction`'s on-disk raw value for "Re-send the last saved values to
  /// the display" (`StartupAction.write`). It is the ONE value whose wake
  /// behaviour is a burst of writes by design: `RestoreCoordinator.noteWake`
  /// returns immediately unless the action is that one, and under it runs the
  /// restore pass ten times after a three-second sober delay. A run under it
  /// would be measuring that feature working rather than the regression this
  /// check looks for.
  static let startupActionResendRaw = "1"

  /// Wake restores values by read resync, not by a burst of writes.
  ///
  /// Destructive: it sleeps every display for about ten seconds, so it runs
  /// only under `--apply`.
  static func wakeCheck(
    instruments: RegressInstruments, preflight: Preflight, options: Options
  ) -> PlatformConformance.Check {
    let name = "regress.wake.norestoreburst"
    guard options.applyDestructive else {
      return skippedCheck(
        name: name,
        reason: "this check blanks every display for about ten seconds, so it runs only under --apply")
    }
    let raw = instruments.defaultsRead("startupAction")?.trimmingCharacters(in: .whitespaces)
    let describedAction = raw.map { "startupAction reads \($0)" }
      ?? "startupAction is absent, which reads as its default 0 (trust the last saved values)"
    guard raw != startupActionResendRaw else {
      return skippedCheck(
        name: name,
        reason: "\(describedAction), the choice that re-sends the last saved values to the display on wake: that burst is what the app is being asked to do under this setting, so writes here would be the feature rather than a regression. This reads the key, and a safe-mode session runs on the do-nothing action whatever the key says, so a run started with Shift held is refused here for a setting that is not in effect"
      )
    }
    if let refusal = drivenGate(
      name: name, instruments: instruments, preflight: preflight,
      needing: .log, keyTargeting: nil, sidebarRow: nil) {
      return refusal
    }
    // The identifier is composed from the on-disk pref name, so the switch and
    // the key are the same string. Read rather than staged: this check opens
    // no settings window, and a fan-out is contamination it cannot tell from a
    // restore burst rather than something it can measure around.
    if readsOne(instruments, syncIdentifier) == true {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: \(syncIdentifier) reads 1, so the built-in's ambient auto-brightness fans out onto every external as DDC writes; a write after wake would then be sync's and this check cannot tell the two apart. Turn brightness sync off before this run"
      ))
    }
    return note(wakeDrive(instruments: instruments), describedAction)
  }

  private static func wakeDrive(instruments: RegressInstruments) -> PlatformConformance.Check {
    let name = "regress.wake.norestoreburst"
    let started = Date()
    let slept = RegressInstruments.execute("/usr/bin/pmset", ["displaysleepnow"])
    guard slept.status == 0 else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: pmset displaysleepnow exited \(slept.status): \(described(slept.err))"))
    }
    Thread.sleep(forTimeInterval: 8)
    let woke = RegressInstruments.execute("/usr/bin/caffeinate", ["-u", "-t", "2"])
    guard woke.status == 0 else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: the displays were slept and caffeinate -u exited \(woke.status): \(described(woke.err)); they are left to wake on their own input"
      ))
    }

    // Polled rather than waited out: the quiet window fires one second after
    // the last raw reconfiguration event, and a wake that brings several
    // panels back restarts that timer.
    var window = instruments.logWindow(since: started)
    var measured = AppRegression.wakeWindow(fromLogLines: window.lines)
    let deadline = Date().addingTimeInterval(30)
    while !window.queryFailed, !measured.quietWindowSeen, Date() < deadline {
      Thread.sleep(forTimeInterval: 2)
      window = instruments.logWindow(since: started)
      measured = AppRegression.wakeWindow(fromLogLines: window.lines)
    }
    guard !window.queryFailed else {
      return plainCheck(name: name, outcome: .inconclusive(
        "the wake window's log query failed, so its silence is the query's and not the app's: \(window.failureReason)"
      ))
    }
    if measured.quietWindowSeen {
      // Five seconds past the quiet window, because that is where a restore
      // burst would be: the wake chain waits three seconds before its first
      // pass. A window that stopped at the quiet line would report a burst
      // that had not started yet as a quiet wake.
      Thread.sleep(forTimeInterval: 5)
      // Flush-tolerant, and this is the ONE window in the command where an
      // empty result is the PASS: `log show` reads the persisted store, and a
      // burst that had not been persisted yet would read as a quiet wake and
      // be recorded as one. The polling reads above are self-flushing by
      // repetition; this final read is taken once, so it re-reads when it
      // finds no write.
      let settled = instruments.logWindowAllowingForFlush(since: started)
      if !settled.queryFailed {
        window = settled
        measured = AppRegression.wakeWindow(fromLogLines: settled.lines)
      }
    }

    // The control triple IS this check's positive control: without it the app
    // never observably saw the sleep or the wake, and an absence of writes
    // afterwards is an absence of everything. `wakeVerdict` guards the same
    // condition, so the two agree by construction; the control is what puts
    // the finding in the record's control column rather than only in its
    // detail.
    let control: Control = measured.sleepIntakeSeen && measured.wakeIntakeSeen
      && measured.quietWindowSeen
      ? .fired(
        "the sleep intake, the wake intake and the topology quiet window were all logged, in that order, in a \(window.count)-line window, and the writes are counted to 5 s after this run OBSERVED the quiet-window line on a 2 s poll, which is up to 2 s later than the line's own timestamp")
      : .didNotFire(
        "the control triple did not appear in order in the \(window.count)-line window (sleep intake \(seen(measured.sleepIntakeSeen)), a wake intake after it \(seen(measured.wakeIntakeSeen)), a quiet window after that \(seen(measured.quietWindowSeen))), so the app never observably saw the sleep or the wake this check drove"
      )

    return controlledCheck(name: name, control: control) {
      AppRegression.wakeVerdict(
        sleepIntakeSeen: measured.sleepIntakeSeen,
        wakeIntakeSeen: measured.wakeIntakeSeen,
        quietWindowSeen: measured.quietWindowSeen,
        ddcWritesAfterWake: measured.ddcWritesAfterWake
      )
    }
  }

  // MARK: D24 through the panel dump

  /// Where the deployed app is put back when its running path does not name a
  /// bundle, so a relaunch always has somewhere honest to aim.
  static let deployedBundlePath = "/Applications/Candela.app"

  /// The menu-bar panel's row model, read out of the Debug build's dump.
  ///
  /// The panel is the least observable surface in the app: an `NSMenu`-hosted
  /// hosting view publishes nothing to Accessibility and `screencapture` cannot
  /// reach the menu's tracking window. The dump is the only route to its
  /// content, and it is compiled out of Release entirely, so asserting D24 live
  /// means running a Debug build in the deployed one's place for a moment.
  ///
  /// Destructive twice over, which is why it needs `--apply` AND a Debug bundle
  /// named: it quits the deployed app, runs another build, and puts the first
  /// one back. It runs LAST for the same reason: every check before it measures
  /// the deployed build, and nothing should follow a swap.
  ///
  /// **Why the sole-instance preflight gate does not apply mid-check.** That
  /// gate refuses a rig where two builds are running because every instrument
  /// downstream would be reading a build nobody named. This check IS the writer
  /// swap, so it cannot hold that condition still: instead it holds the
  /// stronger one, that exactly one build is running at any INSTANT. It never
  /// proceeds past a failed quit, it confirms zero instances before launching
  /// anything, it confirms each launch is the only instance, and it stops each
  /// child before starting the next. Every window it reads is therefore taken
  /// while exactly one build is running, and every boundary is re-verified
  /// rather than assumed.
  static func panelDumpCheck(
    instruments: RegressInstruments, preflight: Preflight, options: Options
  ) -> PlatformConformance.Check {
    let name = "regress.panel.dump"
    var missing: [String] = []
    if !options.applyDestructive {
      missing.append("--apply, because it quits the deployed app and runs a Debug build in its place")
    }
    if options.debugAppPath == nil {
      missing.append(
        "--debug-app <path to a Debug Candela.app>, because the dump is compiled out of Release and a deployed build has nothing to dump")
    }
    guard missing.isEmpty, let debugApp = options.debugAppPath else {
      return skippedCheck(name: name, reason: "this check needs \(missing.joined(separator: "; and "))")
    }
    let executable = "\(debugApp)/Contents/MacOS/Candela"
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: nothing executable at \(executable); --debug-app takes the path to a Debug Candela.app bundle, not to the binary inside it"
      ))
    }
    if let refusal = drivenGate(
      name: name, instruments: instruments, preflight: preflight,
      needing: .log, keyTargeting: nil, sidebarRow: nil) {
      return refusal
    }

    // Boundary 1: exactly one build is running, and this is where its path is
    // read, so the relaunch puts back the build that was actually there rather
    // than whatever happens to be installed.
    guard let deployed = instruments.soleRunningInstance() else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: \(instruments.lastAXError ?? "no single Candela instance could be bound"), so there is no build to swap out and back"
      ))
    }
    let bundle = bundlePath(forExecutable: deployed.path)
    guard instruments.quitCandela() else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: the deployed app did not answer the quit request: \(instruments.lastProcessError ?? "no reason reported")"
      ))
    }
    // Boundary 2, and the one this check never proceeds past: a Debug build
    // launched beside a deployed one that would not quit is a second DDC
    // writer, which is refused rather than measured around.
    guard instruments.waitForNoRunningInstances(timeout: 20) else {
      return plainCheck(name: name, outcome: .inconclusive(
        "setup: \(instruments.runningInstances().map(\.described).joined(separator: "; ")) is still running 20 s after the quit; nothing is launched beside it, because only one DDC writer may run at a time"
      ))
    }

    let check = panelDumpDrive(instruments: instruments, executable: executable)
    return relaunchDeployed(instruments, check: check, bundle: bundle)
  }

  /// The `.app` a running executable belongs to, or nil when its path does not
  /// name one.
  private static func bundlePath(forExecutable path: String) -> String? {
    let suffix = "/Contents/MacOS/Candela"
    guard path.hasSuffix(suffix) else { return nil }
    return String(path.dropLast(suffix.count))
  }

  /// Two launches of the same Debug build: one instrumented, one as the control
  /// that proves the grep can come back empty. Sequential and never
  /// overlapping, and each one stopped and confirmed gone before the next
  /// begins.
  private static func panelDumpDrive(
    instruments: RegressInstruments, executable: String
  ) -> PlatformConformance.Check {
    let name = "regress.panel.dump"
    func setupMiss(_ reason: String) -> PlatformConformance.Check {
      plainCheck(name: name, outcome: .inconclusive("setup: \(reason)"))
    }

    let instrumentedStart = Date()
    guard let instrumented = instruments.launchDetached(executable: executable, panelDump: true)
    else {
      return setupMiss(instruments.lastProcessError ?? "the Debug build did not launch")
    }
    // Boundary 3: the launched build is the only one running, and it is THIS
    // child. Exactly-one and exactly-this-one are different questions: a child
    // that died on launch while something else came up satisfies the count and
    // none of the meaning, and the window would then be read as its own.
    let running: RegressInstruments.RunningInstance
    switch settled(instruments, instrumented, describedAs: "instrumented") {
    case let .failure(setup):
      _ = instruments.terminate(instrumented)
      return setupMiss(setup.reason)
    case let .success(instance):
      running = instance
    }

    // The verdict lands asynchronously, so this waits for the dump that KNOWS
    // rather than for a pass number: the launch dump reports both panels
    // unknown by construction, and judging it would convict the denying panel
    // of the app's own not-yet-knowing.
    var window = instruments.logWindow(since: instrumentedStart)
    let deadline = Date().addingTimeInterval(20)
    while !window.queryFailed,
          !AppRegression.panelDumpVerdictLanded(inLogLines: window.lines),
          Date() < deadline {
      Thread.sleep(forTimeInterval: 2)
      window = instruments.logWindow(since: instrumentedStart)
    }
    // The NEWEST dump's rows, never the window's. The window accumulates every
    // dump since launch, and the launch dump reports both panels unknown, so
    // handing the verdict the whole window selects the denying panel's
    // pre-verdict row and convicts a healthy rig of a D24 regression.
    let rows = AppRegression.newestPanelDumpRows(fromLogLines: window.lines)
    let landed = AppRegression.panelDumpVerdictLanded(inLogLines: window.lines)
    // Both counts, and what the newest header promised, because a timeout has
    // two causes the segment's own count cannot tell apart: no dump rows
    // ANYWHERE is a build with no dump compiled into it, while rows in the
    // window over an incomplete newest segment is the store still flushing one.
    let windowDumpRows = AppRegression.panelDumpRows(fromLogLines: window.lines).count
    let promisedRows = AppRegression.newestPanelDumpRowCount(fromLogLines: window.lines)
    let queryFailed = window.queryFailed
    let queryFailure = window.failureReason
    let instrumentedLines = window.count
    guard instruments.terminate(instrumented) else {
      return setupMiss(
        "the instrumented Debug instance could not be stopped, so the control launch is not started: \(instruments.lastProcessError ?? "no reason reported")"
      )
    }
    if queryFailed {
      return setupMiss(
        "the instrumented launch's log query failed, so its silence is the query's and not the build's: \(queryFailure)"
      )
    }
    guard landed else {
      // A phrase that fits the noun slot in both renderings: the nil case is
      // the Release-bundle one, which is the sentence a person is likeliest to
      // read, and a clause substituted for a number makes it unreadable.
      let promised = promisedRows.map { "\($0)" } ?? "an unstated number of"
      return setupMiss(
        "no complete dump carried a volume verdict other than unknown within 20 s of launching \(running.described): the newest dump holds \(rows.count) of \(promised) rows, over \(windowDumpRows) dump rows in a \(instrumentedLines)-line window. The launch dump reports every panel unknown by construction and the capabilities verdict lands after it, so the D24 pair was never observable. With no dump rows anywhere in the window, the likeliest cause is a Release bundle behind --debug-app: the dump is compiled out of Release entirely, which looks exactly like this. With rows in the window over an incomplete newest dump, the store had not finished flushing it"
      )
    }

    // The control: the SAME build, launched without the variable. Its window is
    // read fresh, so a dump line in it can only be this launch's.
    let controlStart = Date()
    guard let control = instruments.launchDetached(executable: executable, panelDump: false) else {
      return setupMiss(
        instruments.lastProcessError ?? "the control launch of the Debug build did not start")
    }
    if case let .failure(setup) = settled(instruments, control, describedAs: "control") {
      _ = instruments.terminate(control)
      return setupMiss(setup.reason)
    }
    Thread.sleep(forTimeInterval: 10)
    let controlWindow = instruments.logWindow(since: controlStart)
    guard instruments.terminate(control) else {
      return setupMiss(
        "the control Debug instance could not be stopped: \(instruments.lastProcessError ?? "no reason reported")"
      )
    }
    if controlWindow.queryFailed {
      return setupMiss(
        "the control launch's log query failed, so its emptiness is the query's and not the build's: \(controlWindow.failureReason)"
      )
    }
    let controlDumpLines = AppRegression.panelDumpLines(fromLogLines: controlWindow.lines).count

    // The control's own control: a window carrying no lines AT ALL cannot
    // demonstrate that a dump line would have shown up in it. Zero dump lines
    // out of zero lines is a broken query wearing the shape of a clean result.
    let positiveControl: Control
    if controlWindow.count == 0 {
      positiveControl = .didNotFire(
        "the control launch's 10 s window came back with no lines from the app at all, so its zero dump lines are the query's silence rather than the build's"
      )
    } else if controlDumpLines > 0 {
      positiveControl = .didNotFire(
        "the same build launched without \(RegressInstruments.panelDumpVariable) still wrote \(controlDumpLines) dump lines in a \(controlWindow.count)-line window, so the query cannot come back empty and an empty result would have proven nothing"
      )
    } else {
      positiveControl = .fired(
        "the same build launched without \(RegressInstruments.panelDumpVariable) wrote no dump lines in a \(controlWindow.count)-line window, so the query can come back empty and the \(rows.count) rows read from the instrumented launch are the variable's"
      )
    }

    return controlledCheck(name: name, control: positiveControl) {
      AppRegression.panelDumpVerdict(
        dumpLines: rows, noVarDumpLineCount: controlDumpLines,
        magTitleFragment: magNameFragment, dellTitleFragment: dellNameFragment)
    }
  }

  /// The child, confirmed to BE the only Candela running.
  ///
  /// The count and the identity are different questions. A child that exited on
  /// launch while another instance was coming up satisfies "exactly one" and
  /// none of what the count was asked for, and every line read afterwards would
  /// be attributed to a build this check never started. So the sole instance's
  /// pid is compared to the child's rather than assumed to be it.
  private static func settled(
    _ instruments: RegressInstruments, _ process: Process, describedAs role: String
  ) -> Result<RegressInstruments.RunningInstance, SetupFailure> {
    guard let running = instruments.waitForSoleRunningInstance(timeout: 20) else {
      return .failure(SetupFailure(
        reason: "the \(role) Debug launch did not settle as the only running build: \(instruments.lastProcessError ?? "no reason reported")"
      ))
    }
    guard running.pid == "\(process.processIdentifier)" else {
      return .failure(SetupFailure(
        reason: "the only Candela running is \(running.described), not the \(role) child this check launched (pid \(process.processIdentifier)): the count is right and the instance is not, so nothing read from this window would be the launched build's"
      ))
    }
    return .success(running)
  }

  /// Puts the deployed build back and says so in the record: the rig leaves as
  /// it arrived, or the record says exactly how it does not. A relaunch that
  /// did not put back what it aimed at downgrades a pass for the same reason a
  /// failed teardown does, and more sharply here: the alternative is a green
  /// line printed beside a rig running a build nobody named.
  ///
  /// The path is compared rather than trusted. `open -a` goes through
  /// LaunchServices, which this file already records resolving a bundle to the
  /// REGISTERED copy rather than to the path handed to it, so "the app at X was
  /// relaunched" is a sentence that has to be checked before it is written.
  private static func relaunchDeployed(
    _ instruments: RegressInstruments, check: PlatformConformance.Check, bundle: String?
  ) -> PlatformConformance.Check {
    let path = bundle ?? deployedBundlePath
    let aim = bundle == nil
      ? "the running build's path did not name a bundle, so \(path) was relaunched instead"
      : "the deployed app at \(path) was relaunched"
    guard instruments.openBundle(path),
          let back = instruments.waitForSoleRunningInstance(timeout: 30)
    else {
      return note(
        check,
        "teardown: \(aim) and it did not come back: \(instruments.lastProcessError ?? "no reason reported"); the rig is left with no Candela running",
        downgradingPass: true)
    }
    // Compared as FILES, not as spellings: `ps` reports the resolved path, and
    // a worktree bundle handed over as /tmp/... comes back as /private/tmp/...
    // On the rig that reported a correct relaunch as a rig left in the wrong
    // state, which is a false conviction on the teardown line.
    let expected = "\(path)/Contents/MacOS/Candela"
    guard AppRegression.sameFile(back.path, expected) else {
      return note(
        check,
        "teardown: \(aim) and what came back is \(back.described), not \(expected); open goes through LaunchServices, which resolves a bundle to the registered copy, so the rig is running a build this check did not put back",
        downgradingPass: true)
    }
    return note(check, "teardown: \(aim) and answers as \(back.described)")
  }

  private static func seen(_ value: Bool) -> String { value ? "seen" : "not seen" }

  /// A tool's stderr on one line, never an empty string: a failure reported as
  /// no reason at all is the silence this command refuses everywhere else.
  private static func described(_ standardError: String) -> String {
    let text = standardError
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: "; ")
    return text.isEmpty ? "nothing on stderr" : text
  }

  private static func formatted(_ value: Double) -> String {
    String(format: "%.4f", value)
  }

  static func isPass(_ outcome: PlatformConformance.Outcome) -> Bool {
    if case .pass = outcome { return true }
    return false
  }
}

// MARK: - The instruments

/// Everything the regress checks measure the world with. Each one is a shell
/// out, a CoreGraphics call or a direct accessibility read, and each one
/// reports its own failure rather than returning a plausible default: an
/// instrument that answers with something else is the failure mode this whole
/// command is built against.
///
/// `ApplicationServices` is a C framework, so the accessibility layer lives in
/// process without breaking the rule that keeps AppKit and SwiftUI out of the
/// engine and the probe.
final class RegressInstruments {
  let toolsDir: String
  /// Why the last accessibility call did not answer, so a check's detail can
  /// name the cause instead of reporting a control as merely missing.
  private(set) var lastAXError: String?
  /// Why each failed media-key post did not run, carrying the script's own
  /// stderr: "the poster failed" on its own is the silence this command
  /// refuses everywhere else. One entry per failed post, kept for the life of
  /// the run.
  private(set) var posterFailures: [String] = []

  /// Every poster failure so far on one line, or nil when every post worked.
  var posterFailureSummary: String? {
    posterFailures.isEmpty ? nil : posterFailures.joined(separator: "; ")
  }

  /// A cursor into `posterFailures`, taken before a check's own drives begin.
  /// The array is never cleared, so a check that reported the whole of it
  /// would attribute an earlier check's failure to itself, which is a reason
  /// that names the wrong drive.
  var posterFailureMark: Int { posterFailures.count }

  func posterFailureSummary(since mark: Int) -> String? {
    let own = posterFailures.dropFirst(mark)
    return own.isEmpty ? nil : own.joined(separator: "; ")
  }

  init(toolsDir: String) {
    self.toolsDir = toolsDir
  }

  // MARK: Process plumbing

  /// Output is captured through temporary FILES rather than pipes: a log
  /// window can run to megabytes, and a pipe whose buffer fills while nobody
  /// is reading deadlocks the child forever.
  @discardableResult
  static func execute(_ path: String, _ arguments: [String], environment: [String: String]? = nil)
    -> (status: Int32, out: String, err: String)
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let environment {
      var merged = ProcessInfo.processInfo.environment
      for (key, value) in environment { merged[key] = value }
      process.environment = merged
    }
    let manager = FileManager.default
    let stamp = UUID().uuidString
    let outURL = manager.temporaryDirectory.appendingPathComponent("candela-regress-out-\(stamp)")
    let errURL = manager.temporaryDirectory.appendingPathComponent("candela-regress-err-\(stamp)")
    manager.createFile(atPath: outURL.path, contents: nil)
    manager.createFile(atPath: errURL.path, contents: nil)
    defer {
      try? manager.removeItem(at: outURL)
      try? manager.removeItem(at: errURL)
    }
    guard let outHandle = try? FileHandle(forWritingTo: outURL),
          let errHandle = try? FileHandle(forWritingTo: errURL)
    else { return (-1, "", "could not open a capture file for \(path)") }
    process.standardOutput = outHandle
    process.standardError = errHandle
    do {
      try process.run()
    } catch {
      try? outHandle.close()
      try? errHandle.close()
      return (-1, "", "\(path) did not launch: \(error)")
    }
    process.waitUntilExit()
    try? outHandle.close()
    try? errHandle.close()
    return (
      process.terminationStatus,
      (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
      (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
    )
  }

  // MARK: The log window

  /// The subsystem and category tag every one of our records carries. Lines
  /// without it are `log show`'s own column header, and counting the header
  /// would make a window's line count non-zero on an empty result: the
  /// zero-line control would then be a check that cannot fail.
  private static let recordTag = "[com.rydersel.Candela:"

  /// One window read, with the query's own outcome attached. An empty `lines`
  /// from a query that FAILED and an empty `lines` from a quiet app are the
  /// same value and mean opposite things, so the caller is handed both halves
  /// and every caller here checks `queryFailed` before reading anything into
  /// the emptiness.
  struct LogWindow {
    let lines: [String]
    let status: Int32
    let standardError: String

    var queryFailed: Bool { status != 0 }
    var count: Int { lines.count }
    var isEmpty: Bool { lines.isEmpty }
    /// The stderr on one line, for a detail string; the command name when the
    /// tool failed silently, so a failure is never reported as no reason.
    var failureReason: String {
      let text = standardError
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: "; ")
      return text.isEmpty ? "/usr/bin/log exited \(status) with nothing on stderr" : text
    }
  }

  /// `/usr/bin/log` by absolute path (a bare `log` is a shell builtin here
  /// that prints its complaint to stderr and exits 0, which is indistinguish-
  /// able from an app that logged nothing). `--info --debug` because most of
  /// our lines are below default level, and the process filter because
  /// `swift test` logs into this same subsystem from the test helper.
  func logWindow(since: Date) -> LogWindow {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let result = Self.execute("/usr/bin/log", [
      "show", "--start", formatter.string(from: since), "--info", "--debug",
      "--style", "compact",
      "--predicate", "subsystem == \"com.rydersel.Candela\" AND process == \"Candela\"",
    ])
    return LogWindow(
      lines: result.out
        .split(separator: "\n")
        .map(String.init)
        .filter { $0.contains(Self.recordTag) },
      status: result.status,
      standardError: result.err
    )
  }

  /// A window read that gives the log store a second chance before an empty
  /// result is believed.
  ///
  /// `log show` reads the PERSISTED store, and persistence is not instant: a
  /// window read a couple of seconds after a write has been measured on this
  /// rig coming back without it, where the same query moments later carried it.
  /// Re-reading once when the first result has no DDC write in it can only
  /// turn a false empty into a true reading, never the other way: if there
  /// really was no write, both reads agree and the extra wait costs seconds.
  func logWindowAllowingForFlush(since: Date) -> LogWindow {
    let first = logWindow(since: since)
    guard !first.queryFailed,
          AppRegression.ddcWriteValues(fromLogLines: first.lines).isEmpty
    else { return first }
    Thread.sleep(forTimeInterval: 2)
    return logWindow(since: since)
  }

  // MARK: Gamma

  /// The top of the red ramp. 1.0000 means the software dimming leg has
  /// released the display entirely.
  func gammaTop(_ id: CGDirectDisplayID) -> Double? {
    let capacity = Int(CGDisplayGammaTableCapacity(id))
    guard capacity > 0 else { return nil }
    var red = [CGGammaValue](repeating: 0, count: capacity)
    var green = red
    var blue = red
    var sampleCount: UInt32 = 0
    guard CGGetDisplayTransferByTable(id, UInt32(capacity), &red, &green, &blue, &sampleCount)
      == .success, sampleCount > 0
    else { return nil }
    return Double(red[Int(sampleCount) - 1])
  }

  // MARK: Prefs

  /// Read through cfprefsd rather than through an in-process
  /// `UserDefaults(suiteName:)`: this process's snapshot can be stale against
  /// a value the app wrote a moment ago, and every pref assertion here is
  /// about something that just happened.
  func defaultsRead(_ key: String) -> String? {
    let result = Self.execute("/usr/bin/defaults", ["read", "com.rydersel.Candela", key])
    guard result.status == 0 else { return nil }
    let value = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  // MARK: Media keys and the pointer

  /// The committed poster script, found by searching upwards from the working
  /// directory: `swift run` puts the working directory inside the package
  /// while the tools live at the repo root. An explicit `--tools` path is
  /// taken as given and never searched.
  var mediaKeyScript: String? {
    let manager = FileManager.default
    func poster(in directory: String) -> String? {
      let path = (directory as NSString).appendingPathComponent("mediakey.swift")
      return manager.fileExists(atPath: path) ? path : nil
    }
    if (toolsDir as NSString).isAbsolutePath { return poster(in: toolsDir) }
    var base = URL(fileURLWithPath: manager.currentDirectoryPath)
    for _ in 0 ... 4 {
      if let found = poster(in: base.appendingPathComponent(toolsDir).path) { return found }
      base = base.deletingLastPathComponent()
    }
    return nil
  }

  /// Where the poster was looked for, as the check's detail says it: an
  /// absolute `--tools` is taken literally and never searched upwards.
  var mediaKeySearchDescription: String {
    (toolsDir as NSString).isAbsolutePath
      ? "no mediakey.swift at \(toolsDir)"
      : "no mediakey.swift under \(toolsDir), searched upwards from \(FileManager.default.currentDirectoryPath)"
  }

  /// Posts a real system-defined media key through the committed script. It
  /// imports AppKit, which the probe must not, so this stays a shell out.
  ///
  /// A failure is APPENDED and never cleared by a later success: a check posts
  /// several keys and reports once, so clearing on success would let a failed
  /// brightnessDown followed by a working brightnessUp report no reason at all.
  func postMediaKey(_ name: String, count: Int) -> Bool {
    guard let script = mediaKeyScript else {
      posterFailures.append("\(name): \(mediaKeySearchDescription)")
      return false
    }
    let result = Self.execute("/usr/bin/swift", [script, name, String(count)])
    guard result.status != 0 else { return true }
    let stderr = result.err
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: "; ")
    posterFailures.append(
      "\(name): \(script) exited \(result.status): "
        + (stderr.isEmpty ? "nothing on stderr" : stderr))
    return false
  }

  /// One pointer aim, with the position the pointer actually ended up at.
  struct Aim {
    let display: CGDirectDisplayID
    let landed: Bool
    let achieved: CGPoint?
    let attempts: Int

    var describedForDetail: String {
      let position = achieved
        .map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "a position that could not be read"
      return "\(attempts) warp\(attempts == 1 ? "" : "s") left the pointer at \(position), \(landed ? "inside" : "outside") display \(display)'s bounds \(CGDisplayBounds(display).debugDescription)"
    }
  }

  /// Brightness keys target the display under the pointer, so aiming is how a
  /// key press is addressed to one panel.
  ///
  /// **The aim is read back**, which every other instrument here already does
  /// and this one did not. `CGWarpMouseCursorPosition` returns nothing, so an
  /// aim that did not take was indistinguishable from one that did, and a
  /// drive would then walk a panel the record never names. Roughly half the
  /// runs of one pass were measured delivering their key pair to the built-in
  /// while reporting an aim at an external, which is the shape that hides
  /// behind a missing readback.
  ///
  /// Up to three attempts, because a warp lands asynchronously and the window
  /// server can still be reporting the old position on the first read.
  @discardableResult
  func warpPointer(toCenterOf id: CGDirectDisplayID) -> Aim {
    let bounds = CGDisplayBounds(id)
    let centre = CGPoint(x: bounds.midX, y: bounds.midY)
    var achieved: CGPoint?
    for attempt in 1 ... 3 {
      CGWarpMouseCursorPosition(centre)
      CGAssociateMouseAndMouseCursorPosition(1)
      Thread.sleep(forTimeInterval: 0.15)
      // The event system's own idea of where the pointer is, which is what
      // resolves a media key's target display; not the value just written.
      achieved = CGEvent(source: nil)?.location
      if let achieved, bounds.contains(achieved) {
        return Aim(display: id, landed: true, achieved: achieved, attempts: attempt)
      }
    }
    return Aim(display: id, landed: false, achieved: achieved, attempts: 3)
  }

  // MARK: The built-in's native brightness

  /// The fan-out check needs to move a display WITHOUT going through the app,
  /// so the app has something to observe and replicate. DisplayServices is the
  /// same private path the app's own native leg uses, and the built-in is the
  /// only panel here that has one.
  func nativeBrightness(_ id: CGDirectDisplayID) -> Double? {
    DisplayServices.getBrightness(for: id).map(Double.init)
  }

  /// The return is the call's own status and says nothing about the achieved
  /// state; every caller here reads the value back afterwards.
  @discardableResult
  func setNativeBrightness(_ value: Double, for id: CGDirectDisplayID) -> Bool {
    DisplayServices.setBrightness(Float(value), for: id)
  }

  // MARK: The app process

  /// One running Candela, named by the binary it is running. The PATH is the
  /// point: `pgrep -x` matches by executable NAME, so a Debug build out of a
  /// worktree's DerivedData and the deployed bundle both answer to it, and a
  /// run that does not print the path cannot say which build it measured.
  struct RunningInstance {
    let pid: String
    let path: String

    var described: String { "pid \(pid) at \(path)" }
  }

  func runningInstances() -> [RunningInstance] {
    let result = Self.execute("/usr/bin/pgrep", ["-x", "Candela"])
    guard result.status == 0 else { return [] }
    return result.out.split(whereSeparator: \.isNewline).map(String.init).map { pid in
      let path = Self.execute("/bin/ps", ["-p", pid, "-o", "comm="]).out
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return RunningInstance(pid: pid, path: path.isEmpty ? "(path unreadable)" : path)
    }
  }

  /// The ONE instance every other instrument addresses, or nil with the reason
  /// recorded. Two instances is refused rather than resolved: it is the same
  /// non-unique hazard this file already refuses loudly for windows and for
  /// identifiers, and picking the first would bind whichever the process table
  /// happened to list first.
  func soleRunningInstance() -> RunningInstance? {
    let instances = runningInstances()
    guard instances.count == 1 else {
      lastAXError = instances.isEmpty
        ? "no Candela process is running"
        : "\(instances.count) Candela instances are running (\(instances.map(\.described).joined(separator: "; "))); quit all but one before measuring anything"
      return nil
    }
    return instances[0]
  }

  // There is deliberately no `runningPIDs()` and no `appIsRunning()`. Both
  // answered the any-instance question, and every honest caller here needs the
  // one-instance question instead: `runningInstances()` to report what is
  // running, `soleRunningInstance()` to address it.

  // MARK: Swapping which build is running

  /// Why the last process step did not do what it was asked, so a check's
  /// detail can name the step rather than report a swap that half happened.
  private(set) var lastProcessError: String?

  static let panelDumpVariable = "CANDELA_DEBUG_PANEL"

  /// Quits the running app through its own scripting terminate, the way a
  /// person would. A signal would skip the app's shutdown, and the whole
  /// premise of a build swap is that the outgoing build has STOPPED writing
  /// DDC before another one starts.
  func quitCandela() -> Bool {
    let result = Self.execute("/usr/bin/osascript", ["-e", "tell application \"Candela\" to quit"])
    guard result.status == 0 else {
      lastProcessError =
        "osascript exited \(result.status) asking Candela to quit: \(Self.oneLine(result.err))"
      return false
    }
    return true
  }

  /// Polls until no Candela is running at all. The ONE precondition a build
  /// swap will not proceed past: only one DDC writer at a time.
  func waitForNoRunningInstances(timeout: TimeInterval) -> Bool {
    poll(timeout: timeout) { self.runningInstances().isEmpty }
  }

  /// Polls until exactly one Candela is running, and hands it back. Two is a
  /// refusal here for the same reason it is everywhere else in this file.
  func waitForSoleRunningInstance(timeout: TimeInterval) -> RunningInstance? {
    guard poll(timeout: timeout, until: { self.runningInstances().count == 1 }) else {
      let instances = runningInstances()
      lastProcessError = instances.isEmpty
        ? "no Candela process appeared within \(Int(timeout)) s"
        : "\(instances.count) Candela instances are running (\(instances.map(\.described).joined(separator: "; ")))"
      return nil
    }
    return runningInstances().first
  }

  private func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.5)
    }
    return condition()
  }

  /// Launches a bundle's executable DIRECTLY as a child process, never `open`.
  ///
  /// `open` and `open -b` both go through LaunchServices, which resolves a
  /// bundle identifier to the REGISTERED copy rather than to the path given:
  /// pointed at a Debug build out of a worktree it starts the deployed one
  /// instead, and pointing at both produced a second-instance storm on this rig
  /// [MEASURED]. It also hands the child no environment, so the dump variable
  /// would never reach it.
  ///
  /// The variable is SET or REMOVED explicitly rather than left to whatever the
  /// probe inherited. A probe run that happened to carry it would otherwise
  /// instrument its own control launch, and the control whose entire job is to
  /// prove the grep can come back empty would be the one thing contaminated.
  func launchDetached(executable: String, panelDump: Bool) -> Process? {
    var environment = ProcessInfo.processInfo.environment
    if panelDump {
      environment[Self.panelDumpVariable] = "1"
    } else {
      environment.removeValue(forKey: Self.panelDumpVariable)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      lastProcessError = "\(executable) did not launch: \(error)"
      return nil
    }
    return process
  }

  /// Stops a child and CONFIRMS it is gone, twice over: the child itself, then
  /// the process table. A terminate that reported success while a second
  /// instance stayed up would leave two DDC writers running under a record that
  /// says one.
  func terminate(_ process: Process) -> Bool {
    let pid = process.processIdentifier
    process.terminate()
    if !poll(timeout: 10, until: { !process.isRunning }) {
      Self.execute("/bin/kill", ["-9", "\(pid)"])
      guard poll(timeout: 5, until: { !process.isRunning }) else {
        lastProcessError =
          "the Debug instance (pid \(pid)) is still running after a terminate and a kill -9"
        return false
      }
    }
    guard waitForNoRunningInstances(timeout: 5) else {
      lastProcessError =
        "the Debug instance (pid \(pid)) stopped, but \(runningInstances().map(\.described).joined(separator: "; ")) is still running"
      return false
    }
    return true
  }

  /// Puts a deployed bundle back the way a person or a login item would,
  /// through LaunchServices. `open` is the right instrument HERE and the wrong
  /// one above: this bundle IS the registered copy, so there is nothing for
  /// LaunchServices to resolve to instead.
  func openBundle(_ path: String) -> Bool {
    let result = Self.execute("/usr/bin/open", ["-a", path])
    guard result.status == 0 else {
      lastProcessError = "open -a \(path) exited \(result.status): \(Self.oneLine(result.err))"
      return false
    }
    return true
  }

  private static func oneLine(_ text: String) -> String {
    let flattened = text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: "; ")
    return flattened.isEmpty ? "nothing on stderr" : flattened
  }

  // MARK: The accessibility layer

  /// One attribute read, with absent kept distinct from present-but-empty and
  /// from unreadable.
  ///
  /// This layer went through System Events first and had to be rebuilt on the
  /// C API, because AppleScript answers accessibility questions with something
  /// else: its `description` is the ROLE description rather than
  /// `AXDescription`, and its attribute lookup resolves against the attribute
  /// NAMES list, which omits `AXDescription` on elements that have a value. A
  /// System Events walk of this app's sidebar therefore reports every row as
  /// carrying no description, while a direct read returns all of them. One
  /// route says a label exists where none does and the other says none exists
  /// where one does; only `AXUIElementCopyAttributeValue` by name separates
  /// absent from present-but-empty, which is the whole question here.
  enum Reading: Equatable {
    case absent
    case empty
    case text(String)
    case unreadable(String)

    /// The value when the attribute is present and non-empty. Deliberately nil
    /// for `.unreadable`: an uncoercible answer is not a present identifier.
    var presentText: String? {
      if case let .text(value) = self { return value }
      return nil
    }

    var describedForDetail: String {
      switch self {
      case .absent: "(absent)"
      case .empty: "(empty)"
      case let .text(value): value
      case let .unreadable(reason): "(unreadable: \(reason))"
      }
    }
  }

  private func read(_ element: AXUIElement, _ attribute: String) -> Reading {
    var value: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    if status == .attributeUnsupported || status == .noValue { return .absent }
    guard status == .success else { return .unreadable("AX error \(status.rawValue)") }
    if let text = value as? String { return text.isEmpty ? .empty : .text(text) }
    if let number = value as? NSNumber { return .text(number.stringValue) }
    return .unreadable("the attribute answered with a non-string value")
  }

  private func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
      == .success, let kids = value as? [AXUIElement]
    else { return [] }
    return kids
  }

  private func canPress(_ element: AXUIElement) -> Bool {
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    return ((names as? [String]) ?? []).contains(kAXPressAction as String)
  }

  /// The two windows Candela owns that are not the settings window. Both come
  /// and go mid-session and both shift every window index.
  private static let decoyWindowNames = [
    "Candela Gamma Activity Enforcer", "Candela OLED Care Overlay",
  ]

  /// Binding the settings window, and the three separate traps it has to
  /// survive.
  ///
  /// Filter on the ROLE first: the windows attribute has been measured holding
  /// elements whose role is AXApplication, and binding one of those walks the
  /// entire application tree while every call reports success. Then exclude
  /// the two decoy windows BY THEIR OWN NAMES, never by a shared prefix: the
  /// settings window is normally named for its pane but has been measured
  /// reporting "Candela Settings", and a prefix rule throws the real window
  /// away exactly then. Never by size, which AppKit autosaves and restores, and
  /// never by index, which the decoys shift as they come and go.
  ///
  /// Failing loudly on a non-unique match is the point of the count check: a
  /// selector that matches nothing reports every control missing, which reads
  /// exactly like a real defect in the app and has already cost one issue
  /// filed against a defect that did not exist.
  func settingsWindow() -> AXUIElement? {
    guard AXIsProcessTrusted() else {
      lastAXError = "this shell has no Accessibility grant, so every accessibility read would come back empty"
      return nil
    }
    // One instance, or nothing: with two Candelas running there is no such
    // thing as "the app's window", and binding one of them would report a
    // measurement of a build nobody named.
    guard let instance = soleRunningInstance(), let pid = Int32(instance.pid) else { return nil }
    let application = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
      == .success, let windows = value as? [AXUIElement]
    else {
      lastAXError = "the app published no windows attribute; open Settings first"
      return nil
    }
    let realWindows = windows.filter {
      read($0, kAXRoleAttribute as String).presentText == "AXWindow"
    }
    let candidates = realWindows.filter { window in
      let name = read(window, kAXTitleAttribute as String).presentText ?? ""
      return !Self.decoyWindowNames.contains { name.hasPrefix($0) }
    }
    guard candidates.count == 1 else {
      let seen = realWindows
        .map { "[\(read($0, kAXTitleAttribute as String).describedForDetail)]" }
        .joined(separator: " ")
      lastAXError = candidates.isEmpty
        ? "no settings window is open (\(realWindows.count) windows, \(windows.count - realWindows.count) non-window elements in the windows attribute): \(seen)"
        : "the settings window is not uniquely identified: \(candidates.count) candidates: \(seen)"
      return nil
    }
    lastAXError = nil
    return candidates[0]
  }

  /// Identifiers are composed from pref names, command names, persistence keys
  /// and slot numbers, so a quote or a backslash in one means the composer has
  /// changed shape rather than that a control needs escaping. Refuse the match
  /// rather than address something the caller did not mean.
  private func isAddressable(_ identifier: String) -> Bool {
    if identifier.contains("\"") || identifier.contains("\\") {
      lastAXError = "the identifier \(identifier) carries a quote or a backslash and cannot be addressed"
      return false
    }
    return true
  }

  func settingsWindowName() -> String? {
    settingsWindow().flatMap { read($0, kAXTitleAttribute as String).presentText }
  }

  /// Where LaunchServices resolves `com.rydersel.Candela` to. A running
  /// instance outside this path is a build LaunchServices does not know about,
  /// which is what makes `open -b` dangerous rather than merely useless.
  private static let registeredBundlePath = "/Applications/Candela.app/"

  /// Binds the settings window, opening it only when there is not one already.
  ///
  /// Three rules, each of them a failure measured live on the rig:
  ///
  /// - **Bind first, open second.** A call that opens before it looks re-issues
  ///   an activation against a window that is already there, which raises and
  ///   re-lays-out the window under a walk that is about to read it.
  /// - **Issue the open ONCE, then poll.** An `open` per poll iteration is a
  ///   LaunchServices relaunch storm; the ten-second bound is measured off a
  ///   deadline rather than counted in sleeps, because the per-poll cost is not
  ///   a constant.
  /// - **Never `open -b` when the running instance is not the registered
  ///   copy.** LaunchServices resolves the bundle identifier to /Applications
  ///   and launches a SECOND instance from there rather than reaching the one
  ///   that is running, which the multi-instance gate then refuses: the run
  ///   ends having measured nothing and changed the rig. There is no way to
  ///   open that instance's settings window from here, so this says so and
  ///   fails rather than spawning a sibling.
  func openSettingsWindow() -> Bool {
    if settingsWindow() != nil { return true }
    guard let instance = soleRunningInstance() else { return false }
    guard instance.path.hasPrefix(Self.registeredBundlePath) else {
      lastAXError = "the running Candela is \(instance.described), not the registered copy at \(Self.registeredBundlePath), and it has no settings window open. Opening by bundle identifier would launch a SECOND instance from /Applications rather than reach this one, so nothing here can open it: open Settings in that instance by hand, or relaunch it with CANDELA_DEBUG_SETTINGS=pane:general"
      return false
    }
    // `open -b` reaches the reopen handler on a RUNNING app, which is what
    // opens the settings scene. The window is polled for rather than assumed:
    // the call returns long before the scene exists.
    Self.execute("/usr/bin/open", ["-b", "com.rydersel.Candela"])
    let deadline = Date().addingTimeInterval(10)
    repeat {
      Thread.sleep(forTimeInterval: 0.25)
      if settingsWindow() != nil { return true }
    } while Date() < deadline
    return false
  }

  /// One walk of the settings window that answers everything the identifier
  /// instrument needs, including both halves of its own control.
  struct AXAudit {
    let walked: Int
    /// Elements carrying a present, non-empty identifier. An unreadable one is
    /// counted separately and never as present.
    let identifiersSeen: Int
    let identifiersUnreadable: Int
    /// The value of the element carrying the wanted identifier, or nil when no
    /// element carries it.
    let targetValue: String?
    let closeButtonFound: Bool
    /// Non-nil only when the close button carries a present identifier, which
    /// would mean an absent reading can no longer be distinguished. An
    /// unreadable close-button identifier reports here as unreadable, so the
    /// control refuses to fire on it.
    let closeButtonIdentifier: Reading?
  }

  private func walk(_ element: AXUIElement, depth: Int, visit: (AXUIElement) -> Void) {
    guard depth <= 24 else { return }
    visit(element)
    for kid in children(element) { walk(kid, depth: depth + 1, visit: visit) }
  }

  func axIdentifierAudit(identifier: String) -> AXAudit? {
    guard isAddressable(identifier) else { return nil }
    guard let window = settingsWindow() else { return nil }
    var walked = 0
    var carriers = 0
    var unreadableIdentifiers = 0
    var targetValue: String?
    var closeButtonFound = false
    var closeButtonIdentifier: Reading?
    walk(window, depth: 0) { element in
      walked += 1
      let carried = read(element, kAXIdentifierAttribute as String)
      switch carried {
      case .text: carriers += 1
      case .unreadable: unreadableIdentifiers += 1
      case .absent, .empty: break
      }
      if carried.presentText == identifier {
        targetValue = read(element, kAXValueAttribute as String).describedForDetail
      }
      if read(element, kAXSubroleAttribute as String).presentText == "AXCloseButton" {
        closeButtonFound = true
        closeButtonIdentifier = carried
      }
    }
    return AXAudit(
      walked: walked,
      identifiersSeen: carriers,
      identifiersUnreadable: unreadableIdentifiers,
      targetValue: targetValue,
      closeButtonFound: closeButtonFound,
      closeButtonIdentifier: closeButtonIdentifier
    )
  }

  /// Locates one element by its accessibility identifier, refusing an
  /// ambiguous match rather than binding the first: two controls answering to
  /// one identifier means the composer is colliding, and driving either of
  /// them would record a measurement of the wrong control.
  private func element(carrying identifier: String) -> AXUIElement? {
    guard isAddressable(identifier), let window = settingsWindow() else { return nil }
    var matches: [AXUIElement] = []
    walk(window, depth: 0) { element in
      if read(element, kAXIdentifierAttribute as String).presentText == identifier {
        matches.append(element)
      }
    }
    guard matches.count == 1 else {
      lastAXError = matches.isEmpty
        ? "no element carries the accessibility identifier \(identifier)"
        : "\(matches.count) elements carry the accessibility identifier \(identifier); refusing rather than guessing"
      return nil
    }
    return matches[0]
  }

  /// A control's value, located by its accessibility identifier rather than by
  /// its display string: a label is user-visible copy that can be reworded,
  /// and a selector written against one silently matches nothing the day it is.
  func axRead(identifier: String) -> String? {
    guard let element = element(carrying: identifier) else { return nil }
    return read(element, kAXValueAttribute as String).presentText
  }

  /// The same read, three-state. `axRead` collapses absent, empty and
  /// unreadable into one nil, which is the right shape for "what does this
  /// control say" and the wrong shape for "may I press it": a drive gated on
  /// nil-ness presses a control whose state before the press was never
  /// established, and the readback afterwards then has nothing to be a change
  /// FROM.
  func axReading(identifier: String) -> Reading {
    guard let element = element(carrying: identifier) else {
      return .unreadable(lastAXError ?? "the control could not be located")
    }
    return read(element, kAXValueAttribute as String)
  }

  /// Sets a checkbox or switch, then READS IT BACK. A toggle that silently
  /// failed and a toggle that worked look identical from the caller's side,
  /// and three measurements in one session were invalidated by exactly that.
  func axToggle(identifier: String, to desired: Bool) -> Bool {
    guard let element = element(carrying: identifier) else { return false }
    let wanted = desired ? "1" : "0"
    let before = read(element, kAXValueAttribute as String)
    if before.presentText != wanted {
      guard canPress(element) else {
        lastAXError = "the control carrying \(identifier) publishes no press action"
        return false
      }
      let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
      guard result == .success else {
        lastAXError = "pressing \(identifier) failed (AX error \(result.rawValue))"
        return false
      }
      Thread.sleep(forTimeInterval: 1.2)
    }
    let after = read(element, kAXValueAttribute as String)
    guard after.presentText == wanted else {
      lastAXError = "the toggle for \(identifier) read back \(after.describedForDetail), wanted \(wanted)"
      return false
    }
    lastAXError = nil
    return true
  }

  /// Presses ONE pressable element by the accessibility description it
  /// publishes, refusing an ambiguous match rather than pressing the first:
  /// two rows answering to one description means the walk cannot say which
  /// destination it opened.
  ///
  /// It reads nothing back on its own, deliberately. A sidebar row's readback
  /// is the window title; a chevron row inside a display's page pushes without
  /// changing that title at all, so the caller supplies whichever readback is
  /// true of the row it pressed. `AXUIElementPerformAction` has been measured
  /// returning `.success` while pushing nothing, so no caller may treat this
  /// return as evidence of arrival.
  func axPress(describedAs description: String) -> Bool {
    guard isAddressable(description), let window = settingsWindow() else { return false }
    var matches: [AXUIElement] = []
    walk(window, depth: 0) { element in
      if read(element, kAXDescriptionAttribute as String).presentText == description,
         canPress(element) {
        matches.append(element)
      }
    }
    guard matches.count == 1 else {
      lastAXError = matches.isEmpty
        ? "no pressable element publishes the accessibility description \(description)"
        : "\(matches.count) pressable elements publish the accessibility description \(description); refusing rather than guessing"
      return false
    }
    let result = AXUIElementPerformAction(matches[0], kAXPressAction as CFString)
    guard result == .success else {
      lastAXError = "pressing the \(description) row failed (AX error \(result.rawValue))"
      return false
    }
    Thread.sleep(forTimeInterval: 1.2)
    lastAXError = nil
    return true
  }

  /// Presses a sidebar row by the accessibility description it publishes, then
  /// reads the window title back. The index table is a property of the current
  /// build and one of its rows is an inert header that leaves the title on the
  /// previous pane rather than erroring, so the title is the only answer worth
  /// trusting.
  func axNavigateSidebar(rowNamed row: String) -> Bool {
    guard axPress(describedAs: row) else { return false }
    // Re-bind rather than reading the title off the pre-press reference, and
    // keep the binding's OWN error when it fails: a non-unique match lists
    // every open window, and overwriting that with "the title reads
    // (unreadable)" would throw the loud failure away for a vaguer one.
    guard let rebound = settingsWindow() else { return false }
    let title = read(rebound, kAXTitleAttribute as String)
    guard title.presentText == row else {
      lastAXError = "the \(row) row was pressed and the window title reads \(title.describedForDetail)"
      return false
    }
    lastAXError = nil
    return true
  }
}
