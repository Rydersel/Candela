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

  /// Each display destination's pushed-sub-page stack, keyed by persistence key
  /// (SO23). Retained for the life of the window so leaving a display and
  /// coming back lands where the user was; cleared ONLY on that display's
  /// departure — which is also what guarantees SO9's "returns to the hub, not
  /// a sub-page" on reconnection. `@State`, so closing the window clears all.
  @State private var subPagePaths: [String: [DisplaySubPage]] = [:]
  /// The display whose departure evicted the user, remembered so its return
  /// can restore the selection (SO9). Only the SELECTED display's departure is
  /// remembered — an unrelated monitor unplugging must not hijack a later
  /// arrival.
  @State private var lastDisplayKey: String?
  /// The display a jump into the OLED Care pane came from, as a persistence
  /// key. Lives here because it travels with `selection`, which lives here;
  /// the pane clears it as soon as it has scrolled, so it is never state
  /// anyone has to keep in agreement with anything (see `oledCareScrollTarget`
  /// in `OledCarePane`).
  @State private var oledCareScrollTarget: String?
  /// Accessibility contract 2: selecting a sidebar destination moves focus
  /// into the detail column. Anchored on the detail root; hand-verified only
  /// (no app test target, and synthetic keys go to the terminal, not an
  /// LSUIElement app).
  @FocusState private var detailFocusAnchor: Bool

  @Environment(AppModel.self) private var model

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      SettingsSidebar(selection: $selection, onReselect: returnToHub)
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
        .environment(\.oledCareScrollTarget, $oledCareScrollTarget)
        .focused($detailFocusAnchor)
        // Keyboard contract (accessibility contract 2): ⌘[ pops the current
        // display's sub-page; ⌘1–⌘9 select the first nine sidebar destinations
        // in sidebar render order. Hidden buttons rather than `.commands`: the
        // `Settings` scene's menu bar is not this view's to edit, and a
        // shortcut on a button in the key window's hierarchy fires without
        // being visible. Not tab-reachable at zero size; VoiceOver skips them
        // via `accessibilityHidden`.
        .background {
          Group {
            Button("") { popCurrentSubPage() }
              .keyboardShortcut("[", modifiers: .command)
            ForEach(Array(orderedDestinations.prefix(9).enumerated()), id: \.offset) { index, destination in
              Button("") { selection = destination }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
          }
          .frame(width: 0, height: 0)
          .opacity(0)
          .accessibilityHidden(true)
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
    // `navigationToken` re-runs the configurator on every push and pop.
    // Measured in the Task 9 spike: a push flips `titleVisibility` back to
    // visible and AppKit draws the scene's own "Candela Settings" at the
    // LEADING edge next to the Back button — and it LINGERS after the pop,
    // beside the principal title. Without a dependency that changes with the
    // path, `updateNSView` never fires for a push/pop and cannot re-hide it.
    .background(SettingsWindowConfigurator(title: currentTitle, navigationToken: currentPathDepth))
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
          if case let .display(key) = pending, let page = DebugSettingsHook.pendingSubPage {
            DebugSettingsHook.pendingSubPage = nil
            subPagePaths[key] = [page]
          }
          if let target = DebugSettingsHook.pendingScrollTarget {
            DebugSettingsHook.pendingScrollTarget = nil
            oledCareScrollTarget = target
          }
        }
      }
    #endif
    // A destination for an absent display must never render, so an unplug
    // while selected falls back — to a surviving sibling display first, then
    // to General (SO9). Keyed on persistence keys, not display IDs: an ID
    // changes across a replug and would evict the user from a pane every time
    // a link renegotiated.
    //
    // The keys are `allControlledStates` — built-in first, then externals —
    // which is exactly sidebar render order, INCLUDING the built-in. Feeding
    // externals only (the pre-Task-9 shape) made sibling fallback unable to
    // land on the built-in row: unplugging the only external on an open laptop
    // dropped to General even though a display destination survived. The
    // built-in is a real departure source too — clamshell removes it.
    .onChange(of: model.allControlledStates.map(\.display.persistenceKey)) { previous, connected in
      // SO23's clearing rule: a departed display's sub-page stack dies with
      // it, whether or not it was selected — its return lands on the hub.
      for departed in Set(previous).subtracting(connected) {
        subPagePaths[departed] = nil
      }

      if case let .display(key) = selection {
        switch SettingsSelectionPolicy.resolveDestination(selectedDisplayKey: key, connectedKeys: connected) {
        case .keep, nil:
          break
        case let .fallbackToSibling(sibling):
          lastDisplayKey = key
          selection = .display(sibling)
        case .fallbackToPane:
          lastDisplayKey = key
          selection = .pane(.general)
        }
      }

      // A remembered display returning takes back the selection — unless the
      // user is on a display destination they chose in the meantime (SO9).
      // `currentIsDisplay` reads the possibly-just-updated selection: a
      // sibling fallback above counts as "on a display" and blocks this.
      let arrived = Array(Set(connected).subtracting(previous))
      var currentIsDisplay = false
      if case .display = selection { currentIsDisplay = true }
      if let restored = SettingsSelectionPolicy.restoration(
        lastDisplayKey: lastDisplayKey, arrivedKeys: arrived, currentIsDisplay: currentIsDisplay
      ) {
        lastDisplayKey = nil
        selection = .display(restored)
      }
    }
    // Contract 2's second clause: selecting a destination moves focus into the
    // detail column, so Tab starts on the page the user just chose rather than
    // back at the sidebar.
    .onChange(of: selection) { _, _ in
      detailFocusAnchor = true
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

  /// ONE `NavigationStack` for the whole detail column, alive for the life of
  /// the window. It used to be one stack per display destination, created
  /// inside the selection switch and `.id`-keyed, and that shape shipped a
  /// defect: destroying a `NavigationStack` while it is PRESENTING a sub-page
  /// leaves the pushed page hosted by the split view's detail column with
  /// nothing owning it (measured 2026-08-07: sidebar highlighted Keyboard,
  /// window title said Keyboard, detail stayed frozen on the orphaned Advanced
  /// page until Back). A selection change must therefore never remove the
  /// stack; it changes the stack's ROOT and its PATH instead, so leaving a
  /// display pops its sub-page through the binding before the root swaps.
  ///
  /// SO23 is preserved: `subPagePaths` still retains every display's stack,
  /// because the binding below reads and writes per-display storage; a pane
  /// selection just presents none of it.
  private var detail: some View {
    NavigationStack(path: currentPathBinding) {
      detailRoot
        .toolbar { SettingsPrincipalTitle(title: currentTitle) }
        .navigationDestination(for: DisplaySubPage.self) { page in
          pushedPage(page)
        }
    }
  }

  @ViewBuilder private var detailRoot: some View {
    switch selection {
    case let .pane(id):
      SettingsRegistry.descriptor(for: id).content()
    case let .display(key):
      if let state = model.allControlledStates.first(where: { $0.display.persistenceKey == key }) {
        displayRoot(key: key, state: state)
      } else {
        generalFallback
      }
    case .none:
      generalFallback
    }
  }

  /// One display destination's root: the banner region sits above the root AND
  /// above every pushed page from these two placements alone (SO7); pages
  /// never own banners, so a new sub-page cannot forget one.
  ///
  /// `.id(key)` on the ROOT CONTENT, never on the stack: it still resets
  /// per-display root state (scroll, focus) on a switch, without giving each
  /// display its own stack identity, which is the orphaned-page defect `detail`
  /// documents.
  private func displayRoot(key: String, state: AppModel.DisplayState) -> some View {
    VStack(spacing: 0) {
      // The root stays in the stack behind a pushed page and keeps rendering,
      // so both placements would draw the SAME answerable countdown. The pushed
      // page is the one the reader is looking at, so it owns the answer; this
      // one yields while the path is non-empty and keeps every passive banner.
      BannerRegion(state: state, ownsAnswerableCountdown: (subPagePaths[key] ?? []).isEmpty)
      if key == "builtIn" {
        BuiltInDisplayPane(selection: $selection, path: pathBinding(for: key))
      } else {
        DisplayDetailView(state: state, selection: $selection, path: pathBinding(for: key))
      }
    }
    .id(key)
  }

  /// A pushed sub-page, resolved against the CURRENT selection: the stack is
  /// shared, so a page is only ever presented for the selected display. The
  /// guard goes empty for the frame in which a pane selection is still popping
  /// the outgoing display's page.
  @ViewBuilder private func pushedPage(_ page: DisplaySubPage) -> some View {
    if case let .display(key) = selection,
       let state = model.allControlledStates.first(where: { $0.display.persistenceKey == key }) {
      VStack(spacing: 0) {
        BannerRegion(state: state)
        subPage(page, key: key, state: state)
      }
      // `.id(key)` on the pushed CONTENT, mirroring `displayRoot`, and never on
      // the stack (that re-keying is the orphaned-page defect `detail`
      // documents). The switcher keeps this page presented while `state`
      // re-resolves to the new display, so without the re-key the sub-page's
      // `@State` (drafts, focus, list filters) survived the switch and rendered
      // against the new display's prefs; a draft typed on one display could
      // then commit into another's tuning (SO10).
      .id(key)
      // The root's principal title does NOT survive a push (measured in the
      // Task 9 spike: the toolbar came up empty but for Back), so every
      // pushed page re-declares it. Still the DISPLAY's name: the sub-page
      // names itself in its header, and the toolbar keeps answering "which
      // display am I configuring".
      .toolbar { SettingsPrincipalTitle(title: currentTitle) }
    }
  }

  /// The persistent stack's path: the selected display's retained sub-page
  /// stack, or empty for a pane. Selecting a pane changes this binding's VALUE
  /// to `[]`, which is what pops the outgoing display's sub-page while the
  /// stack survives.
  ///
  /// The key is resolved ONCE, when the binding is built, and the setter drops
  /// any write made after the selection stops matching it. The stack can flush
  /// a transition's write-back through a binding built before the selection
  /// moved; a setter that re-read the selection at write time landed that
  /// write under whatever was selected by then, which on a display-to-display
  /// switch cleared the NEW display's retained path (SO23). The pane branch
  /// keeps the old rule as its degenerate case: reads are empty and every
  /// write is dropped.
  private var currentPathBinding: Binding<[DisplaySubPage]> {
    guard case let .display(boundKey) = selection else {
      return Binding(get: { [] }, set: { _ in })
    }
    return Binding(
      get: { subPagePaths[boundKey] ?? [] },
      set: { newPath in
        guard case let .display(current) = selection, current == boundKey else { return }
        subPagePaths[boundKey] = newPath
      }
    )
  }

  /// One case per sub-page — all three pages are real. Each page owns its
  /// own `Form` (a grouped `Form` only reliably sizes structure declared in
  /// its own builder — see `DisplayHubView.body`), so this switch names a
  /// view and nothing else. Every page starts with `SubPageHeader` — title
  /// focus on push, and the display switcher that carries THIS sub-page onto
  /// another display (SO23).
  @ViewBuilder
  private func subPage(_ page: DisplaySubPage, key: String, state: AppModel.DisplayState) -> some View {
    // Rename dependency, registered HERE because `switcherDisplays` is read at
    // this point: the switcher's names come from `friendlyName`, and
    // `DisplayPrefs` is plain UserDefaults with no observation of its own. A
    // page's own body reading `prefsRevision` does not cover the values passed
    // INTO it.
    let _ = model.prefsRevision
    switch page {
    case .allModes:
      AllModesPage(
        state: state,
        displays: switcherDisplays,
        onSwitch: { newKey in switchDisplay(from: key, to: newKey) }
      )
    case .advanced:
      AdvancedPage(
        state: state,
        displays: switcherDisplays,
        onSwitch: { newKey in switchDisplay(from: key, to: newKey) }
      )
    case .diagnostics:
      DiagnosticsPage(
        state: state,
        path: pathBinding(for: key),
        displays: switcherDisplays,
        onSwitch: { newKey in switchDisplay(from: key, to: newKey) }
      )
    }
  }

  /// Pop focus restoration (accessibility contract 1's pop half) is the
  /// destination's job, not this view's: `DisplayDetailView` and
  /// `BuiltInDisplayPane` each own a `@FocusState focusedRow: DisplaySubPage?`
  /// and hand it back to the pushing row when this binding shrinks.
  private func pathBinding(for key: String) -> Binding<[DisplaySubPage]> {
    Binding(
      get: { subPagePaths[key] ?? [] },
      set: { subPagePaths[key] = $0 }
    )
  }

  /// Feeds the window configurator's `navigationToken`: any push or pop must
  /// re-run it (see the call site). Panes have no stack and sit at depth 0.
  private var currentPathDepth: Int {
    guard case let .display(key) = selection else { return 0 }
    return subPagePaths[key]?.count ?? 0
  }

  /// Sidebar render order — registry panes, then built-in, then externals
  /// (`allControlledStates` is exactly that order). ⌘1–⌘9 index into this.
  private var orderedDestinations: [SettingsDestination] {
    SettingsRegistry.panes.map { .pane($0.id) }
      + model.allControlledStates.map { .display($0.display.persistenceKey) }
  }

  /// Clicking the sidebar row of the display you are already on returns that
  /// display to its hub root. Without it the click does nothing, because the
  /// row writes a selection that is already the selection.
  ///
  /// SO23 retention is untouched: this clears only the display being
  /// re-clicked, never a path held for another display, so A to B to A still
  /// lands where the user was. Panes have no stack and are left alone.
  ///
  /// The write goes through `currentPathBinding` rather than `subPagePaths`
  /// directly, so the destination's shrink-detecting `onChange` sees a pop and
  /// restores focus to the row that pushed. The binding's key is resolved from
  /// the selection this guard has just matched, so its stale-write check
  /// compares a key against itself and passes.
  private func returnToHub(_ destination: SettingsDestination) {
    guard case let .display(key) = selection, destination == selection,
          !(subPagePaths[key] ?? []).isEmpty
    else { return }
    currentPathBinding.wrappedValue = []
  }

  private func popCurrentSubPage() {
    guard case let .display(key) = selection,
          var path = subPagePaths[key], !path.isEmpty else { return }
    path.removeLast()
    subPagePaths[key] = path
  }

  /// Every connected display, named the way the sidebar names it, so the
  /// switcher menu and the sidebar can never disagree about what a display is
  /// called.
  private var switcherDisplays: [(key: String, name: String)] {
    model.allControlledStates.map { state in
      let key = state.display.persistenceKey
      return (
        key: key,
        name: DisplayOrdering.title(
          friendlyName: DisplayPrefs(persistenceKey: key).friendlyName,
          hardwareName: state.display.name
        )
      )
    }
  }

  /// SO23's comparison workflow: the sub-page carries over, THEN the sidebar
  /// selection moves. Copying the whole path (not just the visible page) keeps
  /// any deeper future stack intact.
  private func switchDisplay(from currentKey: String, to newKey: String) {
    subPagePaths[newKey] = subPagePaths[currentKey] ?? []
    selection = .display(newKey)
  }

  /// The detail column is never empty: an unresolvable selection shows General
  /// rather than a blank pane, which reads as a broken window.
  private var generalFallback: some View {
    SettingsRegistry.descriptor(for: .general).content()
  }
}

