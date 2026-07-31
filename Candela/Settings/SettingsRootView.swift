import AppKit
import CandelaKit
import SwiftUI

/// Sidebar navigation over a pane registry. Replaces the five-tab `TabView`,
/// whose tab-for-tab match with the fork was the actual source of the visual
/// resemblance — the styling was already modern, and the window already
/// renders with Liquid Glass on macOS 26, which changed nothing.
///
/// D6 still holds and generalises to the registry: `PaneID.rawValue` is the
/// identifier, `title` is the label, and cross-pane state goes through
/// AppModel/SettingsActions observation, never view lifecycle ordering.
///
/// `@MainActor` because `SettingsRegistry` is main-actor-isolated and a
/// `View`'s stored-property default expressions are nonisolated under
/// `SWIFT_STRICT_CONCURRENCY: complete`.
@MainActor
struct SettingsRootView: View {
  @State private var selection: SettingsDestination? = .pane(.general)

  @Environment(AppModel.self) private var model

  var body: some View {
    NavigationSplitView {
      SettingsSidebar(selection: $selection)
        .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
    } detail: {
      detail
    }
    // Resizable, replacing the fork-era fixed `.frame(width: 620)`. The
    // minimum keeps the sidebar and a grouped form from crushing each other.
    .frame(minWidth: 720, minHeight: 480)
    // A destination for an absent display must never render, so a display that
    // is unplugged while selected drops the selection back to a pane. Keyed on
    // persistence keys, not display IDs: an ID changes across a replug and
    // would evict the user from a pane every time a link renegotiated.
    .onChange(of: model.displays.map(\.display.persistenceKey)) { _, connected in
      guard case let .display(key) = selection, key != "builtIn" else { return }
      if SettingsSelectionPolicy.resolve(selectedDisplayKey: key, connectedKeys: connected) == nil {
        selection = .pane(.general)
      }
    }
  }

  @ViewBuilder private var detail: some View {
    switch selection {
    case let .pane(id):
      let pane = SettingsRegistry.descriptor(for: id)
      pane.content()
        .navigationTitle(pane.title)
    case let .display(key):
      if let state = model.allControlledStates.first(where: { $0.display.persistenceKey == key }) {
        if key == "builtIn" {
          BuiltInDisplayPane(selection: $selection)
        } else {
          DisplayDetailView(state: state)
        }
      } else {
        generalFallback
      }
    case .none:
      generalFallback
    }
  }

  /// The detail column is never empty: an unresolvable selection shows General
  /// rather than a blank pane, which reads as a broken window.
  private var generalFallback: some View {
    SettingsRegistry.descriptor(for: .general).content()
      .navigationTitle("General")
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
