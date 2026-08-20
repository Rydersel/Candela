import AppKit
import CandelaKit
import SwiftUI

/// Sidebar navigation over a pane registry. Replaces the five-tab `TabView`,
/// whose tab-for-tab match with the fork was the actual source of the visual
/// resemblance.
///
/// The shell is hand-built (SV4): a canvas, a fixed-width sidebar, a hairline,
/// and the detail column. It was a framework split view until the visual
/// redesign, and what that cost was the whole surface: a split view owns its
/// column backgrounds, so no canvas could be drawn under both columns, and its
/// sidebar column drew a panel that dimmed whenever the window lost focus. It
/// also brought a collapse hazard with it, since AppKit's `NSSplitView` could
/// hide the sidebar under a squeeze and autosave that state, leaving a window
/// with no navigation and no way back from inside the app. A fixed column
/// cannot collapse, so that whole defence retires with the split view.
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
  /// The OLED Care pane's pushed-page stack (OCR1). Lives here beside
  /// `subPagePaths` because it rides the same `NavigationStack`; retained
  /// across selection changes like a display's stack (SO23's rule applied to
  /// the pane), cleared when a display in it departs, and popped by the
  /// sidebar row's re-click. Display Health is NOT in this stack: it opens
  /// in its own window (OCR-A1), an AppKit island reached through
  /// `SettingsActions.openDisplayHealth`.
  @State private var oledCarePath: [OledCarePage] = []
  /// For the debug capture route's Display Health window; the pane's own
  /// health links read the same actions object from their environment.
  @Environment(SettingsActions.self) private var actions
  /// The Keyboard pane's pushed-page stack (KMR11): same NavigationStack, same
  /// retention rules as the OLED pane's, minus the display dependence — these
  /// pages name no hardware, so departure clearing never touches this.
  @State private var keyboardPath: [KeyboardPage] = []
  /// Accessibility contract 2: selecting a sidebar destination moves focus
  /// into the detail column. Anchored on the detail root; hand-verified only
  /// (no app test target, and synthetic keys go to the terminal, not an
  /// LSUIElement app).
  @FocusState private var detailFocusAnchor: Bool

  @Environment(AppModel.self) private var model

  var body: some View {
    ZStack {
      // The ground under both columns, lit by whatever destination is on
      // screen. One canvas for the life of the window, so a selection change
      // moves the light rather than cutting to a new one (SV8).
      SettingsCanvas(accent: currentAccent.accent, secondary: currentAccent.secondary)
      HStack(spacing: 0) {
        SettingsSidebar(selection: animatedSelection, onReselect: returnToHub)
          // Fixed, not a resizable split-view column: nothing in this window
          // needs a wider sidebar, and a fixed column cannot be collapsed to
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
          // Keyboard contract (accessibility contract 2): ⌘[ pops the current
          // display's sub-page; ⌘1–⌘9 select the first nine sidebar
          // destinations in sidebar render order. Hidden buttons rather than
          // `.commands`: the `Settings` scene's menu bar is not this view's to
          // edit, and a shortcut on a button in the key window's hierarchy
          // fires without being visible. Not tab-reachable at zero size;
          // VoiceOver skips them via `accessibilityHidden`.
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
    // Published once for the whole shell, so the sidebar's wordmark and every
    // themed component on the page read one destination's lighting.
    .environment(\.settingsAccent, currentAccent)
    // Dark-only (SV2). Every colour in this window comes from the theme layer,
    // and none of them has a light-appearance answer.
    .preferredColorScheme(.dark)
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
      minWidth: SettingsWindowMetrics.minWidth,
      idealWidth: SettingsWindowMetrics.idealWidth,
      maxWidth: .infinity,
      minHeight: SettingsWindowMetrics.minHeight,
      idealHeight: SettingsWindowMetrics.idealHeight,
      maxHeight: .infinity
    )
    // `navigationToken` re-runs the configurator on every push and pop.
    // Measured in the Task 9 spike: a push flips `titleVisibility` back to
    // visible and AppKit draws the scene's own "Candela Settings" at the
    // LEADING edge next to the Back button, and it LINGERS after the pop.
    // Without a dependency that changes with the path, `updateNSView` never
    // fires for a push/pop and cannot re-hide it.
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
          if let path = DebugSettingsHook.pendingOledPath {
            DebugSettingsHook.pendingOledPath = nil
            oledCarePath = path
          }
          if let path = DebugSettingsHook.pendingKeyboardPath {
            DebugSettingsHook.pendingKeyboardPath = nil
            keyboardPath = path
          }
          // Display Health is a window, not a pushed page (OCR-A1), so its
          // capture route opens the window over the pane it left behind,
          // through the same actions closure the pane's own links use.
          if let key = DebugSettingsHook.pendingHealthWindowKey {
            DebugSettingsHook.pendingHealthWindowKey = nil
            actions.openDisplayHealth(key)
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
      // The OLED pane's stack follows the same rule: a pushed page for a
      // display that left pops back to the overview, and the return does not
      // resume it.
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
  }

  /// Every selection write in this window, so the canvas relight, the sidebar
  /// pill and the page swap all ride one transaction (SV8). The sidebar writes
  /// through the binding; the shortcuts and the display switcher call `select`.
  private var animatedSelection: Binding<SettingsDestination?> {
    Binding(get: { selection }, set: { new in
      withAnimation(SettingsTheme.selectionMotion) { selection = new }
    })
  }

  private func select(_ destination: SettingsDestination?) {
    withAnimation(SettingsTheme.selectionMotion) { selection = destination }
  }

  /// The lighting the whole window reads: the destination's own pair, resolved
  /// from the same `presentation` the title and the content resolve from, so
  /// the canvas can never be lit for a destination that is not on screen.
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

  /// A display's hue, chosen by its position among the externals: the same
  /// rule the sidebar's rows use, so a row and the canvas it lights agree.
  private func displayAccent(for key: String) -> SettingsAccent {
    guard key != "builtIn" else { return .display(isBuiltIn: true, ordinal: 0) }
    let index = model.displays.firstIndex { $0.display.persistenceKey == key } ?? 0
    return .display(isBuiltIn: false, ordinal: index)
  }

  /// The selected display's key, or nil for a pane. Never a claim that the
  /// display exists: `presentation` is what decides that.
  private var selectedDisplayKey: String? {
    guard case let .display(key) = selection else { return nil }
    return key
  }

  /// THE resolution of what the detail column is showing (#124). The title, the
  /// content, the pushed path and the window configurator all read this one
  /// value; before it, each answered the question separately from the same
  /// inputs and they could disagree within a frame.
  ///
  /// The case that used to diverge: the selected display drops out of
  /// `allControlledStates` for a pass, which a display reconfiguration under an
  /// open window routinely produces. `currentTitle` and `detailRoot` both fell
  /// back to General, but the path went on presenting a sub-page for a display
  /// nothing could look up, so the stack rendered an empty destination over the
  /// fallback: no content and no toolbar title. Resolving it once makes that
  /// state unrepresentable rather than caught at three sites.
  ///
  /// It reads `subPagePaths` and never writes it, so SO23 retention is
  /// untouched: not presenting a path is not forgetting one.
  private var presentation: SettingsDetailPresentation<DisplaySubPage> {
    SettingsSelectionPolicy.present(
      selectedDisplayKey: selectedDisplayKey,
      retainedPath: selectedDisplayKey.flatMap { subPagePaths[$0] } ?? [],
      connectedKeys: model.allControlledStates.map(\.display.persistenceKey)
    )
  }

  /// The title shown centred in the toolbar. Resolved from `presentation`
  /// rather than read back from the panes, so every destination titles itself
  /// the same way and the title always names what is on screen.
  /// Display destinations use the display's own name, not a pane label.
  private var currentTitle: String {
    switch presentation {
    case let .display(key, _):
      // The `??` is the same-frame race, not a second policy: `presentation`
      // has already established the key is connected.
      model.allControlledStates
        .first { $0.display.persistenceKey == key }
        .map(\.display.name) ?? SettingsRegistry.descriptor(for: .general).title
    case .pane:
      if case let .pane(id) = selection {
        SettingsRegistry.descriptor(for: id).title
      } else {
        // A pane presentation with a display selection is the fallback case,
        // and `detailRoot` renders General for it. Same words, same source.
        SettingsRegistry.descriptor(for: .general).title
      }
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
        .navigationDestination(for: SettingsPushedPage.self) { pushed in
          switch pushed {
          case let .display(page): pushedPage(page)
          case let .oledCare(page): oledPushedPage(page)
          case let .keyboard(page): keyboardPushedPage(page)
          }
        }
    }
  }

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

  /// One display destination's root: the banner region sits above the root AND
  /// above every pushed page from these two placements alone (SO7); pages
  /// never own banners, so a new sub-page cannot forget one.
  ///
  /// `.id(key)` on the ROOT CONTENT, never on the stack: it still resets
  /// per-display root state (scroll, focus) on a switch, without giving each
  /// display its own stack identity, which is the orphaned-page defect `detail`
  /// documents.
  private func displayRoot(
    key: String, state: AppModel.DisplayState, hasPushedPage: Bool
  ) -> some View {
    VStack(spacing: 0) {
      // The root stays in the stack behind a pushed page and keeps rendering,
      // so both placements would draw the SAME answerable countdown. The pushed
      // page is the one the reader is looking at, so it owns the answer; this
      // one yields while a page is PRESENTED and keeps every passive banner.
      // Presented, not retained: a page held for a display that cannot be shown
      // is not on screen to own anything, and reading `subPagePaths` directly
      // here handed the answer to a page nobody could see.
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

  /// A pushed sub-page, resolved against the CURRENT selection: the stack is
  /// shared, so a page is only ever presented for the selected display. The
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
        // `.id(key)` on the pushed CONTENT, mirroring `displayRoot`, and never
        // on the stack (that re-keying is the orphaned-page defect `detail`
        // documents). The switcher keeps this page presented while `state`
        // re-resolves to the new display, so without the re-key the sub-page's
        // `@State` (drafts, focus, list filters) survived the switch and
        // rendered against the new display's prefs; a draft typed on one
        // display could then commit into another's tuning (SO10).
        .id(key)
      }
    }
  }

  /// An OLED Care pushed page (OCR1), resolved against the connected
  /// externals. Same placement rule as `pushedPage`: `.id` on the content so a
  /// display switch resets page state (SO10's lesson). The guard goes empty
  /// for the frame in which a departed display's page is still popping.
  @ViewBuilder
  private func oledPushedPage(_ page: OledCarePage) -> some View {
    Group {
      // Rename dependency, the sub-page switcher's rule: the switcher's names
      // come from `friendlyName`, and `DisplayPrefs` has no observation of
      // its own, so the values passed INTO the page register it here.
      let _ = model.prefsRevision
      if let state = model.displays.first(where: { $0.display.persistenceKey == page.displayKey }) {
        Group {
          switch page {
          case .display:
            OledCareDisplayPage(
              state: state, path: $oledCarePath,
              displays: oledSwitcherDisplays, onSwitch: switchOledDisplay)
          case .measurement:
            OledCareMeasurementPage(
              state: state, displays: oledSwitcherDisplays, onSwitch: switchOledDisplay)
          }
        }
        .id(page.displayKey)
      }
    }
  }

  /// A Keyboard pushed page (KMR11). No display dependence: no resolution
  /// guard, no `.id` re-key, no switcher; the page renders from app-level
  /// prefs alone.
  @ViewBuilder
  private func keyboardPushedPage(_ page: KeyboardPage) -> some View {
    switch page {
    case .modifiers: KeyboardModifierKeysPage()
    case .targeting: KeyboardTargetingPage()
    }
  }

  /// External displays only: OLED care never covers the built-in (its copy
  /// says so), so the switcher must not offer it.
  private var oledSwitcherDisplays: [(key: String, name: String)] {
    switcherDisplays.filter { $0.key != "builtIn" }
  }

  /// The OLED switcher swaps the SAME page depth onto another display by
  /// rewriting every element's key; the sidebar selection stays on the pane.
  private func switchOledDisplay(to newKey: String) {
    oledCarePath = oledCarePath.map { $0.withDisplayKey(newKey) }
  }

  /// The persistent stack's path: the selected display's retained sub-page
  /// stack, or empty for a pane. Selecting a pane changes this binding's VALUE
  /// to `[]`, which is what pops the outgoing display's sub-page while the
  /// stack survives.
  ///
  /// The key is resolved ONCE, when the binding is built, and the setter drops
  /// any write made after the presentation stops matching it. The stack can
  /// flush a transition's write-back through a binding built before the
  /// selection moved; a setter that re-read the selection at write time landed
  /// that write under whatever was selected by then, which on a
  /// display-to-display switch cleared the NEW display's retained path (SO23).
  /// The pane branch keeps the old rule as its degenerate case: reads are empty
  /// and every write is dropped.
  ///
  /// Matching against the PRESENTATION rather than the selection is what makes
  /// a display leaving the list pop its page (#124) without losing it: the
  /// getter reports empty, the stack pops and writes `[]` back, and that write
  /// is dropped by the same guard, so the retained path is still there when the
  /// display returns.
  private var currentPathBinding: Binding<[SettingsPushedPage]> {
    if let boundKey = presentation.displayKey {
      return Binding(
        get: { (subPagePaths[boundKey] ?? []).map(SettingsPushedPage.display) },
        // Against the PRESENTATION, not the selection: it is the stronger of
        // the two (a presented display is a selected one), and it is what
        // drops the `[]` the stack writes back as it pops a display that has
        // left the list. Dropping that write is the point: the path stays
        // retained (SO23) while nothing presents it.
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
        // Same stale-write contract: a write landing after the selection
        // moved is dropped, which is what retains the pane's path while
        // nothing presents it.
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
        // Same stale-write contract as the OLED branch above (KMR11).
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
  /// re-run it (see the call site). Panes other than OLED Care have no stack
  /// and sit at depth 0.
  ///
  /// What is PRESENTED, never what is retained: a depth read from storage
  /// claimed a push for a display that had left the list, so the token stopped
  /// moving on the pop that actually happened. The OLED depth follows the same
  /// rule through `oledPresentedDepth`'s selection gate.
  private var currentPathDepth: Int {
    presentation.pathDepth + oledPresentedDepth + keyboardPresentedDepth
  }

  /// The OLED pane's stack is presented only while the pane is selected;
  /// retained depth counts for nothing (the same presented-not-retained rule
  /// as `currentPathDepth`).
  private var oledPresentedDepth: Int {
    if case .pane(.oledCare) = selection { oledCarePath.count } else { 0 }
  }

  /// Same presented-not-retained rule for the Keyboard pane's stack (KMR11).
  private var keyboardPresentedDepth: Int {
    if case .pane(.keyboard) = selection { keyboardPath.count } else { 0 }
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
    guard destination == selection else { return }
    if case let .display(_, path) = presentation, !path.isEmpty {
      currentPathBinding.wrappedValue = []
    } else if case .pane(.oledCare) = selection, !oledCarePath.isEmpty {
      // The OLED pane's row does the same thing a display's row does: return
      // to this destination's root.
      oledCarePath = []
    } else if case .pane(.keyboard) = selection, !keyboardPath.isEmpty {
      keyboardPath = []
    }
  }

  /// ⌘[ pops what is on screen. Gated on the PRESENTED path, so the shortcut
  /// cannot quietly edit a stack that is not being shown.
  private func popCurrentSubPage() {
    if case let .display(key, path) = presentation, !path.isEmpty {
      subPagePaths[key] = Array(path.dropLast())
    } else if case .pane(.oledCare) = selection, !oledCarePath.isEmpty {
      oledCarePath.removeLast()
    } else if case .pane(.keyboard) = selection, !keyboardPath.isEmpty {
      keyboardPath.removeLast()
    }
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
    select(.display(newKey))
  }

  /// The detail column is never empty: an unresolvable selection shows General
  /// rather than a blank pane, which reads as a broken window.
  private var generalFallback: some View {
    SettingsRegistry.descriptor(for: .general).content()
  }
}

/// The settings window's size floor, declared once.
///
/// It used to live only in the SwiftUI content frame, which made it advisory:
/// `.windowResizability(.contentMinSize)` stops the USER shrinking the window
/// past it, and stops nothing else. A window AppKit re-fits (a display
/// reconfiguration moving the window's screen out from under it) can land below
/// the floor, and SwiftUI answers that by clipping the content rather than by
/// keeping the size, which is #124's clipped window. `SettingsWindowConfigurator`
/// enforces the same numbers on the `NSWindow`, so both layers read one source.
/// Stops a banner from making the WINDOW taller instead of the page shorter
/// (#124).
///
/// A display's page is a grouped `Form`, and a grouped `Form` reports a minimum
/// height near its content rather than the small one a scroll view usually has.
/// Stacking a banner above it added that banner's height to a minimum already
/// close to the window's, and once the total passed what the window could show,
/// the whole SwiftUI root was laid out taller than the window and clipped from
/// the TOP: both columns rode up, the sidebar lost its first five rows behind
/// the traffic lights, and the detail column was cut mid-row. Every symptom
/// #124 was filed for is that one clip.
///
/// A minimum of 0 is what breaks the chain: the column then accepts whatever
/// height the window has and the `Form` scrolls inside it, which is what a
/// banner appearing is supposed to cost. **`.safeAreaInset` does NOT do this**
/// and was measured doing nothing here: inset content contributes to the
/// container's minimum exactly like a stacked sibling does.
///
/// A modifier rather than two copies of one line, because the root and every
/// pushed page need the same treatment and the reason is too easy to lose.
private struct BannerColumnHeight: ViewModifier {
  func body(content: Content) -> some View {
    content.frame(minHeight: 0, maxHeight: .infinity)
  }
}

/// **The two ideals size a window that has never been sized before, and nothing
/// else** [MEASURED 2026-08-11, #149]. AppKit autosaves this window's frame,
/// SIZE included, under `NSWindow Frame com_apple_SwiftUI_Settings_window` in
/// the app's own defaults domain, and restores it ahead of anything SwiftUI
/// computes. Once a person has dragged a corner, or a display reconfiguration
/// has re-fitted the window, that saved frame is the size for good and these
/// numbers never speak again.
///
/// So `idealWidth` disagreeing with the window on screen is the DESIGNED state,
/// not a defect: #149 was filed on the disagreement, and the harness that
/// settled it reproduced 1005x580 from a saved frame alone, with a page whose
/// content wanted 900. Reading these constants as "the window is 900 wide" is
/// what made a resize look like a regression, and it is also why the checkpoint
/// scripts once selected the window by a literal `{900, 568}`. Never quote a
/// size as this window's, in a comment, a doc or a selector.
///
/// Two routes back to the ideals, both measured in that harness. From a shell,
/// with the app quit:
/// `defaults delete com.rydersel.Candela "NSWindow Frame com_apple_SwiftUI_Settings_window"`.
/// From inside the app, Reset All Settings, whose `removePersistentDomain` takes
/// this key with everything else: closing the resized window afterwards does NOT
/// write the frame back, and the next launch comes up at the ideals.
///
/// The MINIMA are a different contract and are not advisory: see the floor
/// note above, `SettingsWindowConfigurator.pinMinimumSize` and #124. The
/// visual redesign raised them well above the old ones, which is the one way a
/// saved frame does not have the last word: a frame saved by the smaller
/// window is under the new floor, so it is clamped back up to it on the next
/// launch rather than restored as saved.
enum SettingsWindowMetrics {
  static let minWidth: CGFloat = 1040
  /// First-launch width only. Read the note above before quoting it.
  static let idealWidth: CGFloat = 1100
  static let minHeight: CGFloat = 660
  /// First-launch height only. Read the note above before quoting it.
  static let idealHeight: CGFloat = 680

  static var minContentSize: NSSize { NSSize(width: minWidth, height: minHeight) }
}

/// The window chrome a `Settings` scene does not offer: the `.resizable` and
/// `.fullSizeContentView` style masks, the dark appearance, the transparent
/// titlebar, and dragging by the background.
///
/// No SwiftUI modifier restores resizability: `.windowResizability(.contentMinSize)`
/// on the scene plus an `.infinity` content frame both leave the zoom button
/// disabled and the window pinned — measured at a hard 900×512, immovable in
/// either direction.
///
/// This hangs off the view rather than off `SettingsOpener` deliberately.
/// ⌘, does NOT go through `SettingsOpener` — it is delivered straight to
/// SwiftUI's own menu item — so a fix installed on the open path only works
/// when the window is opened from the panel's gear. Attaching it to the view
/// makes it independent of how the window came to exist.
///
/// Also owns the window's NAME: set, but with `titleVisibility` hidden. The
/// window is titled for the Window menu and for accessibility, and the page
/// itself is what names the destination on screen. Drawing this title would
/// put a second name at the LEADING edge of a full-size-content window, over
/// the sidebar's own wordmark.
///
/// The dark appearance is pinned here as well as by `.preferredColorScheme`
/// (SV2), because the appearance decides the titlebar and the traffic lights,
/// which SwiftUI's colour scheme does not reach.
///
/// **The whole contract is re-asserted, never written once** (#124). Every
/// property below is one AppKit or SwiftUI can change back, and the previous
/// shape wrote them from a `DispatchQueue.main.async` hop off `updateNSView`:
/// a hop that found no window silently dropped the write with nothing to retry
/// it, so `window.title` could sit on the words of a destination the user had
/// long since left. That is a title that disagrees with the pane, which is only
/// invisible for as long as `titleVisibility` stays hidden.
private struct SettingsWindowConfigurator: NSViewRepresentable {
  let title: String
  /// A dependency that changes on push/pop so `updateNSView` fires then, which
  /// re-asserts the contract promptly rather than on the next window update
  /// pass. A push flips `titleVisibility` back to visible and draws the window
  /// title leading (measured, Task 9 spike).
  let navigationToken: Int

  func makeNSView(context: Context) -> NSView {
    let coordinator = context.coordinator
    coordinator.desiredTitle = title
    let view = WindowAttachedView()
    // The view has no window during `makeNSView`, and asking again after a
    // `DispatchQueue.main.async` hop was a guess: it answered nil whenever the
    // hop lost the race, and nothing retried. Being told is not a guess.
    view.onAttach = { [weak coordinator] window in coordinator?.apply(to: window) }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.desiredTitle = title
    if let window = view.window { coordinator.apply(to: window) }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  /// Reports the moment it actually has a window, so the contract is applied
  /// then rather than after a hop that may find none.
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
  /// `navigationToken` catches the flips that ride on a push or a pop, but
  /// measured cases flip `titleVisibility` with NO dependency of `updateNSView`
  /// changing: Back out of a pushed page whose selection had already moved, and
  /// the banner region appearing over the hub. Rather than enumerating flip
  /// sources one defect at a time, the enforcement rides
  /// `NSWindow.didUpdateNotification`, which AppKit posts on every window update
  /// pass. Every write below is guarded by a comparison, so an already-correct
  /// window is a few loads and no writes, and the notification cannot feed back
  /// on itself.
  ///
  /// The title is re-asserted alongside the visibility, not only the visibility.
  /// Re-hiding a title that says the wrong thing only hides the disagreement;
  /// the frame where AppKit wins the race then shows a window named for a pane
  /// that is not on screen.
  final class Coordinator {
    // Nonisolated storage so `deinit` can remove the observer (a `@MainActor`
    // property is unreachable from a nonisolated deinit under Swift 6).
    // `removeObserver` is thread-safe; both properties are only ever WRITTEN
    // from `apply(to:)`, which is main-actor.
    private var observer: NSObjectProtocol?
    private weak var observedWindow: NSWindow?
    private var title = ""

    /// Written by the representable on every update; re-applied to the window
    /// the moment it changes, so a dropped write cannot outlive one update.
    @MainActor var desiredTitle: String {
      get { title }
      set {
        guard title != newValue else { return }
        title = newValue
        if let observedWindow { apply(to: observedWindow) }
      }
    }

    /// The one way to hand the window into the `@Sendable` notification
    /// closure. `@unchecked Sendable` is justified by confinement: the box is
    /// only ever opened inside `MainActor.assumeIsolated`, on the `.main`
    /// queue, which is where NSWindow lives.
    private struct WeakWindowBox: @unchecked Sendable {
      weak var window: NSWindow?
    }

    /// The same trick for the coordinator itself, and the same justification:
    /// opened only inside `MainActor.assumeIsolated` on the `.main` queue, which
    /// is the only place this object is ever touched. Weak, so the observation
    /// cannot keep a torn-down coordinator alive.
    private struct WeakCoordinatorBox: @unchecked Sendable {
      weak var coordinator: Coordinator?
    }

    @MainActor func apply(to window: NSWindow) {
      observe(window)
      if !window.styleMask.contains(.resizable) {
        window.styleMask.insert(.resizable)
      }
      // The canvas runs to the top of the window, so the titlebar has to be
      // glass over it rather than a band of its own.
      if !window.styleMask.contains(.fullSizeContentView) {
        window.styleMask.insert(.fullSizeContentView)
      }
      if !window.titlebarAppearsTransparent {
        window.titlebarAppearsTransparent = true
      }
      // Dark-only (SV2): the appearance is what the titlebar and the traffic
      // lights read, and neither of them sees `.preferredColorScheme`.
      if window.appearance?.name != .darkAqua {
        window.appearance = NSAppearance(named: .darkAqua)
      }
      // With no titlebar band to grab, the canvas is the handle.
      if !window.isMovableByWindowBackground {
        window.isMovableByWindowBackground = true
      }
      // Named but not drawn: the page names the destination on screen, so
      // letting AppKit draw this one too would put a second name at the
      // leading edge. `title` still feeds the Window menu and accessibility.
      if window.titleVisibility != .hidden {
        window.titleVisibility = .hidden
      }
      // The window declares no toolbar content of its own any more, but a
      // pushed page still gets SwiftUI's Back item, and the default style
      // would put that in its own band BELOW the titlebar: a strip of dead
      // space across the top of both columns (measured at 24 pt when the
      // principal title lived there). `.unifiedCompact` merges the two rows.
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

    /// The floor SwiftUI declares, pinned where it can actually hold (#124).
    ///
    /// It RAISES `contentMinSize` and never lowers it: SwiftUI computes its own
    /// answer from the content, and clamping that down would be this type
    /// overruling a measurement it did not take. Idempotent either way, which is
    /// what lets it sit on a per-update-pass notification.
    @MainActor private func pinMinimumSize(on window: NSWindow) {
      let floor = SettingsWindowMetrics.minContentSize
      var minimum = window.contentMinSize
      minimum.width = max(minimum.width, floor.width)
      minimum.height = max(minimum.height, floor.height)
      if window.contentMinSize != minimum {
        window.contentMinSize = minimum
      }
    }

    /// Grows a window that is already under the floor back up to it.
    ///
    /// Raising `contentMinSize` does not move a window that is already smaller,
    /// and the reported state was a window well under it: the content was
    /// clipped rather than scrolled, so what was cut off could not be reached at
    /// all. AppKit clamps a live user resize itself, so this only ever fires for
    /// a size something else chose.
    ///
    /// Called from the update-pass notification and never from `updateNSView`:
    /// resizing a window from inside SwiftUI's own update is a re-entrant layout
    /// nobody needs, and the notification lands a moment later anyway.
    ///
    /// Capped at the screen, because a window taller than the display it is on
    /// is not an improvement on a clipped one.
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
        // didUpdateNotification for an NSWindow is posted on the main thread;
        // the assumeIsolated is the bridge from the nonisolated notification
        // closure to the AppKit calls below.
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
