#if DEBUG
  import Foundation

  /// Opens the settings window on a named destination so screenshot validation
  /// (DT6) can reach a pane nothing else can reach: Accessibility is not
  /// granted, so no agent can click the sidebar, and Candela has no URL scheme
  /// (that is W4).
  ///
  /// The WHOLE file is inside `#if DEBUG`, and so are both call sites — the
  /// `#if` in `SettingsRootView` wraps the `.onAppear` modifier itself, not its
  /// closure body, so Release keeps no residue of it at all. Compiled out of
  /// Release BY CONSTRUCTION, not by remembering to delete it — the standing
  /// review step (grep EVERY Mach-O in the Release bundle for debug markers,
  /// with a Debug positive control, because a Debug app's code lives in
  /// `Candela.debug.dylib` and grepping only the stub passes vacuously) is what
  /// proves it, and a `CANDELA_TOOLBAR_STYLE` env switch once reached a Release
  /// build precisely because it was guarded by discipline instead.
  ///
  /// Trigger: the `CANDELA_DEBUG_SETTINGS` environment variable, read ONCE at
  /// launch. An env var rather than a notification or a hidden menu item
  /// because it cannot be set by accident on a user's machine and leaves no
  /// residue — a plain `open` of the app never sets it. Usage:
  ///
  ///   CANDELA_DEBUG_SETTINGS=pane:general    Candela.app/Contents/MacOS/Candela
  ///   CANDELA_DEBUG_SETTINGS=pane:menuBar    (also: pane:arrangement,
  ///                                           pane:keyboard, pane:about)
  ///   CANDELA_DEBUG_SETTINGS=display:builtIn
  ///   CANDELA_DEBUG_SETTINGS=display:first
  ///   CANDELA_DEBUG_SETTINGS=display:<persistenceKey>
  ///   CANDELA_DEBUG_SETTINGS=display:first/allModes   (also: /advanced,
  ///                                           /diagnostics — opens the display
  ///                                           destination with that sub-page
  ///                                           already pushed; Task 9's stack
  ///                                           has no pushing rows until the
  ///                                           hub lands, and later capture
  ///                                           runs want sub-pages directly)
  ///
  /// Both id spaces are CASE-SENSITIVE and camelCase: `pane:menuBar`, not
  /// `pane:menubar`; `display:builtIn`, not `display:builtin`. The valid pane
  /// ids are exactly `PaneID.allCases`, and a rejection message lists them from
  /// that enum rather than from this comment, so the spelling never has to be
  /// guessed twice and this list cannot go stale into a lie.
  ///
  /// `display:first` resolves the first connected EXTERNAL display's
  /// persistence key, which is the one a capture script cannot know in advance.
  ///
  /// Every outcome — resolved or rejected — prints ONE line to stderr tagged
  /// `[CANDELA_DEBUG_SETTINGS]`. Without it, six different failures (unset var,
  /// unparseable value, unknown pane, unknown display key, `display:first` with
  /// no external attached, and a `SettingsOpener.open()` that took the branch
  /// documented as a no-op on macOS 26) are one indistinguishable non-event,
  /// and a capture run has to be repeated with different inputs just to learn
  /// which one it hit. That truth table was built by hand once; the line means
  /// nobody builds it again.
  @MainActor
  enum DebugSettingsHook {
    static let environmentKey = "CANDELA_DEBUG_SETTINGS"

    /// Set by `openIfRequested` and adopted by `SettingsRootView.onAppear`.
    /// The root view owns its selection as `@State`, so there is nothing to
    /// write to from outside until the view exists.
    static var pendingSelection: SettingsDestination?
    /// Only ever set alongside a `.display` `pendingSelection`; the root view
    /// seeds that display's navigation path with it.
    static var pendingSubPage: DisplaySubPage?

    /// A parse that carries its own reason for failing. The reason is the whole
    /// point: `SettingsDestination?` cannot distinguish "you typo'd the pane
    /// id" from "the display you asked for is not plugged in", and those want
    /// opposite responses from whoever is driving the capture.
    enum Resolution {
      case resolved(SettingsDestination, subPage: DisplaySubPage?)
      case rejected(String)
    }

    /// Parsed separately from the opening so a bad value is a REPORTED no-op
    /// rather than a silent open on some OTHER pane — a screenshot of the wrong
    /// pane is worse than no screenshot, because it looks like evidence.
    ///
    /// Both branches validate against the real id space. `display:` validating
    /// is not symmetry for its own sake: an unknown key is accepted by
    /// `SettingsDestination` quite happily, and `SettingsRootView` then renders
    /// `generalFallback` under a toolbar reading "General" with no sidebar row
    /// selected — a window that looks exactly like a deliberate capture of the
    /// General pane. That is the precise failure this type exists to prevent.
    static func resolve(_ value: String, externalKeys: [String]) -> Resolution {
      let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else {
        return .rejected("\(quoted(value)) is not <kind>:<id>; expected pane:<id> or display:<key>")
      }
      let body = String(parts[1])
      switch parts[0] {
      case "pane":
        guard let id = PaneID(rawValue: body) else {
          let known = PaneID.allCases.map(\.rawValue).joined(separator: ", ")
          return .rejected("unknown pane \(quoted(body)); ids are case-sensitive: \(known)")
        }
        return .resolved(.pane(id), subPage: nil)
      case "display":
        // Optional `/subPage` suffix pushes that sub-page onto the display's
        // navigation stack. Validated like everything else here: a typo'd
        // sub-page must not silently capture the hub.
        let segments = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let keyBody = String(segments[0])
        var subPage: DisplaySubPage?
        if segments.count == 2 {
          guard let page = DisplaySubPage(rawValue: String(segments[1])) else {
            let known = DisplaySubPage.allCases.map(\.rawValue).joined(separator: ", ")
            return .rejected("unknown sub-page \(quoted(String(segments[1]))); ids are case-sensitive: \(known)")
          }
          subPage = page
        }
        // The built-in is not in `externalKeys` (AppModel keeps it in its own
        // slot), but it IS a real destination — `SettingsRootView` routes the
        // literal key "builtIn" to `BuiltInDisplayPane`.
        let known = ["builtIn"] + externalKeys
        if keyBody == "first" {
          guard let key = externalKeys.first else {
            return .rejected("display:first found no external display connected; try display:builtIn")
          }
          return .resolved(.display(key), subPage: subPage)
        }
        guard known.contains(keyBody) else {
          let list = known.map(quoted).joined(separator: ", ")
          return .rejected("unknown display key \(quoted(keyBody)); connected: \(list)")
        }
        return .resolved(.display(keyBody), subPage: subPage)
      default:
        return .rejected("unknown kind \(quoted(String(parts[0]))); expected pane or display")
      }
    }

    /// Kept as the brief's named interface, and as the shape most callers want.
    /// `resolve` is the one that can say why.
    static func destination(from value: String, externalKeys: [String]) -> SettingsDestination? {
      guard case let .resolved(destination, _) = resolve(value, externalKeys: externalKeys) else {
        return nil
      }
      return destination
    }

    /// Called once, at the end of launch and AFTER the first display refresh —
    /// `display:first` needs the display list to exist.
    static func openIfRequested(externalKeys: [String]) {
      guard let value = ProcessInfo.processInfo.environment[environmentKey] else {
        // Deliberately silent: this is the normal case for every ordinary Debug
        // launch, and a line here would be noise in every single one.
        return
      }
      switch resolve(value, externalKeys: externalKeys) {
      case let .resolved(destination, subPage):
        log("opening \(describe(destination, subPage: subPage))")
        // Set BEFORE opening: `SettingsRootView.onAppear` runs as part of the
        // window coming up, so a later assignment would miss it entirely.
        pendingSelection = destination
        pendingSubPage = subPage
        SettingsOpener.open()
      case let .rejected(reason):
        log("ignored: \(reason)")
      }
    }

    private static func describe(_ destination: SettingsDestination, subPage: DisplaySubPage?) -> String {
      switch destination {
      case let .pane(id): "pane \(quoted(id.rawValue))"
      case let .display(key):
        "display \(quoted(key))" + (subPage.map { ", sub-page \(quoted($0.rawValue))" } ?? "")
      }
    }

    private static func quoted(_ value: some StringProtocol) -> String { "'\(value)'" }

    /// stderr, not `print`: a capture run redirects the app's output to a log
    /// and reads it back, and stdout is where anything else the app prints
    /// would land. One tag, one line, greppable.
    private static func log(_ message: String) {
      FileHandle.standardError.write(Data("[\(environmentKey)] \(message)\n".utf8))
    }
  }
#endif
