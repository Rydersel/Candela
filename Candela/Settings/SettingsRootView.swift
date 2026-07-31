import AppKit
import SwiftUI

/// Five tabs (≤ 6 per HIG tab-views guidance), short title-case noun labels,
/// each pane fully self-contained. Identifiers ARE the titles (D6 — no "Main"
/// vs "General" split, no preload hacks; cross-pane state goes through
/// AppModel/SettingsActions observation, never viewDidLoad ordering).
struct SettingsRootView: View {
  var body: some View {
    TabView {
      GeneralPane()
        .tabItem { Label("General", systemImage: "switch.2") }
      AppMenuPane()
        .tabItem { Label("App Menu", systemImage: "filemenu.and.cursorarrow") }
      KeyboardPane()
        .tabItem { Label("Keyboard", systemImage: "keyboard") }
      DisplaysPane()
        .tabItem { Label("Displays", systemImage: "display.2") }
      AboutPane()
        .tabItem { Label("About", systemImage: "info.circle") }
    }
    // Fixed width, natural height per pane: the fork's 660×{700,600,640,360}
    // magic heights are NOT ported (chapter-1 QUIRK — SwiftUI sizes to fit).
    .frame(width: 620)
  }
}

/// LSUIElement + Settings-scene activation (spec §9 budgeted risk). Every part
/// of this sequence was measured on macOS 26 with an isolated LSUIElement +
/// SwiftUI-`Settings` harness driving a real NSStatusItem tracking session; the
/// obvious spelling of it is broken in two independent ways.
///
/// 1. `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`
///    is delivered — `SwiftUI.AppDelegate` implements it and `sendAction`
///    returns `true` — but **no window is ever created**. It is a silent
///    no-op, so its return value cannot even be used to detect the failure.
///    What does work is performing the app menu's own Settings item, which
///    SwiftUI wires to a private `MenuItemCallback`; that is the same path a
///    user's ⌘, takes.
///
/// 2. `NSApp.activate()` (and `NSRunningApplication.current.activate(options:)`,
///    which returns `false`) will not activate an accessory-policy app from
///    inside a menu tracking session. The window then opens *behind* the
///    frontmost app and never becomes key — and no amount of
///    `makeKeyAndOrderFront` / `orderFrontRegardless` on the window rescues it,
///    because key-ness follows app activation, not window ordering. Only the
///    deprecated `activate(ignoringOtherApps:)` works.
///
/// Both calls must also stay **synchronous**, inside the click's event context:
/// deferring either one with `DispatchQueue.main.async` loses the activation
/// grant and puts the window back behind the frontmost app (measured — the
/// async variants were the worst-behaved of the six tried).
@MainActor
enum SettingsOpener {
  /// Set by StatusItemController at launch so the panel's gear button can end
  /// the tracking session it lives inside.
  static weak var statusMenu: NSMenu?

  static func open() {
    statusMenu?.cancelTracking()
    // Deprecated since macOS 14 and used anyway: the replacement genuinely
    // does not activate an LSUIElement app from a tracking session. Revisit
    // only against a measurement, never against the deprecation warning alone.
    NSApp.activate(ignoringOtherApps: true)
    if let item = settingsMenuItem, let action = item.action {
      NSApp.sendAction(action, to: item.target, from: item)
    } else {
      // Last-ditch: known to be a no-op on macOS 26, kept only so a future
      // SwiftUI that stops publishing the menu item degrades to "maybe".
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
  }

  /// The app menu's Settings item, found by its ⌘, key equivalent rather than
  /// its title — the title is SwiftUI's ("Settings…" today, "Preferences…"
  /// before macOS 13) but the key equivalent is fixed by the HIG. Scoped to the
  /// app menu so a future ⌘, elsewhere in the menu bar cannot be mistaken for
  /// it.
  private static var settingsMenuItem: NSMenuItem? {
    NSApp.mainMenu?.items.first?.submenu?.items.first {
      $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
    }
  }
}
