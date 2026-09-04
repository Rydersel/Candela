import AppKit
import CandelaKit
import SwiftUI

/// Sidebar navigation over a pane registry.
///
/// The shell is hand-built: a canvas, a fixed-width sidebar, a hairline,
/// the detail column. **Do not reintroduce a split view.** One owns its column
/// backgrounds, so no canvas can be drawn under both columns, its sidebar drew
/// a panel that dimmed when the window lost focus, and `NSSplitView` could hide
/// the sidebar under a squeeze and autosave that, leaving a window with no
/// navigation and no way back from inside the app.
///
/// Identity in the registry: `PaneID.rawValue` is the identifier, `title` is
/// the label, and cross-pane state goes through AppModel/SettingsActions
/// observation, never view lifecycle ordering.
///
/// `@MainActor` because `SettingsRegistry` is main-actor-isolated and a
/// `View`'s stored-property defaults are nonisolated under complete
/// concurrency.
@MainActor
struct SettingsRootView: View {
  @State private var selection: SettingsDestination? = .pane(.general)

  /// Each display destination's pushed-sub-page stack, keyed by persistence
  /// key. Retained for the life of the window, cleared ONLY on that
  /// display's departure, which is what makes a reconnection land on the hub
  /// rather than a sub-page.
  @State private var subPagePaths: [String: [DisplaySubPage]] = [:]
  /// The display whose departure evicted the user, so its return can restore
  /// the selection. Only the SELECTED display's departure is remembered:
  /// an unrelated monitor unplugging must not hijack a later arrival.
  @State private var lastDisplayKey: String?
  /// The OLED Care pane's pushed-page stack, here because it rides the
  /// same `NavigationStack`. Retained across selection changes like a display's,
  /// cleared when a display in it departs. Display Health is NOT in this stack:
  /// it opens in its own AppKit window.
  @State private var oledCarePath: [OledCarePage] = []
  /// For the debug capture route's health window; the pane's own links read the
  /// same actions object from their environment.
  @Environment(SettingsActions.self) private var actions
  /// The Keyboard pane's pushed-page stack: same stack, same retention
  /// rules as the OLED pane's. These pages name no hardware, so departure
  /// clearing never touches this.
  @State private var keyboardPath: [KeyboardPage] = []
  /// Selecting a sidebar destination moves focus into the detail column.
  /// Hand-verified only: synthetic keys go to the terminal, not an LSUIElement
  /// app.
  @FocusState private var detailFocusAnchor: Bool

  @Environment(AppModel.self) private var model

