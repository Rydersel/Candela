import AppKit
import CandelaKit
import SwiftUI
import Testing

/// The Menu Bar pane kept in one host while its prefs change underneath it, the
/// way the settings window keeps it while the user picks from its pop-ups.
/// Prefs are plain defaults, so `prefsRevision` is the only thing that can make
/// the retained pane re-read them; a fresh render would read the new values
/// whether or not that signal reaches the content.
@Suite("Menu Bar pane refresh") @MainActor
struct AppMenuPaneRefreshTests {
  /// Two hosts in turn, and the second is the one that matters: the first
  /// reading-form scaffold in a process followed the bump even while the
  /// defect was live, and only the ones after it went stale [MEASURED
  /// 2026-10-02]. One host alone, run first, would pass over the bug.
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
    // `.islandEdge` disables both position rows and rewrites their captions,
    // so all three things a style pick moves get checked. The write is the
    // pop-up's own setter: the pref, then the fan-out.
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
      let position = popUp(in: host, label: "Brightness indicator position:")
      seen = Seen(
        title: popUp(in: host, label: "Indicator style:")?.accessibilityValue() as? String,
        positionEnabled: position?.isAccessibilityEnabled(),
        positionHint: position?.accessibilityHelp())
      if seen == wanted { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(seen == wanted, "host \(round): the retained pane must show the \(style) style")
  }

  private func popUp(in root: Any, label: String, depth: Int = 0) -> (any NSAccessibilityProtocol)? {
    guard depth < 60 else { return nil }
    let object = root as AnyObject
    if (object.accessibilityRole?() ?? nil) == .popUpButton,
       (object.accessibilityLabel?() ?? nil) == label,
       let found = object as? any NSAccessibilityProtocol {
      return found
    }
    for child in (object.accessibilityChildren?() ?? nil) ?? [] {
      if let found = popUp(in: child, label: label, depth: depth + 1) { return found }
    }
    return nil
  }
}
