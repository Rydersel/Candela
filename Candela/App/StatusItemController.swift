import AppKit
import CandelaKit
import os
import SwiftUI

/// AppKit escape hatch for the menu-bar panel (spec §9 risk item): the panel
/// is a custom-view NSMenuItem inside a real NSMenu on an NSStatusItem,
/// replacing MenuBarExtra's `.window` style.
///
/// Why: with "Automatically hide and show the menu bar" enabled, the bar only
/// stays revealed while a *menu tracking session* is active (or the pointer is
/// in the bar). MenuBarExtra `.window` presents a detached borderless window —
/// not a tracking session — so the bar slid away while the panel was open.
/// `presentationOptions` cannot override the system setting (Apple Forums
/// thread 761204), and NSPopover neither pins the bar nor positions correctly
/// when it is hidden. A real NSMenu is genuine menu tracking, so the bar stays
/// put exactly like every other NSMenu-based status item.
///
/// The SwiftUI panel is unchanged: `PanelView` renders inside an
/// `NSHostingView` used as the menu item's view, so state, gestures, and
/// accessibility all run through the same SwiftUI machinery as before.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate, NSMenuDelegate {
  // Software-dimming islands: constructed here (AppKit lives in the app
  // target) and injected into AppModel, which threads them into every
  // display's BrightnessController.
  private let shadeOverlay: ShadeOverlay
  private let gammaController: GammaController
  /// Watches for f.lux-style apps rewriting our gamma tables and offers the
  /// shade fallback. One monitor for all displays (the fork's counter is
  /// global too); wired into every controller's pre-gamma-apply hook.
  private let interferenceMonitor: GammaInterferenceMonitor
  /// Internal, not private: `CandelaApp` puts this in the Settings scene
  /// environment (Task 3), and every pane reads it from there.
  let model: AppModel
  /// The propagation seam's app-side fan-out (D20). Every settings pane writes
  /// a pref and then calls through here; the closures are wired at launch.
  let settingsActions: SettingsActions
  private var statusItem: NSStatusItem?
  /// KVO on the item's own visibility: `behavior = .removalAllowed` lets the
  /// user ⌘-drag the icon out of the menu bar, which must persist as
  /// `menuIcon = .hide` (D5). Held so the observation stays registered.
  private var statusItemVisibilityObserver: NSKeyValueObservation?
  /// D5 loop guard (fork `statusItemVisibilityChangedByUser`): brackets our own
  /// programmatic visibility writes so the KVO callback can tell them apart
  /// from a user drag. Without it: apply → observe → persist → apply, forever.
  private var isApplyingStatusItemVisibility = false

  override init() {
    let shade = ShadeOverlay()
    let gamma = GammaController()
    shadeOverlay = shade
    gammaController = gamma
    interferenceMonitor = GammaInterferenceMonitor(gamma: gamma, alerts: EngineAlerts())
    let model = AppModel(shade: shade, gamma: gamma)
    self.model = model
    settingsActions = SettingsActions(model: model)
    super.init()
  }
  // Media-key pipeline (tap → router → executor → controllers + HUD). Stored
  // as properties: the tap's thread and the executor must outlive launch.
  private var keyActionExecutor: KeyActionExecutor?
  private var mediaKeyTap: MediaKeyEventTap?
  /// Stored (review M23) so the topology loop can `cleanupDisplay` departed
  /// displays' HUD panels; the executor shares this same instance.
  private let hud = BrightnessHUD()
  /// Sleep/wake observation tokens (block-based observers stay registered
  /// only while retained). Never removed — fork parity, app-lifetime.
  private var sleepWakeObservers: [any NSObjectProtocol] = []
  /// Startup/wake DDC restore choreography (D5). `startupAction` is app-level
  /// but read through DisplayPrefs like every other engine pref.
  private let restoreCoordinator = RestoreCoordinator(
    startupAction: { DisplayPrefs(persistenceKey: "app").startupAction }
  )
  private let log = Logger(subsystem: "com.rydersel.Candela", category: "keys")

  func applicationDidFinishLaunching(_: Notification) {
    // Crash-while-dimmed protection (T5 contract): hand the gamma tables back
    // to the OS ONCE before any applyGammaScale — a previous run may have
    // died with a scaled table installed, and capturing that as the baseline
    // would bake the dimming in permanently.
    gammaController.resetAllGamma()

    // D5: the coordinator gates on startupAction internally, so every
    // launch/reconfigure/wake call site is unconditional.
    restoreCoordinator.restorePass = { [weak model] in model?.performRestorePass() }

    let hostingView = PanelHostingView(rootView: PanelRoot(model: model))
    hostingView.frame.size = hostingView.fittingSize

    let panelItem = NSMenuItem()
    panelItem.view = hostingView

    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.delegate = self
    menu.addItem(panelItem)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Candela")
    item.menu = menu
    // Fork parity: the icon can be ⌘-dragged off the bar, and we persist that.
    item.behavior = .removalAllowed
    statusItem = item

    // The panel's gear button lives inside this menu's tracking session and
    // must end it before a window can take focus (see SettingsOpener).
    SettingsOpener.statusMenu = menu

    // The handler MUST run synchronously — a `Task { @MainActor … }` hop would
    // land after `isApplyingStatusItemVisibility` was already reset, and every
    // programmatic hide would be misread as a user drag-removal. AppKit posts
    // this on the main thread, which is what assumeIsolated asserts.
    //
    // KNOWN TRAP: `assumeIsolated` *traps* rather than degrading if AppKit ever
    // delivers this off-main. It cannot be replaced by an async hop here — the
    // loop guard requires synchronous execution — so the constraint is
    // documented at the site and the crash surface is exercised interactively.
    statusItemVisibilityObserver = item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
      // The new value comes from `change`, never from the observed object:
      // the closure's `NSStatusItem` is task-isolated, and reading it inside
      // the main-actor region below is a "sending risks data races" error
      // under `SWIFT_STRICT_CONCURRENCY: complete`. `.new` is what makes
      // `newValue` non-nil, so it is load-bearing, not decoration.
      guard let isVisible = change.newValue else { return }
      MainActor.assumeIsolated {
        self?.statusItemVisibilityChanged(isVisible: isVisible)
      }
    }
    // Apply the mode immediately. With `.externalOnly` on a laptop the icon may
    // appear a beat later, once the warm refresh below discovers the external —
    // acceptable, and the correct trade: `.hide` must take effect at once.
    updateStatusItemVisibility()

    // Reconfiguration intake: synchronous registration on the main thread is
    // load-bearing — CG delivers the callback on the registering thread's
    // run loop, and only the main thread has one that lives forever.
    model.displayManager.activate()

    // Sleep/wake stay app-side (NSWorkspace is AppKit) and forward to the
    // engine's epoch intake. Both notification pairs, like the fork: a
    // display sleep and a system sleep must each gate DDC writes.
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    let displayManager = model.displayManager
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
      sleepWakeObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
        displayManager.noteSleep() // nonisolated + synchronous: safe from any queue
      })
    }
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
      sleepWakeObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
        displayManager.noteWake()
        // The observer closure runs off-main; the coordinator is MainActor.
        Task { @MainActor in self?.restoreCoordinator.noteWake() }
      })
    }

    // Re-arm volume keys when the default output device changes (D4). The
    // handler fires on the CoreAudio listener queue; hop to main for the tap.
    model.audioDevices.setOnDefaultOutputChange { [weak self] in
      Task { @MainActor in self?.refreshTapConfig() }
    }

    settingsActions.rearmTap = { [weak self] in self?.refreshTapConfig() }
    settingsActions.recheckPermissions = { [weak self] in self?.model.accessibility.promptIfNeeded() }
    settingsActions.updateStatusItem = { [weak self] in self?.updateStatusItemVisibility() }

    // Topology consumption loop — the stream's single consumer: after each
    // debounced reconfiguration (or post-wake sober), re-discover displays,
    // re-arm the media-key tap, and drop departed displays' HUD panels.
    Task { [weak self] in
      guard let stream = self?.model.displayManager.topologyChanges else { return }
      for await _ in stream {
        guard let self else { return }
        let departed = await self.model.refresh()
        self.refreshTapConfig()
        self.updateStatusItemVisibility()
        // D5: a reconfigure pass restores once (the wake repeat chain, when
        // one is running, keeps re-asserting on its own schedule).
        self.restoreCoordinator.noteLaunchOrReconfigure()
        self.wireInterferenceHooks()
        // Fork parity: the counter zeroes on every configure so unrelated
        // events across a long session never add up to an offer.
        // `suspendedForSession` survives.
        self.interferenceMonitor.resetCounter()
        for id in departed {
          self.hud.cleanupDisplay(id)
        }
        // HDR state may have changed under the 2 s cache (mode switches
        // themselves trigger reconfiguration) — drop it BEFORE the
        // per-display re-evaluation so fresh state is read.
        await self.model.hdrToggling.displaysReconfigured()
        // Gamma reset once per event, before any recapture (T5 ordering:
        // reset → recapture → re-apply; recapture must see an OS-owned
        // table). Done here rather than per display so a later display's
        // reset cannot wipe an earlier display's just-reapplied dim.
        self.gammaController.resetAllGamma()
        for state in self.model.displays {
          await state.controller.noteHDRStateMayHaveChanged()
          await state.controller.handleReconfigure()
        }
      }
    }

    // Media keys: the tap delivers on its own thread; hop to the main actor,
    // route (pure, cheap), execute. Strong captures are fine — executor and
    // tap both live for the app's lifetime.
    let executor = KeyActionExecutor(model: model, hud: hud)
    keyActionExecutor = executor
    let tap = MediaKeyEventTap { press in
      Task { @MainActor in
        // Constructed INSIDE the press closure on purpose: the live read per
        // press is what closes fork bug 3, and is why the fine-scale prefs
        // correctly carry no `.rearmTap` row in the propagation table.
        let prefs = DisplayPrefs(persistenceKey: "app")
        let config = KeyRouterConfig(
          useFineScaleBrightness: prefs.useFineScaleBrightness,
          useFineScaleVolume: prefs.useFineScaleVolume
        )
        // isFresh separates a fresh press from key-repeat for the engine.
        executor.execute(KeyRouter.route(press, config: config), isFresh: !press.isRepeat)
      }
    }
    mediaKeyTap = tap

    let permission = model.accessibility
    permission.promptIfNeeded()
    if permission.isGranted {
      startMediaKeyTap()
    } else {
      permission.startPolling { [weak self] in
        self?.startMediaKeyTap()
      }
    }

    // Warm the display list before the first open. Menu tracking can hold the
    // main run loop in event-tracking mode, which starves main-actor task
    // execution (see BrightnessController.setBrightness), so a refresh cannot
    // be relied on to land while the menu is open. Launch here, menu close
    // below, and the topology loop above are therefore the only refresh
    // triggers; AppModel.refresh() coalesces overlapping calls, so they
    // never race the DDC bus.
    Task {
      await model.refresh()
      refreshTapConfig()
      updateStatusItemVisibility()
      wireInterferenceHooks()
      restoreCoordinator.noteLaunchOrReconfigure()
    }
  }

  /// Review M24 + D5: remove software dimming, then hand the DDC register the
  /// full-range equivalent of the published brightness so the monitor is not
  /// left at a combined-mode DDC floor.
  func applicationWillTerminate(_: Notification) {
    gammaController.resetAllGamma()
    shadeOverlay.removeAllShades()
    for state in model.displays {
      // Quitting while DisplayManager is suspended (mid-reconfigure or
      // asleep) silently drops this at the epoch gate — acceptable:
      // best-effort is the D5 contract (concurrency flag-8 note).
      state.controller.restoreFullRangeDDC()
    }
    // Best-effort barrier (planner flag 8, endorsed): the coalescer drains on
    // the global executor, so a short main-thread nap gives the ~20 ms/display
    // DDC transactions time to land before exit. Awaiting the main-actor
    // waiters here would deadlock (terminate is synchronous on main).
    // `.terminateLater` + async drain is the recorded M5 cleanup.
    if !model.displays.isEmpty {
      Thread.sleep(forTimeInterval: 0.25)
    }
  }

  /// Dock-less reopen (double-clicking the app in Finder, `open -a`): with no
  /// window to restore there is nothing for AppKit to do, so route it to
  /// Settings — never to onboarding, which is a first-run flow.
  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
    SettingsOpener.open()
    return false
  }

  func menuDidClose(_: NSMenu) {
    // Re-discover displays and re-read hardware once tracking has ended and
    // the run loop is back in default mode, so the next open starts fresh.
    Task {
      await model.refresh()
      refreshTapConfig()
      updateStatusItemVisibility()
      wireInterferenceHooks()
    }
  }

  /// Hands every display's controller a pre-gamma-apply hook that runs the
  /// interference check for that display. Idempotent — re-run after each
  /// refresh so displays that just appeared get one (and so a hook never
  /// outlives the display it names).
  private func wireInterferenceHooks() {
    for state in model.displays {
      let displayID = state.id
      let displayName = state.display.name
      let persistenceKey = state.display.persistenceKey
      let monitor = interferenceMonitor
      let gamma = gammaController
      state.controller.preGammaApplyHook = { [weak controller = state.controller] in
        monitor.checkBeforeApply(displayID: displayID, displayName: displayName) {
          // Accept: this display stops using gamma for good...
          DisplayPrefs(persistenceKey: persistenceKey).avoidGamma = true
          // ...hand its table back (per-display; `resetAllGamma` would drop
          // every other display's dimming too)...
          gamma.applyGammaScale(1.0, on: displayID)
          // ...and re-apply the current brightness through the shade backend.
          // `handleReconfigure` is the public door for that: it clears the
          // software dedupe memo (which `setBrightness` alone would trip over,
          // the value being unchanged) and re-runs the software leg, now
          // routed to the shade. Async, so this returns to the alert at once.
          // `recapture: false` — the interfering app may own the table right
          // now, so a baseline capture here would bake its curve in as the
          // "default"; the next real reconfiguration recaptures.
          Task { @MainActor in await controller?.handleReconfigure(recapture: false) }
        }
      }
    }
  }

  private func startMediaKeyTap() {
    guard let mediaKeyTap else { return }
    do {
      try mediaKeyTap.start(config: model.tapConfig)
    } catch {
      log.error("media-key tap failed to start: \(error) — keys disabled until relaunch")
    }
  }

  /// Re-arms/disarms brightness keys after display topology changes — the M2
  /// slice of the fork's updateMediaKeyTap. No-op unless the tap is running.
  private func refreshTapConfig() {
    guard let mediaKeyTap, mediaKeyTap.isRunning else { return }
    mediaKeyTap.update(config: model.tapConfig)
  }

  /// Applies the `menuIcon` mode to the status item (D5). Called at launch,
  /// after every display refresh, and from the settings seam's
  /// `.updateStatusItem` effect — which fires for `menuIcon`, `hideDisplay`
  /// AND `hideBuiltInDisplay`, because the last two decide `hasVisibleSlider`.
  private func updateStatusItemVisibility() {
    guard let statusItem else { return }
    let visible = MenuIconPolicy.isStatusItemVisible(
      mode: DisplayPrefs(persistenceKey: "app").menuIcon,
      hasExternalDisplay: !model.displays.isEmpty,
      // Exactly the panel's own question — same statics, so the icon and the
      // panel can never disagree about whether a slider exists.
      hasVisibleSlider: !PanelView.visibleDisplays(model).isEmpty || PanelView.showsBuiltIn(model)
    )
    guard statusItem.isVisible != visible else { return }
    isApplyingStatusItemVisibility = true
    statusItem.isVisible = visible
    isApplyingStatusItemVisibility = false
  }

  /// KVO sink for `NSStatusItem.isVisible` — i.e. the user dragged the icon
  /// out of the menu bar (or we just hid it ourselves).
  private func statusItemVisibilityChanged(isVisible: Bool) {
    let prefs = DisplayPrefs(persistenceKey: "app")
    guard let mode = MenuIconPolicy.modeAfterVisibilityChange(
      isVisible: isVisible,
      changedByUser: !isApplyingStatusItemVisibility,
      current: prefs.menuIcon
    ) else { return }
    prefs.menuIcon = mode
    // Deliberately NOT `settingsActions.prefDidChange(.menuIcon)`: that row
    // also fires `.updateStatusItem`, which would re-apply visibility on top of
    // the drag the user just performed. Only the re-render is wanted, so the
    // App menu pane's popup (T11) flips to "Never" on its own.
    model.notePrefsChanged()
  }
}

/// Concrete root view so NSHostingView can be subclassed without AnyView.
private struct PanelRoot: View {
  let model: AppModel

  var body: some View {
    PanelView()
      .environment(model)
  }
}

/// Hosting view that keeps its frame matched to SwiftUI's ideal size. Menu
/// item views are frame-based (no Auto Layout parent), so when the panel's
/// content changes (display list refresh), the frame must follow the new
/// fitting size for the menu to lay out correctly.
private final class PanelHostingView: NSHostingView<PanelRoot> {
  required init(rootView: PanelRoot) {
    super.init(rootView: rootView)
  }

  @available(*, unavailable)
  @objc dynamic required init?(coder _: NSCoder) {
    fatalError("PanelHostingView does not support NSCoder")
  }

  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    let target = fittingSize
    if frame.size != target {
      setFrameSize(target)
    }
  }
}