  var body: some View {
    ZStack {
      // One canvas for the life of the window, so a selection change moves the
      // light rather than cutting to a new one.
      //
      // **The canvas is the ONLY view here that opts out of the safe area**,
      // and that asymmetry is the whole defence for the top strip: the glow
      // runs under the transparent titlebar while the columns start below it,
      // so nothing scrolls up behind the traffic lights. Never add
      // `.ignoresSafeArea()` to the HStack or to a page, and never re-add
      // per-view titlebar padding.
      SettingsCanvas(accent: currentAccent.accent, secondary: currentAccent.secondary)
      HStack(spacing: 0) {
        SettingsSidebar(selection: animatedSelection, onReselect: returnToHub)
          // Fixed, not a resizable column: a fixed one cannot be collapsed to
          // nothing by an AppKit squeeze.
          .frame(width: 224)
        Rectangle()
          .fill(Color.white.opacity(0.08))
          .frame(width: 1)
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .environment(\.oledCarePath, $oledCarePath)
          .environment(\.keyboardPath, $keyboardPath)
          .focused($detailFocusAnchor)
          // ⌘[ pops the current sub-page; ⌘1 onward select sidebar
          // destinations in render order. Hidden buttons rather than
          // `.commands`, because the `Settings` scene's menu bar is not this
          // view's to edit and a shortcut on a button in the key window's
          // hierarchy fires without being visible.
          .background {
            Group {
              Button("") { popCurrentSubPage() }
                .keyboardShortcut("[", modifiers: .command)
              ForEach(Array(orderedDestinations.prefix(9).enumerated()), id: \.offset) { index, destination in
                Button("") { select(destination) }
                  .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
              }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
          }
      }
    }
    // Published once for the whole shell, so the wordmark and every themed
    // component read one destination's lighting.
    .environment(\.settingsAccent, currentAccent)
    // Dark-only: every colour comes from the theme layer and none of
    // them has a light-appearance answer.
    .preferredColorScheme(.dark)
    // The cross-link navigation seam, wired here because this view
    // owns the selection and re-wired per appearance so a reopened window binds
    // to the live view identity.
    //
    // A reveal lands on the destination's ROOT, so the retained stack is
    // cleared first. Otherwise a row promising "the display's own page" opens
    // on whatever sub-page that display was left on, which for Advanced or All
    // Sizes is a page the promised control is not on.
    //
    // The retention rule is untouched: sidebar clicks do not come through
    // the seam.
    .onAppear {
      actions.reveal = { destination in
        switch destination {
        case let .display(key): subPagePaths[key] = []
        case .pane(.oledCare): oledCarePath = []
        case .pane(.keyboard): keyboardPath = []
        case .pane: break
        }
        select(destination)
      }
    }
    // The maxima are load-bearing. A bare `minWidth`/`minHeight` pair leaves
    // the content's ideal size as its maximum too and the window then refuses
    // to grow OR shrink, measured at a hard 900x512 in both directions.
    // `.infinity` is what makes it resizable, and the scene needs
    // `.windowResizability(.contentMinSize)` to agree.
    .frame(
      minWidth: SettingsWindowMetrics.minWidth,
      idealWidth: SettingsWindowMetrics.idealWidth,
      maxWidth: .infinity,
      minHeight: SettingsWindowMetrics.minHeight,
      idealHeight: SettingsWindowMetrics.idealHeight,
      maxHeight: .infinity
    )
    // `navigationToken` re-runs the configurator on every push and pop.
    // Measured: a push flips `titleVisibility` back to visible, AppKit draws
    // the scene's own title at the LEADING edge next to the Back button, and it
    // LINGERS after the pop. With no dependency that changes with the path,
    // `updateNSView` never fires for a push and cannot re-hide it.
    // The title's `prefsRevision` read lives in the leaf: read here it re-ran
    // the whole shell on every pref write.
    .background(
      SettingsWindowTitleHost(
        displayKey: presentation.displayKey,
        fallbackTitle: selectedPaneTitle,
        navigationToken: currentPathDepth))
    // Debug screenshot hook: the window has no URL scheme and cannot be driven
    // by clicking without an Accessibility grant, so a capture run names its
    // destination through an env var and this adopts it once, where the
    // `@State` selection lives.
    //
    // The `#if` wraps the MODIFIER, not the closure body. Guarding the body
    // leaves Release with a live empty `.onAppear { }` and a comment naming the
    // debug env var.
    #if DEBUG
      .onAppear {
        if let pending = DebugSettingsHook.pendingSelection {
          DebugSettingsHook.pendingSelection = nil
          selection = pending
          if case let .display(key) = pending, let page = DebugSettingsHook.pendingSubPage {
            DebugSettingsHook.pendingSubPage = nil
            subPagePaths[key] = [page]
          }
          if let path = DebugSettingsHook.pendingOledPath {
            DebugSettingsHook.pendingOledPath = nil
            oledCarePath = path
          }
          if let path = DebugSettingsHook.pendingKeyboardPath {
            DebugSettingsHook.pendingKeyboardPath = nil
            keyboardPath = path
          }
          // A window, not a pushed page, so the capture route opens
          // it over the pane through the same closure the pane's links use.
          if let key = DebugSettingsHook.pendingHealthWindowKey {
            DebugSettingsHook.pendingHealthWindowKey = nil
            actions.openDisplayHealth(key)
          }
        }
      }
    #endif
    // A destination for an absent display must never render, so an unplug
    // while selected falls back to a surviving sibling first, then to General.
    // Keyed on persistence keys, not display IDs: an ID changes across a
    // replug and would evict the user every time a link renegotiated.
    //
    // The keys are `allControlledStates`, built-in first, which is sidebar
    // render order. Feeding externals only left sibling fallback unable to land
    // on the built-in row: unplugging the only external on an open laptop
    // dropped to General with a display destination still alive. The built-in
    // is a real departure source too, since clamshell removes it.
    .onChange(of: model.allControlledStates.map(\.display.persistenceKey)) { previous, connected in
      // A departed display's sub-page stack dies with it, selected or
      // not, so its return lands on the hub.
      for departed in Set(previous).subtracting(connected) {
        subPagePaths[departed] = nil
      }
      // Same rule for the OLED pane: a page for a departed display pops back
      // to the overview and the return does not resume it.
      if oledCarePath.contains(where: { !connected.contains($0.displayKey) }) {
        oledCarePath = []
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

      // A remembered display returning takes the selection back, unless the
      // user chose another display destination meanwhile.
      // `currentIsDisplay` reads the possibly-just-updated selection, so a
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
    // Tab starts on the page the user just chose, not back at the sidebar.
    .onChange(of: selection) { _, _ in
      detailFocusAnchor = true
    }
  }

  /// Every selection write, so the canvas relight, the sidebar pill and the
  /// page swap ride one transaction.
  ///
  /// Derived from `$selection`, never a fresh `Binding(get:set:)`: a hand-built
  /// binding carries no location, so SwiftUI cannot prove it equal between
  /// updates and every view holding it re-renders on each root body pass.
  private var animatedSelection: Binding<SettingsDestination?> {
    $selection.animation(SettingsTheme.selectionMotion)
  }

  private func select(_ destination: SettingsDestination?) {
    withAnimation(SettingsTheme.selectionMotion) { selection = destination }
  }

  /// Resolved from the same `presentation` the title and content are, so the
  /// canvas can never be lit for a destination that is not on screen.
  private var currentAccent: SettingsAccent {
    switch presentation {
    case let .display(key, _):
      displayAccent(for: key)
    case .pane:
      if case let .pane(id) = selection {
        SettingsRegistry.descriptor(for: id).accent
      } else {
        SettingsRegistry.descriptor(for: .general).accent
      }
    }
  }

  /// By position among the externals, the same rule the sidebar's rows use, so
  /// a row and the canvas it lights agree.
  ///
  /// A key with no position is lit neutral rather than by the first display's
  /// hue: borrowing another display's hue would have the canvas say the user is
  /// somewhere they are not.
  private func displayAccent(for key: String) -> SettingsAccent {
    guard key != "builtIn" else { return .display(isBuiltIn: true, ordinal: 0) }
    guard let index = model.displays.firstIndex(where: { $0.display.persistenceKey == key })
    else { return .neutral }
    return .display(isBuiltIn: false, ordinal: index)
  }

  /// Never a claim that the display exists; `presentation` decides that.
  private var selectedDisplayKey: String? {
    guard case let .display(key) = selection else { return nil }
    return key
  }

  /// THE resolution of what the detail column is showing. The title, the
  /// content, the pushed path and the window configurator all read this one
  /// value, because answering separately let them disagree within a frame.
  ///
  /// The case that diverged: the selected display drops out of
  /// `allControlledStates` for a pass, which a reconfiguration under an open
  /// window routinely produces. Title and root fell back to General while the
  /// path went on presenting a sub-page nothing could look up, so the stack
  /// rendered an empty destination over the fallback.
  ///
  /// Reads `subPagePaths` and never writes it: not presenting a path is not
  /// forgetting one.
  private var presentation: SettingsDetailPresentation<DisplaySubPage> {
    SettingsSelectionPolicy.present(
      selectedDisplayKey: selectedDisplayKey,
      retainedPath: selectedDisplayKey.flatMap { subPagePaths[$0] } ?? [],
      connectedKeys: model.allControlledStates.map(\.display.persistenceKey)
    )
  }

  /// The pane title, and the fallback for a display; the display half lives in
  /// `SettingsWindowTitleHost` to keep the rename dependency off this view.
  private var selectedPaneTitle: String {
    if case let .pane(id) = selection {
      SettingsRegistry.descriptor(for: id).title
    } else {
      // The fallback case, which `detailRoot` renders General for.
      SettingsRegistry.descriptor(for: .general).title
    }
  }

  /// ONE `NavigationStack` for the whole detail column, alive for the life of
  /// the window. Destroying a `NavigationStack` while it is PRESENTING a
  /// sub-page orphans the pushed page (measured 2026-08-07: sidebar and title
  /// said Keyboard, detail stayed frozen on the Advanced page until Back). A
  /// selection change must never remove the stack; it changes the ROOT and the
  /// PATH, so leaving a display pops its sub-page before the root swaps.
  ///
  /// The retention rule holds: the binding below still reads and writes
  /// per-display storage,
  /// and a pane selection just presents none of it.
  private var detail: some View {
    NavigationStack(path: currentPathBinding) {
      detailRoot
        // On macOS the stack keeps its ROOT rendered under the destination the
        // whole time a page is pushed. These pages are transparent so the canvas
        // shows through, and what showed through instead was both destinations
        // at once: two titles over one another, the overview's cards ghosting
        // under the pushed page's rows.
        //
        // Hidden, not removed. `displayRoot`'s countdown-ownership rule needs
        // the root to keep existing, and taking it out would drop the stack's
        // root while it is presenting, which is the orphaned-page defect above.
        // Hit testing and accessibility go with the opacity, or an invisible
        // control catches clicks and VoiceOver walks the hidden root.
        .opacity(hasPushedPage ? 0 : 1)
        .allowsHitTesting(!hasPushedPage)
        .accessibilityHidden(hasPushedPage)
        .navigationDestination(for: SettingsPushedPage.self) { pushed in
          Group {
            switch pushed {
            case let .display(page): pushedPage(page)
            case let .oledCare(page): oledPushedPage(page)
            case let .keyboard(page): keyboardPushedPage(page)
            }
          }
          // The system back item draws at the WINDOW's leading edge, over the
          // sidebar's wordmark rather than over the column it acts on.
          // `SubPageHeader` draws the back control in the page instead. Cmd-[
          // and re-clicking the sidebar row write the path directly.
          .navigationBarBackButtonHidden(true)
        }
    }
  }

  /// Whether the stack is PRESENTING a page: a retained path counts only while
  /// its destination is presented. Derived from `currentPathDepth` rather than
  /// a second read of the three stores, so the hidden root and the window
  /// configurator's token cannot disagree about whether a page is on screen.
  private var hasPushedPage: Bool { currentPathDepth > 0 }

  @ViewBuilder private var detailRoot: some View {
    switch presentation {
    case let .display(key, path):
      if let state = model.allControlledStates.first(where: { $0.display.persistenceKey == key }) {
        displayRoot(key: key, state: state, hasPushedPage: !path.isEmpty)
      } else {
        generalFallback
      }
    case .pane:
      if case let .pane(id) = selection {
        SettingsRegistry.descriptor(for: id).content()
      } else {
        generalFallback
      }
    }
  }

  /// The banner region sits above the root AND above every pushed page from
  /// these two placements alone, so a new sub-page cannot forget one.
  ///
  /// `.id(key)` on the ROOT CONTENT, never on the stack: it resets per-display
  /// root state on a switch without giving each display its own stack identity,
  /// which is the orphaned-page defect `detail` documents.
  private func displayRoot(
    key: String, state: AppModel.DisplayState, hasPushedPage: Bool
  ) -> some View {
    VStack(spacing: 0) {
      // The root keeps rendering behind a pushed page (see `detail`), so both
      // placements would build the SAME answerable countdown. The page is what
      // the reader is looking at, so it owns the answer and this one yields
      // while a page is PRESENTED. Presented, not retained: reading
      // `subPagePaths` here handed the answer to a page nobody could see.
      BannerRegion(state: state, ownsAnswerableCountdown: !hasPushedPage)
      if key == "builtIn" {
        BuiltInDisplayPane(selection: animatedSelection, path: pathBinding(for: key))
      } else {
        DisplayDetailView(
          state: state, selection: animatedSelection, path: pathBinding(for: key))
      }
    }
    .modifier(BannerColumnHeight())
    .id(key)
  }

  /// Resolved against the CURRENT selection, since the stack is shared. The
  /// guard goes empty for the frame in which a pane selection is still popping
  /// the outgoing display's page.
  private func pushedPage(_ page: DisplaySubPage) -> some View {
    Group {
      if case let .display(key, _) = presentation,
         let state = model.allControlledStates.first(where: { $0.display.persistenceKey == key }) {
        VStack(spacing: 0) {
          BannerRegion(state: state)
          subPage(page, key: key, state: state)
        }
        .modifier(BannerColumnHeight())
        // `.id(key)` on the pushed CONTENT, never on the stack (that re-keying
        // is the orphaned-page defect `detail` documents). The switcher keeps
        // this page presented while `state` re-resolves, so without the re-key
        // the sub-page's `@State` survives the switch and a draft typed on one
        // display commits into another's tuning.
        .id(key)
      }
    }
  }

  /// An OLED Care pushed page. Same placement rule as `pushedPage`:
  /// `.id` on the content, so a display switch resets page state.
  @ViewBuilder
  private func oledPushedPage(_ page: OledCarePage) -> some View {
    Group {
      // Rename dependency: the switcher's names come from `friendlyName` and
      // `DisplayPrefs` has no observation, so values passed INTO the page
      // register it here.
      let _ = model.prefsRevision
      if let state = model.displays.first(where: { $0.display.persistenceKey == page.displayKey }) {
        // Still a switch on one case, so a page added later is a compile error
        // rather than a silent fall-through onto the display page.
        Group {
          switch page {
          case .display:
            OledCareDisplayPage(
              state: state, displays: oledSwitcherDisplays, onSwitch: switchOledDisplay)
          }
        }
        .id(page.displayKey)
      }
    }
  }

  /// A Keyboard pushed page. No display dependence, so no resolution
  /// guard, no `.id` re-key and no switcher.
  @ViewBuilder
  private func keyboardPushedPage(_ page: KeyboardPage) -> some View {
    switch page {
    case .modifiers: KeyboardModifierKeysPage()
    case .targeting: KeyboardTargetingPage()
    }
  }

  /// OLED care never covers the built-in, so the switcher must not offer it.
  private var oledSwitcherDisplays: [(key: String, name: String)] {
    switcherDisplays.filter { $0.key != "builtIn" }
  }

  /// Swaps the SAME page depth onto another display by rewriting every
  /// element's key. The sidebar selection stays on the pane.
  private func switchOledDisplay(to newKey: String) {
    oledCarePath = oledCarePath.map { $0.withDisplayKey(newKey) }
  }

  /// The selected display's retained sub-page stack, or empty for a pane.
  /// Selecting a pane changes this binding's VALUE to `[]`, which pops the
  /// outgoing display's sub-page while the stack survives.
  ///
  /// The key is resolved ONCE, when the binding is built, and the setter drops
  /// writes made after the presentation stops matching it. The stack can flush
  /// a transition's write-back through a binding built before the selection
  /// moved, and a setter re-reading the selection landed that write under
  /// whatever was selected by then, clearing the NEW display's retained path on
  /// a display-to-display switch.
  ///
  /// Matching the PRESENTATION rather than the selection is what lets a display
  /// leaving the list pop its page without losing it: the getter reports empty,
  /// the stack writes `[]` back, and the same guard drops that write.
  private var currentPathBinding: Binding<[SettingsPushedPage]> {
    if let boundKey = presentation.displayKey {
      return Binding(
        get: { (subPagePaths[boundKey] ?? []).map(SettingsPushedPage.display) },
        // Against the PRESENTATION, the stronger of the two, so the `[]` the
        // stack writes back while popping a departed display is dropped and the
        // path stays retained.
        set: { newPath in
          guard presentation.displayKey == boundKey else { return }
          subPagePaths[boundKey] = newPath.compactMap {
            if case let .display(page) = $0 { page } else { nil }
          }
        }
      )
    }
    if case .pane(.oledCare) = selection {
      return Binding(
        get: { oledCarePath.map(SettingsPushedPage.oledCare) },
        // Same stale-write contract: a write landing after the selection moved
        // is dropped, which retains the pane's path.
        set: { newPath in
          guard case .pane(.oledCare) = selection else { return }
          oledCarePath = newPath.compactMap {
            if case let .oledCare(page) = $0 { page } else { nil }
          }
        }
      )
    }
    if case .pane(.keyboard) = selection {
      return Binding(
        get: { keyboardPath.map(SettingsPushedPage.keyboard) },
        // Same stale-write contract as the OLED branch above.
        set: { newPath in
          guard case .pane(.keyboard) = selection else { return }
          keyboardPath = newPath.compactMap {
            if case let .keyboard(page) = $0 { page } else { nil }
          }
        }
      )
    }
    return Binding(get: { [] }, set: { _ in })
  }

  /// Each page owns its own `SettingsPageScaffold`, so this switch names a view
  /// and nothing else. Every page starts with `SubPageHeader`, which supplies
  /// title focus on push and the display switcher.
  @ViewBuilder
  private func subPage(_ page: DisplaySubPage, key: String, state: AppModel.DisplayState) -> some View {
    // Rename dependency, registered HERE because `switcherDisplays` is read
    // here. `DisplayPrefs` has no observation, and a page's own body reading
    // `prefsRevision` does not cover the values passed INTO it.
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

  /// Pop focus restoration is the destination's job: `DisplayDetailView` and
  /// `BuiltInDisplayPane` each own a `@FocusState focusedRow` and hand focus
  /// back to the pushing row when this binding shrinks.
  private func pathBinding(for key: String) -> Binding<[DisplaySubPage]> {
    Binding(
      get: { subPagePaths[key] ?? [] },
      set: { subPagePaths[key] = $0 }
    )
  }

  /// Feeds the window configurator's `navigationToken`; any push or pop must
  /// re-run it.
  ///
  /// What is PRESENTED, never what is retained: a depth read from storage
  /// claimed a push for a display that had left the list, so the token stopped
  /// moving on the pop that actually happened.
  private var currentPathDepth: Int {
    presentation.pathDepth + oledPresentedDepth + keyboardPresentedDepth
  }

  /// Presented only while the pane is selected; retained depth counts for
  /// nothing, the same rule as `currentPathDepth`.
  private var oledPresentedDepth: Int {
    if case .pane(.oledCare) = selection { oledCarePath.count } else { 0 }
  }

  /// Same presented-not-retained rule for the Keyboard pane's stack.
  private var keyboardPresentedDepth: Int {
    if case .pane(.keyboard) = selection { keyboardPath.count } else { 0 }
  }

  /// Sidebar render order: the registry's panes in section order, then
  /// `allControlledStates`. The command-number shortcuts index into this, and
  /// `SettingsRegistry.panes` follows `sections`, so re-sectioning the sidebar
  /// moves the shortcuts with it.
  private var orderedDestinations: [SettingsDestination] {
    SettingsRegistry.panes.map { .pane($0.id) }
      + model.allControlledStates.map { .display($0.display.persistenceKey) }
  }

  /// Clicking the sidebar row you are already on returns that destination to
  /// its root. Without it the click does nothing, since the row writes a
  /// selection that is already the selection.
  ///
  /// The retention rule holds: only the re-clicked destination is cleared,
  /// so A to
  /// B to A still lands where the user was.
  ///
  /// The write goes through `currentPathBinding` rather than `subPagePaths`, so
  /// the destination's shrink-detecting `onChange` sees a pop and restores
  /// focus to the row that pushed.
  private func returnToHub(_ destination: SettingsDestination) {
    guard destination == selection else { return }
    if case let .display(_, path) = presentation, !path.isEmpty {
      currentPathBinding.wrappedValue = []
    } else if case .pane(.oledCare) = selection, !oledCarePath.isEmpty {
      // Same as a display's row: return to this destination's root.
      oledCarePath = []
    } else if case .pane(.keyboard) = selection, !keyboardPath.isEmpty {
      keyboardPath = []
    }
  }

  /// Gated on the PRESENTED path, so the shortcut cannot quietly edit a stack
  /// that is not on screen.
  private func popCurrentSubPage() {
    if case let .display(key, path) = presentation, !path.isEmpty {
      subPagePaths[key] = Array(path.dropLast())
    } else if case .pane(.oledCare) = selection, !oledCarePath.isEmpty {
      oledCarePath.removeLast()
    } else if case .pane(.keyboard) = selection, !keyboardPath.isEmpty {
      keyboardPath.removeLast()
    }
  }

  /// Named the way the sidebar names them, so the switcher menu and the sidebar
  /// cannot disagree about what a display is called.
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

  /// The comparison workflow: the sub-page carries over, THEN the sidebar
  /// selection moves. The whole path is copied, not just the visible page.
  private func switchDisplay(from currentKey: String, to newKey: String) {
    subPagePaths[newKey] = subPagePaths[currentKey] ?? []
    select(.display(newKey))
  }

  /// An unresolvable selection shows General rather than a blank pane, which
  /// reads as a broken window.
  private var generalFallback: some View {
    SettingsRegistry.descriptor(for: .general).content()
  }
}

/// Stops a banner from making the WINDOW taller instead of the page shorter.
///
/// A page reporting a minimum height near its own content, plus a banner
/// stacked above it, once passed what the window could show: the whole SwiftUI
/// root was laid out taller than the window and clipped from the TOP. Both
/// columns rode up, the sidebar lost its first rows behind the traffic lights,
/// and the detail column was cut mid-row.
///
/// A minimum of 0 breaks the chain: the column accepts whatever height the
/// window has and the content scrolls inside it. **`.safeAreaInset` does NOT do
/// this**, measured: inset content contributes to the container's minimum
/// exactly like a stacked sibling.
///
/// A modifier rather than two copies of one line, since the root and every
/// pushed page need it.
private struct BannerColumnHeight: ViewModifier {
  func body(content: Content) -> some View {
    content.frame(minHeight: 0, maxHeight: .infinity)
  }
}

/// **The two ideals size a window that has never been sized before, and nothing
/// else** [MEASURED 2026-08-11]. AppKit autosaves this window's frame, SIZE
/// included, under `NSWindow Frame com_apple_SwiftUI_Settings_window` and
/// restores it ahead of anything SwiftUI computes. Once a corner has been
/// dragged, or a reconfiguration has re-fitted the window, that saved frame is
/// the size for good.
///
/// So `idealWidth` disagreeing with the window on screen is the DESIGNED state.
/// **Never quote a size as this window's**, in a comment, a doc or a UI
/// selector: a checkpoint script once selected the window by a literal
/// `{900, 568}`.
///
/// Two measured routes back to the ideals. With the app quit:
/// `defaults delete com.rydersel.Candela "NSWindow Frame com_apple_SwiftUI_Settings_window"`.
/// Or Reset All Settings, whose `removePersistentDomain` takes the key with
/// everything else; closing the resized window afterwards does NOT write the
/// frame back.
///
/// The MINIMA are a different contract and are not advisory
/// (`SettingsWindowConfigurator.pinMinimumSize`). A frame saved under the floor
/// is clamped back up to it on the next launch rather than restored as saved.
enum SettingsWindowMetrics {
  static let minWidth: CGFloat = 1040
  /// First-launch width only. Read the note above before quoting it.
  static let idealWidth: CGFloat = 1100
  static let minHeight: CGFloat = 660
  /// First-launch height only. Read the note above before quoting it.
  static let idealHeight: CGFloat = 680

  static var minContentSize: NSSize { NSSize(width: minWidth, height: minHeight) }
}

/// Hosts the configurator and resolves the title, so the shell's only
/// `prefsRevision` dependency is this leaf that draws nothing. A rename is a pref
/// write with no observation of its own, so the title has to hang off the
/// revision, and read in the shell it re-ran the whole window per pref write.
///
/// Display destinations use the resolved name: the window draws no title of its
/// own, so this reaches only the Window menu and VoiceOver, where the hardware
/// name would be a display nobody renamed.
private struct SettingsWindowTitleHost: View {
  let displayKey: String?
  /// Also covers the same-frame race where the key has left the connected states.
  let fallbackTitle: String
  let navigationToken: Int

  @Environment(AppModel.self) private var model

  var body: some View {
    SettingsWindowConfigurator(title: title, navigationToken: navigationToken)
  }

  private var title: String {
    guard let displayKey else { return fallbackTitle }
    // The revision read that this view exists to contain.
    _ = model.prefsRevision
    return
      model.allControlledStates
      .first { $0.display.persistenceKey == displayKey }
      .map {
        DisplayOrdering.title(
          friendlyName: DisplayPrefs(persistenceKey: displayKey).friendlyName,
          hardwareName: $0.display.name)
      } ?? fallbackTitle
  }
}

/// The window chrome a `Settings` scene does not offer: the `.resizable` and
/// `.fullSizeContentView` style masks, the dark appearance, the transparent
/// titlebar, and dragging by the background.
///
/// No SwiftUI modifier restores resizability. `.windowResizability(.contentMinSize)`
/// plus an `.infinity` content frame still leave the zoom button disabled and
/// the window pinned, measured at a hard 900x512 in both directions.
///
/// This hangs off the VIEW rather than `SettingsOpener` deliberately: Cmd-comma
/// goes straight to SwiftUI's own menu item, so a fix installed on the open
/// path only works when the window is opened from the panel's gear.
///
/// It also owns the window's NAME, set but with `titleVisibility` hidden. The
/// title feeds the Window menu and accessibility; drawing it would put a second
/// name at the leading edge over the sidebar's wordmark.
///
/// The dark appearance is pinned here as well as by `.preferredColorScheme`
/// because the appearance decides the titlebar and traffic lights, which
/// the colour scheme does not reach.
///
/// **The whole contract is re-asserted, never written once.** Every property
/// below is one AppKit or SwiftUI can change back. The previous shape wrote them
/// from a `DispatchQueue.main.async` hop off `updateNSView`, and a hop that
/// found no window dropped the write with nothing to retry it, leaving
/// `window.title` on a destination the user had long since left.
private struct SettingsWindowConfigurator: NSViewRepresentable {
  let title: String
  /// Changes on push and pop so `updateNSView` fires then, re-asserting the
  /// contract promptly. Measured: a push flips `titleVisibility` back to visible
  /// and draws the window title at the leading edge.
  let navigationToken: Int

  func makeNSView(context: Context) -> NSView {
    let coordinator = context.coordinator
    coordinator.desiredTitle = title
    let view = WindowAttachedView()
    // The view has no window during `makeNSView`, and asking again after a
    // `DispatchQueue.main.async` hop answered nil whenever the hop lost the
    // race, with nothing to retry it.
    view.onAttach = { [weak coordinator] window in coordinator?.apply(to: window) }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.desiredTitle = title
    if let window = view.window { coordinator.apply(to: window) }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// Reports the moment it has a window, so the contract is applied then rather
  /// than after a hop that may find none.
  final class WindowAttachedView: NSView {
    var onAttach: (NSWindow) -> Void = { _ in }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window { onAttach(window) }
    }
  }

  /// Holds the desired title and the `didUpdateNotification` observation that
  /// re-asserts the window contract whenever AppKit changes it back.
  ///
  /// `navigationToken` catches the flips riding a push or a pop, but measured
  /// cases flip `titleVisibility` with no `updateNSView` dependency changing:
  /// Back out of a page whose selection had already moved, and the banner
  /// region appearing over the hub. So enforcement rides
  /// `NSWindow.didUpdateNotification`, which AppKit posts every update pass.
  /// Every write below is guarded by a comparison, so the notification cannot
  /// feed back on itself.
  ///
  /// The title is re-asserted alongside the visibility. Re-hiding a wrong title
  /// only hides the disagreement, and the frame where AppKit wins the race
  /// still shows a window named for a pane that is not on screen.
  final class Coordinator {
    // Nonisolated storage so `deinit` can remove the observer: a `@MainActor`
    // property is unreachable from a nonisolated deinit under Swift 6.
    // `removeObserver` is thread-safe, and both properties are only ever
    // WRITTEN from `apply(to:)`, which is main-actor.
    private var observer: NSObjectProtocol?
    private weak var observedWindow: NSWindow?
    private var title = ""

    /// Re-applied to the window the moment it changes, so a dropped write
    /// cannot outlive one update.
    @MainActor var desiredTitle: String {
      get { title }
      set {
        guard title != newValue else { return }
        title = newValue
        if let observedWindow { apply(to: observedWindow) }
      }
    }

    /// Hands the window into the `@Sendable` notification closure.
    /// `@unchecked Sendable` is justified by confinement: the box is only ever
    /// opened inside `MainActor.assumeIsolated` on the `.main` queue, which is
    /// where NSWindow lives.
    private struct WeakWindowBox: @unchecked Sendable {
      weak var window: NSWindow?
    }

    /// Same trick and same justification for the coordinator: opened only
    /// inside `MainActor.assumeIsolated` on the `.main` queue, the only place
    /// this object is touched. Weak, so the observation cannot keep a torn-down
    /// coordinator alive.
    private struct WeakCoordinatorBox: @unchecked Sendable {
      weak var coordinator: Coordinator?
    }

    @MainActor func apply(to window: NSWindow) {
      observe(window)
      if !window.styleMask.contains(.resizable) {
        window.styleMask.insert(.resizable)
      }
      // The canvas runs to the top, so the titlebar has to be glass over it
      // rather than a band of its own.
      if !window.styleMask.contains(.fullSizeContentView) {
        window.styleMask.insert(.fullSizeContentView)
      }
      if !window.titlebarAppearsTransparent {
        window.titlebarAppearsTransparent = true
      }
      // Dark-only: the titlebar and traffic lights read the appearance
      // and never see `.preferredColorScheme`.
      if window.appearance?.name != .darkAqua {
        window.appearance = NSAppearance(named: .darkAqua)
      }
      // With no titlebar band to grab, the canvas is the handle.
      if !window.isMovableByWindowBackground {
        window.isMovableByWindowBackground = true
      }
      // Named but not drawn: the page names the destination, so letting AppKit
      // draw this too puts a second name at the leading edge. `title` still
      // feeds the Window menu and accessibility.
      if window.titleVisibility != .hidden {
        window.titleVisibility = .hidden
      }
      // A pushed page still gets SwiftUI's Back item, and the default style
      // puts it in its own band BELOW the titlebar: a strip of dead space
      // across the top of both columns, measured at 24 pt. `.unifiedCompact`
      // merges the two rows.
      if window.toolbarStyle != .unifiedCompact {
        window.toolbarStyle = .unifiedCompact
      }
      // Empty only before the first update, and a window briefly named "" is
      // worse than one still named by the scene.
      if !title.isEmpty, window.title != title {
        window.title = title
      }
      pinMinimumSize(on: window)
    }

    /// The floor SwiftUI declares, pinned where it can actually hold.
    ///
    /// RAISES `contentMinSize` and never lowers it: SwiftUI computes its own
    /// answer from the content, and clamping that down would overrule a
    /// measurement this type did not take. Idempotent, which is what lets it
    /// sit on a per-update-pass notification.
    @MainActor private func pinMinimumSize(on window: NSWindow) {
      let floor = SettingsWindowMetrics.minContentSize
      var minimum = window.contentMinSize
      minimum.width = max(minimum.width, floor.width)
      minimum.height = max(minimum.height, floor.height)
      if window.contentMinSize != minimum {
        window.contentMinSize = minimum
      }
    }

    /// Grows a window already under the floor back up to it. Raising
    /// `contentMinSize` does not move a window that is already smaller, and the
    /// reported state clipped its content rather than scrolling, so what was cut
    /// off could not be reached at all. AppKit clamps a live user resize itself,
    /// so this only fires for a size something else chose.
    ///
    /// Called from the update-pass notification, never `updateNSView`: resizing
    /// from inside SwiftUI's own update is a re-entrant layout nobody needs.
    ///
    /// Capped at the screen, since a window taller than its display is not an
    /// improvement on a clipped one.
    @MainActor private func restoreMinimumSize(on window: NSWindow) {
      let minimum = window.contentMinSize
      let content = window.contentRect(forFrameRect: window.frame).size
      guard content.width < minimum.width - 0.5 || content.height < minimum.height - 0.5
      else { return }
      let available = window.screen?.visibleFrame.size
      let chrome = max(window.frame.height - content.height, 0)
      window.setContentSize(NSSize(
        width: min(max(content.width, minimum.width), available?.width ?? .greatestFiniteMagnitude),
        height: min(
          max(content.height, minimum.height),
          (available?.height ?? .greatestFiniteMagnitude) - chrome
        )
      ))
    }

    @MainActor private func observe(_ window: NSWindow) {
      guard observedWindow !== window else { return }
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observedWindow = window
      let box = WeakWindowBox(window: window)
      let owner = WeakCoordinatorBox(coordinator: self)
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didUpdateNotification, object: window, queue: .main
      ) { _ in
        // didUpdateNotification is posted on the main thread; assumeIsolated
        // bridges from the nonisolated closure to the AppKit calls below.
        MainActor.assumeIsolated {
          guard let coordinator = owner.coordinator, let window = box.window else { return }
          coordinator.apply(to: window)
          coordinator.restoreMinimumSize(on: window)
        }
      }
    }

    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }
  }
}

/// LSUIElement plus Settings-scene activation. Every part of this sequence was
/// measured on macOS 26 against an isolated LSUIElement harness driving a real
/// NSStatusItem tracking session. The obvious spelling is broken two ways.
///
/// 1. `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`
///    is delivered (`SwiftUI.AppDelegate` implements it and `sendAction`
///    returns `true`) but **no window is ever created**. A silent no-op, so
///    the return value cannot even detect the failure. Performing the app
///    menu's own Settings item works, which is the path Cmd-comma takes.
///
/// 2. `NSApp.activate()` and `NSRunningApplication.current.activate(options:)`
///    will not activate an accessory-policy app from inside a menu tracking
///    session. The window opens behind the frontmost app and never becomes key.
///    `makeKeyAndOrderFront` and `orderFrontRegardless` do not rescue it,
///    because key-ness follows app activation, not window ordering. Only the
///    deprecated `activate(ignoringOtherApps:)` works.
///
/// Both calls must stay **synchronous**, inside the click's event context.
/// Deferring either with `DispatchQueue.main.async` loses the activation grant
/// and puts the window back behind the frontmost app (measured).
@MainActor
enum SettingsOpener {
  static func open() {
    // The gear button lives inside the panel's menu tracking session, and no
    // window can take focus while one runs. `PanelMenu` is the one holder,
    // since a second panel control also has to end tracking.
    PanelMenu.endTracking()
    // Deprecated since macOS 14 and used anyway: the replacement does not
    // activate an LSUIElement app from a tracking session. Revisit only against
    // a measurement, never against the deprecation warning alone.
    NSApp.activate(ignoringOtherApps: true)
    if let item = settingsMenuItem, let action = item.action {
      NSApp.sendAction(action, to: item.target, from: item)
    } else {
      // A no-op on macOS 26, kept only so a future SwiftUI that stops
      // publishing the menu item degrades to "maybe".
      NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
  }

  /// Found by its key equivalent, not its title: the title is SwiftUI's and has
  /// changed across releases, while the HIG fixes the key. Scoped to the app
  /// menu so another Cmd-comma in the menu bar cannot be mistaken for it.
  private static var settingsMenuItem: NSMenuItem? {
    NSApp.mainMenu?.items.first?.submenu?.items.first {
      $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
    }
  }
}
