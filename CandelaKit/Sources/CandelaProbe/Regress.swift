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
/// defaults domain, the media-key poster and the accessibility API, so none of
/// it is unit-testable; the judgement it feeds lives in `AppRegression`, where
/// every verdict is red-tested including its inconclusive third state.
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
    for (interval, span) in [(300.0, "5 minutes"), (3600.0, "1 hour"), (43200.0, "12 hours")] {
      let window = instruments.logWindow(since: Date().addingTimeInterval(-interval))
      answeredCount = window.count
      answeredSpan = span
      if !window.isEmpty { break }
    }
    let logOutcome = annotate(
      AppRegression.logWindowControl(lineCount: answeredCount),
      with: "window: the last \(answeredSpan)")
    checks.append(plainCheck(name: "regress.instrument.log", outcome: logOutcome))
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
    let keysCheck = keysInstrumentCheck(instruments: instruments, target: target)
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
    instruments: RegressInstruments, target: Display?
  ) -> PlatformConformance.Check {
    let name = "regress.instrument.keys"
    guard let target else {
      return skippedCheck(
        name: name,
        reason: "no DDC-capable external display is attached, so no key post can produce a DDC write")
    }
    guard let script = instruments.mediaKeyScript else {
      return plainCheck(name: name, outcome: .fail(
        "the media-key poster was not found: \(instruments.mediaKeySearchDescription); pass --tools <dir>"
      ))
    }

    // The control is a QUIET pre-window. Brightness sync amplifies the
    // built-in's ambient auto-brightness into DDC traffic on every external,
    // and those writes would be read as the ones this check drove.
    let quietStart = Date()
    Thread.sleep(forTimeInterval: 3)
    let preWindow = instruments.logWindow(since: quietStart)
    let preWrites = AppRegression.ddcWriteValues(fromLogLines: preWindow).count
    let control: Control = preWrites == 0
      ? .fired("a quiet 3 s pre-window carried no DDC writes, so the writes below are the posted keys")
      : .didNotFire(
        "the 3 s pre-window already carried \(preWrites) DDC writes, so a write in the drive window would not be attributable to the posted keys; brightness sync fans the built-in's ambient auto-brightness out to every external, so turn it off before this run")

    return controlledCheck(name: name, control: control) {
      let start = Date()
      instruments.warpPointer(toCenterOf: target.id)
      // Down then up: the pair leaves the panel where it found it on the 1/16
      // key grid, so the instrument does not move the rig it measures.
      let down = instruments.postMediaKey("brightnessDown", count: 1)
      Thread.sleep(forTimeInterval: 1)
      let up = instruments.postMediaKey("brightnessUp", count: 1)
      Thread.sleep(forTimeInterval: 2)
      guard down, up else {
        return .fail("the media-key poster failed to run (\(script)); down=\(down) up=\(up)")
      }
      let window = instruments.logWindow(since: start)
      let writes = AppRegression.ddcWriteValues(fromLogLines: window)
      guard writes.count >= 2 else {
        return .fail(
          "two brightness keys aimed at \(target.name) produced \(writes.count) DDC writes in a \(window.count)-line window; the Accessibility grant, the app's event tap or the DDC path is down"
        )
      }
      return .pass(
        "two brightness keys aimed at \(target.name) produced \(writes.count) DDC writes (values \(writes.map(String.init).joined(separator: ", ")))"
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
    // demonstrated by any element carrying any identifier, absent by the
    // window's own close button, which carries none.
    let control: Control
    if audit.walked == 0 {
      control = .didNotFire("the accessibility walk reached zero elements, so nothing was read")
    } else if audit.identifiersSeen == 0 {
      control = .didNotFire(
        "not one of the \(audit.walked) elements walked carries any accessibility identifier, so the reader was never shown a present one and present cannot be told from absent")
    } else if !audit.closeButtonFound {
      control = .didNotFire(
        "the window's close button was not found, so the reader was never shown an element that must have no identifier")
    } else if let carried = audit.closeButtonIdentifier {
      control = .didNotFire(
        "the window's close button carries the identifier \(carried), so an absent reading can no longer be told from a present one on this platform")
    } else {
      control = .fired(
        "\(audit.identifiersSeen) of \(audit.walked) walked elements carry an identifier and the close button carries none, so the reader answers both ways")
    }

    return controlledCheck(name: name, control: control) {
      guard let value = audit.targetValue else {
        return .fail(
          "no element in the settings window carries the accessibility identifier \(wanted) (\(audit.walked) elements walked on the General pane); the running build predates the identifier pass, or the composer no longer emits the bare pref name for an app-level pref"
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
/// out or a CoreGraphics call, and each one reports its own failure rather
/// than returning a plausible default: an instrument that answers with
/// something else is the failure mode this whole command is built against.
final class RegressInstruments {
  let toolsDir: String
  /// The last osascript failure, so a check's detail can name the cause
  /// instead of reporting a control as merely missing.
  private(set) var lastAXError: String?

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

  /// `/usr/bin/log` by absolute path (a bare `log` is a shell builtin here
  /// that prints its complaint to stderr and exits 0, which is indistinguish-
  /// able from an app that logged nothing). `--info --debug` because most of
  /// our lines are below default level, and the process filter because
  /// `swift test` logs into this same subsystem from the test helper.
  func logWindow(since: Date) -> [String] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let result = Self.execute("/usr/bin/log", [
      "show", "--start", formatter.string(from: since), "--info", "--debug",
      "--style", "compact",
      "--predicate", "subsystem == \"com.rydersel.Candela\" AND process == \"Candela\"",
    ])
    return result.out
      .split(separator: "\n")
      .map(String.init)
      .filter { $0.contains(Self.recordTag) }
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
    guard let script = mediaKeyScript else { return false }
    return Self.execute("/usr/bin/swift", [script, name, String(count)]).status == 0
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
  private static let bindSettingsWindow = """
      set candidates to (every window whose role is "AXWindow" and name does not start with "Candela Gamma Activity Enforcer" and name does not start with "Candela OLED Care Overlay")
      if (count of candidates) is not 1 then
        set seen to ""
        repeat with candidate in windows
          set nm to "(unnamed)"
          try
            set nm to name of candidate as text
          end try
          set seen to seen & " [" & nm & "]"
        end repeat
        error "the settings window is not uniquely identified: " & (count of candidates) & " candidates:" & seen
      end if
      set w to item 1 of candidates
    """

  private func osascript(_ body: String) -> String? {
    let script = """
    tell application "System Events"
      tell process "Candela"
    \(Self.bindSettingsWindow)
    \(body)
      end tell
    end tell
    """
    let result = Self.execute("/usr/bin/osascript", ["-e", script])
    guard result.status == 0 else {
      lastAXError = result.err
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: "; ")
      return nil
    }
    lastAXError = nil
    return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Identifiers are composed from pref names and persistence keys, so a quote
  /// or a backslash in one means the composer has changed shape rather than
  /// that a control needs escaping. Refuse rather than build a script that
  /// would silently address something else.
  private func isAddressable(_ identifier: String) -> Bool {
    if identifier.contains("\"") || identifier.contains("\\") {
      lastAXError = "the identifier \(identifier) carries a quote or a backslash and cannot be addressed"
      return false
    }
    return true
  }

  func settingsWindowName() -> String? {
    osascript("    return name of w")
  }

  /// `open -b` reaches the reopen handler on a RUNNING app, which is what
  /// opens the settings scene. The window is then polled for rather than
  /// assumed: the call returns long before the scene exists.
  func openSettingsWindow() -> Bool {
    Self.execute("/usr/bin/open", ["-b", "com.rydersel.Candela"])
    for _ in 0 ..< 20 {
      if settingsWindowName() != nil { return true }
      Thread.sleep(forTimeInterval: 0.5)
    }
    return false
  }

  /// One walk of the settings window that answers everything the identifier
  /// instrument needs, including both halves of its own control.
  struct AXAudit {
    let walked: Int
    let identifiersSeen: Int
    /// The value of the element carrying the wanted identifier, or nil when
    /// no element carries it.
    let targetValue: String?
    let closeButtonFound: Bool
    /// Non-nil only when the close button carries an identifier, which would
    /// mean an absent reading can no longer be distinguished.
    let closeButtonIdentifier: String?
  }

  func axIdentifierAudit(identifier: String) -> AXAudit? {
    guard isAddressable(identifier) else { return nil }
    // The list is materialised before the walk: iterating `entire contents`
    // directly hands back references that cannot always be resolved.
    let body = """
        set els to entire contents of w
        set walked to 0
        set carriers to 0
        set target to "(absent)"
        set closeSeen to "no"
        set closeIdentifier to "(absent)"
        repeat with el in els
          set walked to walked + 1
          set thisIdentifier to "(absent)"
          try
            set thisIdentifier to (value of attribute "AXIdentifier" of el) as text
          end try
          if thisIdentifier is not "(absent)" and thisIdentifier is not "missing value" then
            set carriers to carriers + 1
            if thisIdentifier is "\(identifier)" then
              set target to "(unreadable)"
              try
                set target to (value of el) as text
              end try
            end if
          end if
          set thisSubrole to ""
          try
            set thisSubrole to (value of attribute "AXSubrole" of el) as text
          end try
          if thisSubrole is "AXCloseButton" then
            set closeSeen to "yes"
            set closeIdentifier to thisIdentifier
          end if
        end repeat
        return "walked=" & walked & ";carriers=" & carriers & ";target=" & target & ";close=" & closeSeen & ";closeIdentifier=" & closeIdentifier
    """
    guard let output = osascript(body) else { return nil }
    var fields: [String: String] = [:]
    for pair in output.split(separator: ";") {
      let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
      if parts.count == 2 { fields[parts[0]] = parts[1] }
    }
    guard let walked = fields["walked"].flatMap(Int.init),
          let carriers = fields["carriers"].flatMap(Int.init)
    else {
      lastAXError = "the accessibility walk returned an unparseable line: \(output)"
      return nil
    }
    let closeIdentifier = fields["closeIdentifier"]
    return AXAudit(
      walked: walked,
      identifiersSeen: carriers,
      targetValue: fields["target"] == "(absent)" ? nil : fields["target"],
      closeButtonFound: fields["close"] == "yes",
      closeButtonIdentifier: closeIdentifier == "(absent)" || closeIdentifier == "missing value"
        ? nil : closeIdentifier
    )
  }

  /// A control's value, located by its accessibility identifier rather than by
  /// its display string: a label is user-visible copy that can be reworded,
  /// and a selector written against one silently matches nothing the day it is.
  func axRead(identifier: String) -> String? {
    axIdentifierAudit(identifier: identifier)?.targetValue
  }

  /// Sets a checkbox or switch, then READS IT BACK. A toggle that silently
  /// failed and a toggle that worked look identical from the caller's side,
  /// and three measurements in one session were invalidated by exactly that.
  func axToggle(identifier: String, to desired: Bool) -> Bool {
    guard isAddressable(identifier) else { return false }
    let body = """
        set els to entire contents of w
        repeat with el in els
          set thisIdentifier to "(absent)"
          try
            set thisIdentifier to (value of attribute "AXIdentifier" of el) as text
          end try
          if thisIdentifier is "\(identifier)" then
            set before to (value of el) as text
            if before is not "\(desired ? "1" : "0")" then
              click el
              delay 1.2
            end if
            return "before=" & before & ";after=" & ((value of el) as text)
          end if
        end repeat
        error "no element carries the accessibility identifier \(identifier)"
    """
    guard let output = osascript(body) else { return false }
    guard let after = output.split(separator: ";")
      .first(where: { $0.hasPrefix("after=") })?
      .dropFirst("after=".count)
    else {
      lastAXError = "the toggle returned an unparseable line: \(output)"
      return false
    }
    let landed = String(after) == (desired ? "1" : "0")
    if !landed {
      lastAXError = "the toggle for \(identifier) read back \(after), wanted \(desired ? 1 : 0)"
    }
    return landed
  }

  /// Clicks a sidebar row by the accessibility description it publishes, then
  /// reads the window title back. The index table is a property of the current
  /// build and one of its rows is an inert header that leaves the title on the
  /// previous pane rather than erroring, so the title is the only answer worth
  /// trusting.
  func axNavigateSidebar(rowNamed row: String) -> Bool {
    guard isAddressable(row) else { return false }
    let body = """
        set els to entire contents of w
        repeat with el in els
          set thisDescription to ""
          try
            set thisDescription to (value of attribute "AXDescription" of el) as text
          end try
          if thisDescription is "\(row)" then
            click el
            delay 1.2
            return "clicked"
          end if
        end repeat
        error "no sidebar row publishes the accessibility description \(row)"
    """
    guard osascript(body) == "clicked" else { return false }
    let title = settingsWindowName()
    if title != row {
      lastAXError = "the row \(row) was clicked and the window title reads \(title ?? "(unreadable)")"
      return false
    }
    return true
  }
}
