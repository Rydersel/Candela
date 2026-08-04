#if DEBUG
  import AppKit
  import Foundation

  /// Opens the settings window on a named destination so screenshot validation
  /// (DT6) can reach a pane nothing else can reach: Accessibility is not
  /// granted, so no agent can click the sidebar, and Candela has no URL scheme
  /// (that is W4).
  ///
  /// The WHOLE file is inside `#if DEBUG`, and so are both call sites. Compiled
  /// out of Release BY CONSTRUCTION, not by remembering to delete it — the
  /// standing review step (grep the Release binary for debug markers) is what
  /// proves it, and a `CANDELA_TOOLBAR_STYLE` env switch once reached a Release
  /// build precisely because it was guarded by discipline instead.
  ///
  /// Trigger: the `CANDELA_DEBUG_SETTINGS` environment variable, read ONCE at
  /// launch. An env var rather than a notification or a hidden menu item
  /// because it cannot be set by accident on a user's machine and leaves no
  /// residue — a plain `open` of the app never sets it. Usage:
  ///
  ///   CANDELA_DEBUG_SETTINGS=pane:general      Candela.app/Contents/MacOS/Candela
  ///   CANDELA_DEBUG_SETTINGS=display:builtIn   Candela.app/Contents/MacOS/Candela
  ///   CANDELA_DEBUG_SETTINGS=display:first     Candela.app/Contents/MacOS/Candela
  ///
  /// `display:first` resolves the first connected EXTERNAL display's
  /// persistence key, which is the one a capture script cannot know in advance.
  @MainActor
  enum DebugSettingsHook {
    static let environmentKey = "CANDELA_DEBUG_SETTINGS"

    /// Set by `openIfRequested` and adopted by `SettingsRootView.onAppear`.
    /// The root view owns its selection as `@State`, so there is nothing to
    /// write to from outside until the view exists.
    static var pendingSelection: SettingsDestination?

    /// Parsed separately from the opening so a typo is a no-op rather than a
    /// silent open on some OTHER pane — a screenshot of the wrong pane is worse
    /// than no screenshot, because it looks like evidence.
    static func destination(from value: String, externalKeys: [String]) -> SettingsDestination? {
      let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      let body = String(parts[1])
      switch parts[0] {
      case "pane":
        guard let id = PaneID(rawValue: body) else { return nil }
        return .pane(id)
      case "display":
        if body == "first" {
          guard let key = externalKeys.first else { return nil }
          return .display(key)
        }
        return body.isEmpty ? nil : .display(body)
      default:
        return nil
      }
    }

    /// Called once, at the end of launch and AFTER the first display refresh —
    /// `display:first` needs the display list to exist.
    static func openIfRequested(externalKeys: [String]) {
      guard let value = ProcessInfo.processInfo.environment[environmentKey],
            let destination = destination(from: value, externalKeys: externalKeys)
      else { return }
      // Set BEFORE opening: `SettingsRootView.onAppear` runs as part of the
      // window coming up, so a later assignment would miss it entirely.
      pendingSelection = destination
      SettingsOpener.open()
    }
  }
#endif