/// The one visible title, centred. macOS 26 gives toolbar items the Liquid
/// Glass capsule it gives CONTROLS, which drew a pill around the title; a
/// title is not a control, so on 26 it opts out of the shared background.
/// Earlier versions have no such background and need no opt-out.
private struct SettingsPrincipalTitle: ToolbarContent {
  let title: String

  var body: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarItem(placement: .principal) {
        Text(title).font(.headline)
      }
      .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(placement: .principal) {
        Text(title).font(.headline)
      }
    }
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
  /// Unused in `configure` — its whole job is being a dependency that changes
  /// on push/pop so `updateNSView` fires then. A push flips `titleVisibility`
  /// back to visible and draws the scene title leading (measured, Task 9
  /// spike); this is what re-hides it.
  let navigationToken: Int

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    // The view is not in a window yet during `makeNSView`.
    let coordinator = context.coordinator
    DispatchQueue.main.async { configure(view.window, coordinator: coordinator) }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    DispatchQueue.main.async { configure(view.window, coordinator: coordinator) }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// Holds the `didUpdateNotification` observation that re-hides the window
  /// title whenever AppKit flips `titleVisibility` back to visible.
  ///
  /// `navigationToken` catches the flips that ride on a push or a pop, but two
  /// measured cases flip it with NO dependency of `updateNSView` changing: Back
  /// out of a pushed page whose selection had already moved (the pop leaves the
  /// depth-keyed token where a stale render had it), and the banner region
  /// appearing over the hub. Rather than enumerating flip sources one defect at
  /// a time, the enforcement rides `NSWindow.didUpdateNotification`, which
  /// AppKit posts on every window update pass; the check is two loads and a
  /// compare, and the write happens only when a flip actually occurred, so the
  /// notification cannot feed back on itself.
  final class Coordinator {
    // Nonisolated storage so `deinit` can remove the observer (a `@MainActor`
    // property is unreachable from a nonisolated deinit under Swift 6).
    // `removeObserver` is thread-safe; both properties are only ever WRITTEN
    // from `enforceTitleHidden`, which is main-actor.
    private var observer: NSObjectProtocol?
    private weak var observedWindow: NSWindow?

    /// The one way to hand the window into the `@Sendable` notification
    /// closure. `@unchecked Sendable` is justified by confinement: the box is
    /// only ever opened inside `MainActor.assumeIsolated`, on the `.main`
    /// queue, which is where NSWindow lives.
    private struct WeakWindowBox: @unchecked Sendable {
      weak var window: NSWindow?
    }

    @MainActor func enforceTitleHidden(on window: NSWindow) {
      guard observedWindow !== window else { return }
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observedWindow = window
      let box = WeakWindowBox(window: window)
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didUpdateNotification, object: window, queue: .main
      ) { _ in
        // didUpdateNotification for an NSWindow is posted on the main thread;
        // the assumeIsolated is the bridge from the nonisolated notification
        // closure to the AppKit calls below.
        MainActor.assumeIsolated {
          guard let window = box.window, window.titleVisibility != .hidden else { return }
          window.titleVisibility = .hidden
        }
      }
    }

    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }
  }

  private func configure(_ window: NSWindow?, coordinator: Coordinator) {
    guard let window else { return }
    coordinator.enforceTitleHidden(on: window)
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
