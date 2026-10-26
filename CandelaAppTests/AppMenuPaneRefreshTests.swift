import AppKit
import CandelaKit
import SwiftUI
import Testing

/// One retained host while prefs change, as in the settings window. Prefs are
/// plain defaults, so only `prefsRevision` makes the pane re-read them; a fresh
/// render would pass whether or not that signal arrives.
@Suite("Menu Bar pane refresh") @MainActor
struct AppMenuPaneRefreshTests {
  /// The second host is the one that matters: only reading-form scaffolds after
  /// the process's first went stale [MEASURED 2026-10-02].
  @Test func aRetainedPaneFollowsAStyleChange() async throws {
    for host in 1...2 {
      try await driveOneHost(round: host)
    }
  }

  private func driveOneHost(round: Int) async throws {
    let prefs = DisplayPrefs(defaults: InMemoryDefaults(), persistenceKey: "app")
    prefs.hudStyle = .system
    let model = TestFixtures.appModel()
    let actions = SettingsActions(model: model)

    _ = NSApplication.shared
    (NSApp as NSObject).accessibilitySetValue(
      true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let host = NSHostingView(rootView: AppMenuPane(prefs: prefs)
      .environment(model)
      .environment(actions)
      .transaction { $0.disablesAnimations = true }
      .frame(width: 720, height: 2400))
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 2400)

    try await expect(in: host, style: .system, round: round)
    // `.islandEdge` also disables the position rows and rewrites their captions.
    // Same order as the pop-up's setter: pref, then fan-out.
    for style in [HUDStyle.islandEdge, .compact] {
      prefs.hudStyle = style
      actions.prefDidChange(.hudStyle)
      try await expect(in: host, style: style, round: round)
    }
  }

  private struct Seen: Equatable {
    var title: String?
    var positionEnabled: Bool?
    var positionHint: String?
  }

  private func expect(in host: NSView, style: HUDStyle, round: Int) async throws {
    let wanted = Seen(
      title: IndicatorStyleCopy.label(for: style),
      positionEnabled: IndicatorStyleCopy.positionRowsApply(to: style),
      positionHint: IndicatorStyleCopy.positionCaption(for: style, kind: .brightness))
    var seen = Seen()
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      let position = control(in: host, label: "Brightness indicator position:")
      seen = Seen(
        title: axObjectValue(control(in: host, label: "Indicator style:"), selector: "accessibilityValue") as? String,
        positionEnabled: axEnabled(position),
        positionHint: axObjectValue(position, selector: "accessibilityHelp") as? String)
      if seen == wanted { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(seen == wanted, "host \(round): the retained pane must show the \(style) style")
  }

  /// SwiftUI's AX node need not conform to NSAccessibilityProtocol, and the
  /// Picker's AppKit implementation changes with the macOS 27 SDK. The user
  /// contract is its label and readable value, not the native control class.
  private func control(in root: Any, label: String, depth: Int = 0) -> AnyObject? {
    guard depth < 60 else { return nil }
    let object = root as AnyObject
    if (object.accessibilityLabel?() ?? nil) == label,
       (object as? NSObject)?.responds(to: NSSelectorFromString("accessibilityValue")) == true {
      return object
    }
    for child in (object.accessibilityChildren?() ?? nil) ?? [] {
      if let found = control(in: child, label: label, depth: depth + 1) { return found }
    }
    return nil
  }

  private func axObjectValue(_ object: AnyObject?, selector name: String) -> AnyObject? {
    guard let object = object as? NSObject else { return nil }
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return nil }
    return object.perform(selector)?.takeUnretainedValue()
  }

  private func axEnabled(_ object: AnyObject?) -> Bool? {
    guard let object = object as? NSObject else { return nil }
    let selector = NSSelectorFromString("isAccessibilityEnabled")
    guard object.responds(to: selector) else { return nil }
    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
    let getter = unsafeBitCast(object.method(for: selector), to: Getter.self)
    return getter(object, selector)
  }
}
