#if DEBUG
  import Foundation

  /// Opens the settings window on a named destination so screenshot validation
  /// can reach a pane nothing else can: without an Accessibility grant
  /// nothing can click the sidebar from a script, and Candela has no URL scheme.
  ///
  /// The file and both call sites are inside `#if DEBUG`, so Release keeps no
  /// residue by construction rather than by discipline.
  ///
  /// Trigger: `CANDELA_DEBUG_SETTINGS`, read ONCE at launch. An env var cannot be
  /// set by accident on a user's machine and a plain `open` never sets it. Usage:
  ///
  ///   CANDELA_DEBUG_SETTINGS=pane:<PaneID>
  ///   CANDELA_DEBUG_SETTINGS=pane:oledCare/<key|first>[/display|/health]
  ///   CANDELA_DEBUG_SETTINGS=pane:keyboard/<KeyboardPage>
  ///   CANDELA_DEBUG_SETTINGS=setup:mock   (guided setup over the rig fixture)
  ///   CANDELA_DEBUG_SETTINGS=display:<builtIn|first|key>[/<DisplaySubPage>]
  ///
  /// `/health` opens the Display Health WINDOW over the display page; it is
  /// not a pushed page.
  ///
  /// Both id spaces are CASE-SENSITIVE and camelCase: `pane:menuBar`, not
  /// `pane:menubar`. Valid ids come from the enums, and so does every rejection
  /// message, so this comment cannot go stale into a lie.
  ///
  /// `display:first` resolves the first connected EXTERNAL display's persistence
  /// key, the one a capture script cannot know in advance.
  ///
  /// Every outcome, resolved or rejected, prints ONE line to stderr tagged
  /// `[CANDELA_DEBUG_SETTINGS]`. Without it an unset variable, a bad value, an
  /// unknown pane and a `SettingsOpener.open()` that no-ops are the same
  /// non-event, and the capture run gets repeated just to learn which it hit.
  @MainActor
  enum DebugSettingsHook {
    static let environmentKey = "CANDELA_DEBUG_SETTINGS"

    /// Set by `openIfRequested`, adopted by `SettingsRootView.onAppear`: the root
    /// view owns its selection as `@State`, so there is nothing to write until it
    /// exists.
    static var pendingSelection: SettingsDestination?
    /// Only ever set alongside a `.display` `pendingSelection`; the root view
    /// seeds that display's navigation path with it.
    static var pendingSubPage: DisplaySubPage?
    /// Only ever set alongside `pane:oledCare`: the pushed-page path to open on.
    /// The hub link and the pane's rows cannot be clicked without an Accessibility
    /// grant, so without this the pushed pages have no route to a screenshot.
    static var pendingOledPath: [OledCarePage]?
    /// Only ever set alongside `pane:keyboard`: same job as `pendingOledPath`
    /// for the Keyboard pane's pushed pages.
    static var pendingKeyboardPath: [KeyboardPage]?
    /// Only ever set alongside `pane:oledCare/<key>/health`: Display Health is a
    /// WINDOW, not a pushed page, so the capture route opens it over the
    /// display page.
    static var pendingHealthWindowKey: String?

    /// A parse that carries its own reason for failing: `SettingsDestination?`
    /// cannot distinguish a typo'd pane id from a display that is not plugged in,
    /// and those want opposite responses from whoever drives the capture.
    enum Resolution {
      case resolved(
        SettingsDestination, subPage: DisplaySubPage?, oledPath: [OledCarePage]?,
        keyboardPath: [KeyboardPage]?, healthWindowKey: String?)
      /// `setup:mock`: not a settings destination at all; the guided setup
      /// flow in its own window, over the fixture environment.
      case presentSetupMock
      case rejected(String)
    }

    /// Parsed separately from the opening so a bad value is a REPORTED no-op
    /// rather than a silent open on some OTHER pane: a screenshot of the wrong
    /// pane looks like evidence.
    ///
    /// `display:` validates too, not for symmetry: `SettingsDestination` accepts
    /// an unknown key happily and `SettingsRootView` then renders
    /// `generalFallback` under a toolbar reading "General", which looks exactly
    /// like a deliberate capture of the General pane.
    static func resolve(_ value: String, externalKeys: [String]) -> Resolution {
      let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else {
        return .rejected(
          "\(quoted(value)) is not <kind>:<id>; expected pane:<id>, display:<key> or setup:mock")
      }
      let body = String(parts[1])
      switch parts[0] {
      case "setup":
        switch body {
        case "mock": return .presentSetupMock
        default:
          return .rejected(
            "unknown setup value \(quoted(body)); ids are case-sensitive: mock")
        }
      case "pane":
        // Optional suffixes, accepted only on the panes with pushed pages.
        // Rejected elsewhere rather than ignored: a suffix that silently did
        // nothing would capture the top of a pane and look like evidence.
        let segments = body.split(separator: "/", omittingEmptySubsequences: false)
        // Named rather than left to the unknown-pane message: capture scripts
        // written before the merge still ask for it, and "unknown pane" would
        // not say where the update controls went.
        if segments[0] == "updates" {
          return .rejected("the Updates pane merged into About; its controls are the About page's now, so use 'pane:about'")
        }
        guard let id = PaneID(rawValue: String(segments[0])) else {
          let known = PaneID.allCases.map(\.rawValue).joined(separator: ", ")
          return .rejected("unknown pane \(quoted(String(segments[0]))); ids are case-sensitive: \(known)")
        }
        guard segments.count > 1 else {
          return .resolved(.pane(id), subPage: nil, oledPath: nil, keyboardPath: nil, healthWindowKey: nil)
        }
        if id == .keyboard {
          guard segments.count == 2 else {
            return .rejected("pane:keyboard takes at most one /<page>")
          }
          guard let page = KeyboardPage(rawValue: String(segments[1])) else {
            let known = KeyboardPage.allCases.map(\.rawValue).joined(separator: ", ")
            return .rejected("unknown keyboard page \(quoted(String(segments[1]))); ids are case-sensitive: \(known)")
          }
          return .resolved(.pane(id), subPage: nil, oledPath: nil, keyboardPath: [page], healthWindowKey: nil)
        }
        guard id == .oledCare else {
          return .rejected("pane \(quoted(id.rawValue)) takes no suffix; only 'oledCare' and 'keyboard' do")
        }
        guard segments.count <= 3 else {
          return .rejected("pane:oledCare takes at most /<displayKey>/<page>")
        }
        let targetBody = String(segments[1])
        let key: String
        if targetBody == "first" {
          guard let first = externalKeys.first else {
            return .rejected("pane:oledCare/first found no external display connected")
          }
          key = first
        } else {
          guard externalKeys.contains(targetBody) else {
            let list = externalKeys.map(quoted).joined(separator: ", ")
            return .rejected("unknown display key \(quoted(targetBody)); connected externals: \(list)")
          }
          key = targetBody
        }
        let path: [OledCarePage] = [.display(key)]
        var healthWindowKey: String?
        if segments.count == 3 {
          // Validated like everything else here: a typo'd page must not
          // silently capture the display page.
          switch String(segments[2]) {
          case "display": break
          // A window, not a page: the display page stays behind it.
          case "health": healthWindowKey = key
          // Named rather than left to the default: capture scripts written
          // earlier still ask for it, and "unknown page" would not say where
          // the controls went.
          case "measurement":
            return .rejected("the OLED Care measurement page retired; its controls are on the Health pane, so use 'pane:health'")
          default:
            return .rejected("unknown OLED page \(quoted(String(segments[2]))); ids are case-sensitive: display, health")
          }
        }
        return .resolved(
          .pane(id), subPage: nil, oledPath: path, keyboardPath: nil,
          healthWindowKey: healthWindowKey)
      case "display":
        // Optional `/subPage` suffix. Validated like everything else here: a
        // typo'd sub-page must not silently capture the hub.
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
        // slot) but it IS a real destination: `SettingsRootView` routes the
        // literal key "builtIn" to `BuiltInDisplayPane`.
        let known = ["builtIn"] + externalKeys
        if keyBody == "first" {
          guard let key = externalKeys.first else {
            return .rejected("display:first found no external display connected; try display:builtIn")
          }
          return .resolved(.display(key), subPage: subPage, oledPath: nil, keyboardPath: nil, healthWindowKey: nil)
        }
        guard known.contains(keyBody) else {
          let list = known.map(quoted).joined(separator: ", ")
          return .rejected("unknown display key \(quoted(keyBody)); connected: \(list)")
        }
        return .resolved(.display(keyBody), subPage: subPage, oledPath: nil, keyboardPath: nil, healthWindowKey: nil)
      default:
        return .rejected("unknown kind \(quoted(String(parts[0]))); expected pane, display or setup")
      }
    }

    /// The shape most callers want; `resolve` is the one that can say why.
    static func destination(from value: String, externalKeys: [String]) -> SettingsDestination? {
      guard case let .resolved(destination, _, _, _, _) = resolve(value, externalKeys: externalKeys)
      else {
        return nil
      }
      return destination
    }

    /// Called once, at the end of launch and AFTER the first display refresh:
    /// `display:first` needs the display list to exist.
    static func openIfRequested(externalKeys: [String]) {
      guard let value = ProcessInfo.processInfo.environment[environmentKey] else {
        // Silent: this is every ordinary Debug launch.
        return
      }
      switch resolve(value, externalKeys: externalKeys) {
      case let .resolved(destination, subPage, oledPath, keyboardPath, healthWindowKey):
        log(
          "opening \(describe(destination, subPage: subPage, oledPath: oledPath, keyboardPath: keyboardPath, healthWindowKey: healthWindowKey))"
        )
        // Set BEFORE opening: `SettingsRootView.onAppear` runs as part of the
        // window coming up, so a later assignment would miss it entirely.
        pendingSelection = destination
        pendingSubPage = subPage
        pendingOledPath = oledPath
        pendingKeyboardPath = keyboardPath
        pendingHealthWindowKey = healthWindowKey
        SettingsOpener.open()
      case .presentSetupMock:
        log("presenting the guided setup mock")
        OnboardingMockPresenter.present()
      case let .rejected(reason):
        log("ignored: \(reason)")
      }
    }

    private static func describe(
      _ destination: SettingsDestination, subPage: DisplaySubPage?, oledPath: [OledCarePage]?,
      keyboardPath: [KeyboardPage]?, healthWindowKey: String?
    ) -> String {
      switch destination {
      case let .pane(id):
        "pane \(quoted(id.rawValue))"
          + (oledPath.map { ", pushed to \(quoted($0.map(describe).joined(separator: "/")))" } ?? "")
          + (keyboardPath.map { ", pushed to \(quoted($0.map(\.rawValue).joined(separator: "/")))" } ?? "")
          + (healthWindowKey.map { ", health window for \(quoted($0))" } ?? "")
      case let .display(key):
        "display \(quoted(key))" + (subPage.map { ", sub-page \(quoted($0.rawValue))" } ?? "")
      }
    }

    private static func describe(_ page: OledCarePage) -> String {
      switch page {
      case let .display(key): "display(\(key))"
      }
    }

    private static func quoted(_ value: some StringProtocol) -> String { "'\(value)'" }

    /// stderr, not `print`: a capture run reads the app's output back, and stdout
    /// is where everything else it prints lands. One tag, one line, greppable.
    private static func log(_ message: String) {
      FileHandle.standardError.write(Data("[\(environmentKey)] \(message)\n".utf8))
    }
  }
#endif
