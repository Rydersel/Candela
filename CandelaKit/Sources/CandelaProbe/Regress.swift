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
    let name: String
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

  /// The ONE builder for a driven check, so the record's invariant holds by
  /// construction rather than by everyone remembering it: the verdict closure
  /// is consulted only when the control fired, and a control that did not fire
  /// produces `.inconclusive` with the control recorded as failed. An
  /// inconclusive verdict downgrades the control too, because an inconclusive
  /// outcome means some control half was absent whichever half it was. There
  /// is therefore no path through this function that pairs a pass with a
  /// failed control.
  static func controlledCheck(
    name: String, control: Control, verdict: () -> PlatformConformance.Outcome
  ) -> PlatformConformance.Check {
    switch control {
    case let .didNotFire(reason):
      return .init(name: name, outcome: .inconclusive(reason), control: .failed)
    case let .fired(fired):
      let outcome = verdict()
      if case .inconclusive = outcome {
        return .init(name: name, outcome: outcome, control: .failed)
      }
      return .init(name: name, outcome: annotate(outcome, with: "control: \(fired)"), control: .fired)
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

  /// Appends to a pass or a fail detail only. A skip's reason names why the
  /// check did not run, and an inconclusive's names the control that did not
  /// fire; neither wants a measurement's aside stapled to it.
  private static func annotate(_ outcome: PlatformConformance.Outcome, with note: String)
    -> PlatformConformance.Outcome
  {
    switch outcome {
    case let .pass(detail): .pass("\(detail); \(note)")
    case let .fail(detail): .fail("\(detail); \(note)")
    default: outcome
    }
  }

  // MARK: - The run

  /// What the preflights established, for the driven checks that come after
  /// them. A driven check whose instrument is unproven reports
  /// `.inconclusive`, never `.fail`: an unproven instrument cannot convict the
  /// app of anything.
  struct Preflight {
    let checks: [PlatformConformance.Check]
    let appRunning: Bool
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
    report.checks += preflight(instruments: instruments, displays: displays).checks
    return report
  }

  // MARK: Preflight

  /// Six instrument checks, each a REPORTED check rather than a silent
  /// precondition. Every later check consumes them, and a suite whose
  /// instruments were never asserted is a suite whose green means nothing.
  static func preflight(instruments: RegressInstruments, displays: [Display]) -> Preflight {
    var checks: [PlatformConformance.Check] = []

    // 1. Is the app running at all? Everything else asks questions about a
    //    process, so this one gates the rest.
    let pids = instruments.runningPIDs()
    checks.append(plainCheck(
      name: "regress.app.running",
      outcome: pids.isEmpty
        ? .fail("no Candela process is running; there is no deployed build to assert anything about")
        : .pass("Candela is running (pid \(pids.joined(separator: ", ")))")
    ))
    guard !pids.isEmpty else {
      let reason = "the app is not running (see regress.app.running)"
      checks += [
        "regress.instrument.log", "regress.instrument.gamma", "regress.instrument.keys",
        "regress.instrument.identifiers", "regress.instrument.prefs",
      ].map { skippedCheck(name: $0, reason: reason) }
      return Preflight(
        checks: checks, appRunning: false, logProven: false, gammaProven: false,
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
    } ?? annotate(
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
    let target = displays.first { $0.persistenceKey != nil && !$0.isBuiltIn }
    let keysCheck = keysInstrumentCheck(
      instruments: instruments, target: target, logProven: logProven)
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
      appRunning: true,
      logProven: logProven,
      gammaProven: isPass(gammaOutcome),
      keysProven: keysProven,
      identifiersProven: isPass(identifiersCheck.outcome),
      prefsProven: isPass(prefsCheck.outcome),
      keyTarget: target
    )
  }

  private static func keysInstrumentCheck(
    instruments: RegressInstruments, target: Display?, logProven: Bool
  ) -> PlatformConformance.Check {
    let name = "regress.instrument.keys"
    guard let target else {
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

    return controlledCheck(name: name, control: control) {
      let start = Date()
      instruments.warpPointer(toCenterOf: target.id)
      // brightnessDown then brightnessUp: the pair leaves the panel where it
      // found it on the 1/16 key grid, so the instrument does not move the rig
      // it measures.
      let down = instruments.postMediaKey("brightnessDown", count: 1)
      Thread.sleep(forTimeInterval: 1)
      let up = instruments.postMediaKey("brightnessUp", count: 1)
      Thread.sleep(forTimeInterval: 2)
      guard down, up else {
        return .fail(
          "the media-key poster failed to run (brightnessDown ran: \(down), brightnessUp ran: \(up)): \(instruments.lastPosterError ?? "no reason reported")"
        )
      }
      let window = instruments.logWindow(since: start)
      guard !window.queryFailed else {
        return .fail("the drive window's log query failed: \(window.failureReason)")
      }
      let writes = AppRegression.ddcWriteValues(fromLogLines: window.lines)
      guard writes.count >= 2 else {
        return .fail(
          "brightnessDown then brightnessUp aimed at \(target.name) produced \(writes.count) DDC writes in a \(window.count)-line window; the Accessibility grant, the app's event tap or the DDC path is down"
        )
      }
      return .pass(
        "brightnessDown then brightnessUp aimed at \(target.name) produced \(writes.count) DDC writes (values \(writes.map(String.init).joined(separator: ", ")))"
      )
    }
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
  /// Why the last media-key post did not run, carrying the script's own
  /// stderr: "the poster failed" on its own is the silence this command
  /// refuses everywhere else.
  private(set) var lastPosterError: String?

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
  func postMediaKey(_ name: String, count: Int) -> Bool {
    guard let script = mediaKeyScript else {
      lastPosterError = mediaKeySearchDescription
      return false
    }
    let result = Self.execute("/usr/bin/swift", [script, name, String(count)])
    guard result.status != 0 else {
      lastPosterError = nil
      return true
    }
    let stderr = result.err
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: "; ")
    lastPosterError = "\(script) \(name) exited \(result.status): "
      + (stderr.isEmpty ? "nothing on stderr" : stderr)
    return false
  }

  /// Brightness keys target the display under the pointer, so aiming is how a
  /// key press is addressed to one panel.
  func warpPointer(toCenterOf id: CGDirectDisplayID) {
    let bounds = CGDisplayBounds(id)
    CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
    CGAssociateMouseAndMouseCursorPosition(1)
  }

  // MARK: The app process

  func runningPIDs() -> [String] {
    let result = Self.execute("/usr/bin/pgrep", ["-x", "Candela"])
    guard result.status == 0 else { return [] }
    return result.out.split(whereSeparator: \.isNewline).map(String.init)
  }

  func appIsRunning() -> Bool { !runningPIDs().isEmpty }

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
    guard let pid = runningPIDs().first.flatMap(Int32.init) else {
      lastAXError = "no Candela process to read an accessibility tree from"
      return nil
    }
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

  /// `open -b` reaches the reopen handler on a RUNNING app, which is what
  /// opens the settings scene. The window is then polled for rather than
  /// assumed: the call returns long before the scene exists. The bound is a
  /// real ten seconds, measured off a deadline rather than counted in sleeps,
  /// because the per-poll cost is not a constant.
  func openSettingsWindow() -> Bool {
    Self.execute("/usr/bin/open", ["-b", "com.rydersel.Candela"])
    let deadline = Date().addingTimeInterval(10)
    repeat {
      if settingsWindow() != nil { return true }
      Thread.sleep(forTimeInterval: 0.25)
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

  /// Presses a sidebar row by the accessibility description it publishes, then
  /// reads the window title back. The index table is a property of the current
  /// build and one of its rows is an inert header that leaves the title on the
  /// previous pane rather than erroring, so the title is the only answer worth
  /// trusting.
  func axNavigateSidebar(rowNamed row: String) -> Bool {
    guard isAddressable(row), let window = settingsWindow() else { return false }
    var matches: [AXUIElement] = []
    walk(window, depth: 0) { element in
      if read(element, kAXDescriptionAttribute as String).presentText == row, canPress(element) {
        matches.append(element)
      }
    }
    guard matches.count == 1 else {
      lastAXError = matches.isEmpty
        ? "no pressable sidebar row publishes the accessibility description \(row)"
        : "\(matches.count) pressable elements publish the accessibility description \(row); refusing rather than guessing"
      return false
    }
    let result = AXUIElementPerformAction(matches[0], kAXPressAction as CFString)
    guard result == .success else {
      lastAXError = "pressing the \(row) row failed (AX error \(result.rawValue))"
      return false
    }
    Thread.sleep(forTimeInterval: 1.2)
    let title = settingsWindowName()
    guard title == row else {
      lastAXError = "the \(row) row was pressed and the window title reads \(title ?? "(unreadable)")"
      return false
    }
    lastAXError = nil
    return true
  }
}
