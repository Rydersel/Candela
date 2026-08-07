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
  /// Pinned to `.all` and BOUND rather than left `.automatic`, so SwiftUI
  /// holds an explicit visibility value to defend.
  ///
  /// AppKit's `NSSplitView` may collapse the sidebar when the window is
  /// squeezed — and it autosaves that under
  /// `"NSSplitView Subview Frames …SidebarNavigationSplitView"`, so the collapse
  /// survives relaunch. There is no sidebar-toggle item in this window's
  /// toolbar, so once collapsed there was **no way back from inside the app**:
  /// every pane and every display disappeared from navigation permanently.
  ///
  /// Measured 2026-08-04. A display being rotated and mirrored under an open
  /// settings window squeezed it, the sidebar collapsed, and the stored frames
  /// came back `"0, 0, 208, 568, YES, NO"` — collapsed — on every subsequent
  /// launch. Recovery took a `defaults delete`, which is not a thing to ask of
  /// anyone. The binding pins the INITIAL state; the `.onChange` in `body`
  /// springs the value back if a collapse ever reaches the binding. Whether
  /// AppKit's restored autosave frames reach it is UNMEASURED — that launch
  /// case is #66's open hardware item, and the lever that can actually touch
  /// the `NSSplitView` is `SettingsWindowConfigurator`, not this state.
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  @Environment(AppModel.self) private var model

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SettingsSidebar(selection: $selection)
        .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
    } detail: {
      // The content keeps its own opaque surface: this window carries a lot of
      // small secondary text, and it must not end up at the mercy of whatever
      // is behind the window.
      //
      // The ONE visible title. Three spellings were tried and two shipped a
      // visible defect, so the reasoning is recorded rather than rediscovered:
      //
      // 1. `.navigationTitle` alone renders at the LEADING edge of the detail
      //    column — a stray label rather than a title.
      // 2. Setting `window.title` alone does the same thing: in a
      //    full-size-content window with a sidebar, AppKit draws the window
      //    title leading, NOT centred.
      // 3. A principal item plus either of the above shows the name TWICE.
      //
      // So: a principal item draws it, and the window's own title is set but
      // hidden (`titleVisibility`), which keeps the window named for the
      // Window menu and accessibility without drawing a second copy.
      detail
        .background(.background)
        .toolbar {
          // macOS 26 gives toolbar items the Liquid Glass capsule it gives
          // CONTROLS, which drew a pill around the title. A title is not a
          // control, so on 26 it opts out of the shared background. Earlier
          // versions have no such background and need no opt-out.
          if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
              Text(currentTitle).font(.headline)
            }
            .sharedBackgroundVisibility(.hidden)
          } else {
            ToolbarItem(placement: .principal) {
              Text(currentTitle).font(.headline)
            }
          }
        }
    }
    // Replaces the fork-era fixed `.frame(width: 620)`.
    //
    // The maxima are load-bearing, not decoration: a bare `minWidth/minHeight`
    // pair leaves the content's ideal size as its maximum too, and the window
    // then refuses to grow OR shrink — measured at a hard 900×512 in both
    // directions. `.infinity` is what actually makes it resizable, and the
    // scene needs `.windowResizability(.contentMinSize)` to agree (see
    // CandelaApp). The minimum keeps the sidebar and a grouped form from
    // crushing each other.
    .frame(
      minWidth: 720, idealWidth: 900, maxWidth: .infinity,
      minHeight: 480, idealHeight: 560, maxHeight: .infinity
    )
    .background(SettingsWindowConfigurator(title: currentTitle))
    // Debug-only screenshot hook: the window has no URL scheme and cannot be
    // driven by clicking without an Accessibility grant, so a capture run says
    // which destination it wants through an env var and this adopts it once,
    // here, where the `@State` selection actually lives.
    //
    // The `#if` wraps the MODIFIER, not the closure body: guarding the body
    // instead leaves Release with a live, empty `.onAppear { }` in the chain
    // and a comment naming the debug env var — residue, and a quiet lie in
    // `DebugSettingsHook`'s claim that both call sites are compiled out.
    #if DEBUG
      .onAppear {
        if let pending = DebugSettingsHook.pendingSelection {
          DebugSettingsHook.pendingSelection = nil
          selection = pending
        }
      }
    #endif
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
    // Best-effort anti-collapse defence (#66): this window has no
    // sidebar-toggle item, so a hidden sidebar removes every pane from
    // navigation with no way back from inside the app. Guards `.detailOnly`
    // alone — "the sidebar is hidden" — never `!= .all`: `.automatic` and
    // `.doubleColumn` are legitimate framework values, and fighting them would
    // ping-pong writes against SwiftUI's own normalisation. On a window
    // genuinely too narrow for both columns, the forced `.all` may itself be
    // re-collapsed by AppKit — a squeeze-fight #66's hardware item should
    // watch for. This layer helps only when a collapse is reflected into the
    // binding; whether AppKit's restored autosave frames ever are is
    // unmeasured, so the restored-collapsed launch stays OPEN on #66 — this
    // modifier does not claim to cover it.
    .onChange(of: columnVisibility) { _, visibility in
      if visibility == .detailOnly { columnVisibility = .all }
    }
  }

  /// The title shown centred in the toolbar. Resolved here rather than read
  /// back from the panes, so every destination titles itself the same way.
  /// Display destinations use the display's own name, not a pane label.
  private var currentTitle: String {
    switch selection {
    case let .pane(id):
      SettingsRegistry.descriptor(for: id).title
    case let .display(key):
      model.allControlledStates
        .first { $0.display.persistenceKey == key }
        .map(\.display.name) ?? "General"
    case .none:
      "General"
    }
  }

  @ViewBuilder private var detail: some View {
    switch selection {
    case let .pane(id):
      SettingsRegistry.descriptor(for: id).content()
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
  }
}

/// Adds the `.resizable` style mask that a `Settings` scene omits.
///
/// No SwiftUI modifier restores it: `.windowResizability(.contentMinSize)` on
/// the scene plus an `.infinity` content frame both leave the zoom button
/// disabled and the window pinned — measured at a hard 900×512, immovable in
/// either direction. A fixed size was tolerable for a stack of tabs; it is not
/// for a split view whose panes differ in height, where the window keeps
/// whatever size the pane it first opened on happened to want.
///
/// This hangs off the view rather than off `SettingsOpener` deliberately.
/// ⌘, does NOT go through `SettingsOpener` — it is delivered straight to
/// SwiftUI's own menu item — so a fix installed on the open path only works
/// when the window is opened from the panel's gear. Attaching it to the view
/// makes it independent of how the window came to exist.
/// Also owns the window's NAME — set, but with `titleVisibility` hidden. The
/// visible title is a principal toolbar item (see `body`); this one exists so
/// the Window menu and accessibility have a name to report, and is not drawn
/// because AppKit would place it at the LEADING edge of a full-size-content
/// window with a sidebar, giving a second, misaligned copy.
private struct SettingsWindowConfigurator: NSViewRepresentable {
  let title: String

  func makeNSView(context _: Context) -> NSView {
    let view = NSView(frame: .zero)
    // The view is not in a window yet during `makeNSView`.
    DispatchQueue.main.async { configure(view.window) }
    return view
  }

  func updateNSView(_ view: NSView, context _: Context) {
    DispatchQueue.main.async { configure(view.window) }
  }

  private func configure(_ window: NSWindow?) {
    guard let window else { return }
    if !window.styleMask.contains(.resizable) {
      window.styleMask.insert(.resizable)
    }
    // Named but not drawn: the visible title is the principal toolbar item, so
    // letting AppKit draw this one too is what produced two copies of the pane
    // name. `title` still feeds the Window menu and accessibility.
    if window.titleVisibility != .hidden {
      window.titleVisibility = .hidden
    }
    // The default style puts the toolbar in its own band BELOW the titlebar,
    // which dropped the pane title 24 pt under the window controls and opened
    // a strip of dead space across the top of both columns (measured: title at
    // y=162 against controls at y=138). `.unifiedCompact` merges the two rows,
    // so the title sits on the same line as the controls.
    if window.toolbarStyle != .unifiedCompact {
      window.toolbarStyle = .unifiedCompact
    }
    if window.title != title {
      window.title = title
    }
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
  static func open() {
    // The gear button lives inside the panel's menu tracking session, and no
    // window can take focus while one is running. The menu is held by
    // `PanelMenu` — one holder, because a second panel control now has to end
    // tracking for a different reason (see `PanelResolutionSection`).
    PanelMenu.endTracking()
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
