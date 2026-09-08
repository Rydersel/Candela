import AppKit
// @preconcurrency: same mutable-C-global import quirk as AccessibilityPermission.
@preconcurrency import ApplicationServices
import CandelaKit
import Observation
import os
import ServiceManagement
import SwiftUI

/// AppKit escape hatch for the menu-bar panel: a custom-view NSMenuItem inside
/// a real NSMenu on an NSStatusItem, replacing MenuBarExtra's `.window` style.
///
/// With "Automatically hide and show the menu bar" on, the bar stays revealed
/// only while a menu tracking session is active. MenuBarExtra `.window` presents
/// a detached borderless window, not a tracking session, so the bar slid away
/// while the panel was open. `presentationOptions` cannot override the system
/// setting (Apple Forums thread 761204), and NSPopover neither pins the bar nor
/// positions correctly when it is hidden. A real NSMenu is genuine menu
/// tracking.
///
/// `PanelView` still renders inside an `NSHostingView` used as the menu item's
/// view, so state, gestures and accessibility run through SwiftUI as before.
@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate, NSMenuDelegate {
  // Software-dimming islands: built here because AppKit lives in the app target,
  // then injected into AppModel and on into every BrightnessController.
  private let shadeOverlay: ShadeOverlay
  private let gammaController: GammaController
  /// Watches for f.lux-style apps rewriting our gamma tables and offers the
  /// shade fallback. One monitor for all displays, wired into every controller's
  /// pre-gamma-apply hook.
  private let interferenceMonitor: GammaInterferenceMonitor
  /// Internal, not private: `CandelaApp` puts this in the Settings scene
  /// environment, and every pane reads it from there.
  let model: AppModel
  /// The propagation seam's app-side fan-out. Every settings pane writes
  /// a pref and then calls through here; the closures are wired at launch.
  let settingsActions: SettingsActions
  /// The one Sparkle updater. Built here so it starts with the app and outlives
  /// any settings window; `CandelaApp` puts it in the Settings scene environment.
  let updaterModel = UpdaterModel()
  private var statusItem: NSStatusItem?
  /// KVO on the item's own visibility: `behavior = .removalAllowed` lets the
  /// user ⌘-drag the icon out of the menu bar, which must persist as
  /// `menuIcon = .hide`. Held so the observation stays registered.
  private var statusItemVisibilityObserver: NSKeyValueObservation?
  /// Loop guard (fork `statusItemVisibilityChangedByUser`): brackets our own
  /// programmatic visibility writes so the KVO callback can tell them apart
  /// from a user drag. Without it: apply → observe → persist → apply, forever.
  private var isApplyingStatusItemVisibility = false
  /// Safe mode: Shift held at launch. Polled once in `init` and never re-read, so the
  /// mode cannot change mid-session.
  let isSafeMode: Bool

  override init() {
    let safeMode = NSEvent.modifierFlags.contains(.shift)
    isSafeMode = safeMode
    let shade = ShadeOverlay()
    let gamma = GammaController()
    shadeOverlay = shade
    gammaController = gamma
    // Bound to a local as well as the property: `self`'s stored properties
    // cannot be read before `super.init()`, and the handoff below needs the same
    // instance.
    let monitor = GammaInterferenceMonitor(gamma: gamma, alerts: EngineAlerts())
    interferenceMonitor = monitor
    let model = AppModel(shade: shade, gamma: gamma, safeMode: safeMode)
    self.model = model
    // Reporting-only handoff: built here because it needs the AppKit alert
    // island, read there because the diagnostics pane has no other way to say how
    // often another app took a display's color profile back.
    model.gammaInterference = monitor
    settingsActions = SettingsActions(model: model)
    // The coordinator gates on `startupAction` internally, so reading it
    // through a safe-mode prefs object disables startup AND wake restore for
    // the session with no further call-site changes.
    restoreCoordinator = RestoreCoordinator(
      startupAction: { DisplayPrefs(persistenceKey: "app", safeMode: safeMode).startupAction }
    )
    super.init()
  }
  // Media-key pipeline (tap, router, executor, controllers and HUD). Stored as
  // properties: the tap's thread and the executor must outlive launch.
  private var keyActionExecutor: KeyActionExecutor?
  private var mediaKeyTap: MediaKeyEventTap?
  /// Custom-shortcut dispatch. Held for the app's lifetime: the handlers it
  /// registers capture it weakly, so dropping it kills every custom shortcut.
  private var shortcutManager: ShortcutManager?
  /// Held for the app's lifetime so "Run Setup Again…" and the post-reset
  /// re-run reuse one window instead of stacking copies.
  private var onboardingController: OnboardingWindowController?
  /// Answers a resolution preview started from the panel. Held here because the
  /// coordinator references it weakly, and the countdown must outlive the menu
  /// tracking session that started it.
  private var modeConfirmation: ModeConfirmationWindow?
  /// Answers a mirror preview, and reports a mirror change that was refused,
  /// failed, or only partly happened. Held like the mode window above, and
  /// because the hotkey has no other surface at all.
  private var mirrorConfirmation: MirrorConfirmationWindow?
  private var rotationConfirmation: RotationConfirmationWindow?
  /// Answers an arrangement preview. Held for the same reason as the three
  /// above: the coordinator references it weakly and the countdown outlives
  /// whatever started the change.
  private var arrangementConfirmation: ArrangementConfirmationWindow?
  /// Display Health windows: held like the confirmation windows above,
  /// app-lifetime, one window per display key inside.
  private lazy var displayHealthPresenter = DisplayHealthWindowPresenter(model: model)
  /// The checkup window: built on first use, app-lifetime, like the presenter above.
  private var checkupWindow: CheckupWindowController?
  /// Stored so the departure hook can `cleanupDisplay` departed displays' HUD
  /// panels; the executor shares this instance.
  private let hud = BrightnessHUD()
  #if DEBUG
    /// Keeps the `CANDELA_DEBUG_HUD_DEMO` re-show loop alive; see
    /// `startHUDDemoIfRequested()`.
    private var hudDemoTimer: Timer?
  #endif
  /// Sleep/wake observation tokens: block-based observers stay registered only
  /// while retained. Never removed, app-lifetime.
  private var sleepWakeObservers: [any NSObjectProtocol] = []
  /// Startup/wake DDC restore choreography. `startupAction` is app-level
  /// but read through DisplayPrefs like every other engine pref, and under safe
  /// mode through a prefs object whose getter reports `.doNothing`, which
  /// is what disables both restores. Assigned in `init` because it needs that
  /// flag.
  private let restoreCoordinator: RestoreCoordinator
  /// The two unattended restore passes, chained (see `restoreUnattended()`). A
  /// property rather than a local so two topology events cannot interleave their
  /// halves: the second call's passes wait on the first call's.
  private let unattendedRestores = UnattendedRestoreSequence()
  /// The only writer to `model.mirrorTopology`. Held for the app's lifetime: it
  /// owns a block-based notification registration, and dropping it freezes the
  /// store at the launch sample with nothing saying so.
  private lazy var mirrorSampler = MirrorTopologySampler(store: model.mirrorTopology)
  private let log = Logger(subsystem: "com.rydersel.Candela", category: "keys")
  private let checkupLog = Logger(subsystem: "com.rydersel.Candela", category: "checkup")

  func applicationDidFinishLaunching(_: Notification) {
    // The notice states exactly what safe mode does and does not do. The
    // fork's copy ("Default settings are reloaded, DDC read is blocked") is wrong
    // twice: nothing is reloaded, and it blocks the startup write too. Someone
    // reaching for safe mode because a DDC write is wedging their monitor must
    // not be told the traffic stopped when it has not. Sliders and keys stay live
    // on purpose: gating them would kill every panel control and disable the only
    // unmute affordance a hardware-muted display has.
    if isSafeMode {
      let alert = NSAlert()
      alert.messageText = "Safe Mode"
      // The words live in `SafeModeCopy` with the Diagnostics row and the
      // General pane caption: this notice once listed fewer suppressions than the
      // app performed. One enum now, so a new suppression cannot reach only one
      // surface.
      var informative = SafeModeCopy.launchNotice(app: AppInfo.productName)
      // Appended rather than folded into the list: this one is conditional on a
      // pref, and it is additional to the suppressions rather than one of them.
      if DisplayPrefs(persistenceKey: "app").enableBrightnessSync {
        informative += "\n\n" + SafeModeCopy.brightnessSyncParagraph
      }
      alert.informativeText = informative
      // Accessory-policy app: without activating first, a launch-time alert can
      // come up behind whatever was frontmost. `NSApp.activate()` is enough here;
      // the SettingsOpener caveat applies only inside a menu tracking session,
      // and there is none at launch.
      NSApp.activate()
      alert.runModal()
    }

    // Crash-while-dimmed protection: hand the gamma tables back to
    // the OS ONCE before any applyGammaScale. A previous run may have died with a
    // scaled table installed, and capturing that as the baseline would bake the
    // dimming in permanently.
    gammaController.resetAllGamma()

    // The coordinator gates on startupAction internally, so every
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
    item.menu = menu
    // Fork parity: the icon can be ⌘-dragged off the bar, and we persist that.
    item.behavior = .removalAllowed
    statusItem = item
    updateStatusItemImage()
    trackKeepAwake()

    // Panel controls that have to end this tracking session reach it through
    // here: the gear button (a window cannot take focus while it runs) and
    // resolution selection (main-actor work queued from inside it is starved
    // until it ends). See `PanelMenu`.
    PanelMenu.menu = menu

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
    // appear a beat later, once the warm refresh discovers the external. That is
    // the right trade: `.hide` must take effect at once.
    updateStatusItemVisibility()

    // The mirror topology's only writer, started BEFORE the first discovery
    // pass: every drawable-ID resolution reads `model.mirrorTopology`, and an
    // unstarted sampler leaves it holding the empty topology, whose resolution is
    // the identity function. Launching into an already-engaged mirror set is an
    // ordinary way to start.
    mirrorSampler.start()

    // Reconfiguration intake: synchronous registration on the main thread is
    // load-bearing, since CG delivers the callback on the registering thread's
    // run loop and only the main thread has one that lives forever.
    model.displayManager.activate()

    // Starts the OLED care driver loop (Safe Mode still builds the chrome
    // controller) and wires its lock and sleep/wake observers. Display membership
    // is resolved by the warm task and the topology loop via
    // `displaysReconfigured()`.
    model.oledCare.start(model: model)

    // Sleep/wake stay app-side (NSWorkspace is AppKit) and forward to the
    // engine's epoch intake. Both notification pairs: a display sleep and a
    // system sleep must each gate DDC writes.
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
        Task { @MainActor in
          self?.restoreCoordinator.noteWake()
          // A wire that stopped answering before the Mac slept is asked
          // again rather than staying demoted across a link the sleep rebuilt.
          self?.model.noteWakeForBrightnessWires()
        }
      })
    }

    // Re-arm volume keys when the default output device changes. The
    // handler fires on the CoreAudio listener queue; hop to main for the tap.
    model.audioDevices.setOnDefaultOutputChange { [weak self] in
      Task { @MainActor in self?.refreshTapConfig() }
    }

    // Re-arm when a capabilities probe lands. The watched set is gated on
    // the display's own verdict for the volume and mute registers, and that
    // verdict arrives asynchronously after the display does, so the first arm
    // after a plug is always made from the pre-probe answer.
    model.onVolumeKeyRoutingChanged = { [weak self] in
      self?.refreshTapConfig()
      #if DEBUG
        // Third dump trigger, beside launch and reconfigure: the capability
        // verdict resolves after the launch dump, so without this the greyed
        // slider is invisible until a reconfigure comes along.
        if let self { DebugPanelDump.dumpIfRequested(self.model) }
      #endif
    }

    settingsActions.rearmTap = { [weak self] in
      self?.refreshTapConfig()
      // A Carbon hotkey registration is exclusive and system-wide, so an
      // assigned shortcut whose mode is off silently steals its combination from
      // every other app. Registration follows the modes, and the settings reset
      // wipes those modes. In `.rearmTap` rather than the reset body so it covers
      // every mode write through the seam. Static because the manager instance is
      // private here and the KeyboardShortcuts registry is global.
      ShortcutManager.syncRegistration()
    }
    settingsActions.recheckPermissions = { [weak self] in
      // The fork computes this and never calls it, so changing a
      // keyboard mode never re-prompts. Candela prompts, but only when the mode
      // change actually made the CGEvent tap wanted. Custom shortcuts are Carbon
      // hotkeys and need no grant, so an all-custom rig must not be shown a TCC
      // prompt it can only refuse.
      let prefs = DisplayPrefs(persistenceKey: "app")
      guard KeyModePolicy.requiresAccessibility(
        brightness: prefs.keyboardBrightness, volume: prefs.keyboardVolume
      ) else { return }
      self?.model.accessibility.promptIfNeeded()
    }
    settingsActions.updateStatusItem = { [weak self] in self?.updateStatusItemVisibility() }
    settingsActions.performReset = { [weak self] in self?.performSettingsReset() }

    // The panel's own naming rule, so a renamed display reads the same in the row
    // that started a change, the window that confirms it, and the arrangement
    // canvas. Falls back to "" for a display `DisplayDiscovery` never saw (it
    // filters on a non-nil `IOAVService`), and each surface substitutes the
    // topology's own name there.
    let displayName: (CGDirectDisplayID) -> String = { [weak self] displayID in
      guard let state = self?.model.allControlledStates.first(where: { $0.id == displayID })
      else { return "" }
      return PanelView.title(for: state.display)
    }
    // Resolved through the store on each use, never captured as a value: a
    // window outlives any single topology, and a mirror can engage while it is
    // up, which for a MIRROR preview is the thing being previewed.
    let drawableDisplayID: (CGDirectDisplayID) -> CGDirectDisplayID = { [weak self] displayID in
      self?.model.mirrorTopology.drawableDisplayID(for: displayID) ?? displayID
    }

    // Resolution previews started from the panel are answered in a window of
    // their own: the panel is a menu tracking session and cannot be relied on
    // to still exist half a minute later. See `ModeConfirmationWindow`.
    let confirmation = ModeConfirmationWindow(coordinator: model.displayModes)
    confirmation.displayName = displayName
    confirmation.drawableDisplayID = drawableDisplayID
    modeConfirmation = confirmation
    model.displayModes.confirmation = confirmation
    // The coordinator writes `storedDisplayMode` when the user pins one and
    // when a kept change updates it, and the seam has to hear about it whichever
    // surface asked. Wired once here rather than per surface: the panel's window
    // has no `SettingsActions`, and a second copy is a second thing to forget.
    model.displayModes.didStoreMode = { [weak self] displayID in
      guard let self,
            let key = model.allControlledStates
            .first(where: { $0.id == displayID })?.display.persistenceKey
      else { return }
      self.settingsActions.prefDidChange(.storedDisplayMode, persistenceKey: key)
    }
    // The same rule for the two synthesis prefs, which the coordinator writes
    // rather than a pane: the opt-in is settable from the hub and from a reset,
    // and the stored size is written by the picker and by an unattended reapply.
    // The persistence key comes with the call because the coordinator already
    // resolved it to write the pref.
    model.synthesis.didWriteSynthesisPref = { [weak self] name, key in
      self?.settingsActions.prefDidChange(name, persistenceKey: key)
    }
    // A failed resolution restore joins the diagnostics event ring. Wired here
    // because a reapply runs unattended at reconnect, with no view to notice it.
    model.displayModes.didReportReapply = { [weak self] displayID, notice in
      guard let self else { return }
      let name = self.model.allControlledStates
        .first { $0.id == displayID }?.display.name ?? "a display"
      self.model.noteDisplayEvent("\(name): \(DiagnosticsCopy.reapplyEvent(notice))")
    }

    // Mirroring's own surface. Same argument as the resolution window, plus one
    // of its own: a mirror change can start from a HOTKEY, with no panel and no
    // settings window, so without this a refusal or failed apply is silent.
    let mirrorConfirmation = MirrorConfirmationWindow(coordinator: model.mirroring)
    mirrorConfirmation.drawableDisplayID = drawableDisplayID
    self.mirrorConfirmation = mirrorConfirmation
    model.mirroring.confirmation = mirrorConfirmation
    model.mirroring.displayName = displayName
    // Rotation's own surface. There is no rotation hotkey, but the settings
    // window is often on a DIFFERENT display from the one that just rotated,
    // which is the "answered blind" case the window exists to prevent.
    let rotationConfirmation = RotationConfirmationWindow(coordinator: model.rotation)
    rotationConfirmation.drawableDisplayID = drawableDisplayID
    rotationConfirmation.displayName = displayName
    self.rotationConfirmation = rotationConfirmation
    model.rotation.confirmation = rotationConfirmation

    // Arrangement's own surface: another CALLER of `ConfirmationPanel`, not
    // another window type, which is how one of the others once shipped with an
    // invisible primary button. It has the strongest case for being a window: an
    // arrangement change can move the menu bar onto a different display, so the
    // surface asking about it must go where the menu bar ended up.
    let arrangementConfirmation = ArrangementConfirmationWindow(coordinator: model.arrangement)
    arrangementConfirmation.drawableDisplayID = drawableDisplayID
    // While a synthesized size stands, this window is talking about the
    // virtual display holding the desktop while the reader is looking at their
    // monitor, so it names the panel the pair stands in for. An empty answer is
    // handled: `ArrangementCopy` falls back to an unnamed sentence.
    arrangementConfirmation.displayName = { [weak self] displayID in
      guard let self else { return "" }
      let pairing = model.synthesis.pairings.first { $0.virtualDisplayID == displayID }
      return displayName(pairing?.physicalDisplayID ?? displayID)
    }
    self.arrangementConfirmation = arrangementConfirmation
    model.arrangement.confirmation = arrangementConfirmation
    // The canvas names its tiles through the coordinator, so the map and the
    // confirmation window call a display by the same name.
    model.arrangement.displayName = displayName
    // What the coordinator keys a saved layout, its lookup and the arrival
    // gate on: a synthesized size puts the desktop on a virtual display and makes
    // the panel its mirror slave, so without the pairing the topology signature
    // moves the moment a size engages and orphans the saved layout. Read live and
    // held nowhere, since display IDs are reassigned across a replug.
    model.arrangement.synthesisPairings = { [weak self] in self?.model.synthesis.pairings ?? [] }
    // The same wiring `didStoreMode` gets: the coordinator writes
    // `savedArrangements` when a layout is kept and the seam has to hear about it.
    // No persistence key, since the layout is a fact about the display SET.
    model.arrangement.didSaveArrangement = { [weak self] in
      self?.settingsActions.prefDidChange(.savedArrangements)
    }

    // The orphaned-shade fix (see `MirroringCoordinator.rebuildSoftwareDimming`).
    // Wired here because it needs an AppKit island and the display list. The
    // reapply-after-pref-change rule decides WHICH door:
    // `reapplyAfterPrefChange()`, never `handleReconfigure(recapture:)`, which
    // re-runs only the software leg and no-ops in pure-DDC mode, and never
    // `setBrightness(sameValue)`, which is memo-suppressed.
    model.mirroring.rebuildSoftwareDimming = { [weak self] in
      guard let self else { return }
      self.shadeOverlay.removeAllShades()
      for state in self.model.displays {
        state.controller.reapplyAfterPrefChange()
      }
    }

    // Wired here rather than read off `refresh()`'s return value, which a joiner
    // never sees. `checkupWindow` is read at call time: it is built on first use.
    model.onDisplaysDeparted = { [weak self] departed in
      guard let self else { return }
      for id in departed {
        self.hud.cleanupDisplay(id)
        // The target leaving ends the run as incomplete, naming the leg
        // it was in. A no-op for any other display, and when no run is going.
        self.checkupWindow?.displayDisconnected(id)
      }
    }

    // Topology consumption loop, the stream's single consumer: after each
    // debounced reconfiguration, re-discover displays and re-arm the media-key
    // tap.
    Task { [weak self] in
      guard let stream = self?.model.displayManager.topologyChanges else { return }
      for await _ in stream {
        guard let self else { return }
        // Backstop, and first: the screen-parameters observer is the primary
        // trigger, but everything below this line may resolve a drawable ID and
        // none of it should read a topology older than this event.
        self.mirrorSampler.refresh()
        // Cheap (one `displays()` call), and every drawable-ID resolution reads
        // it. The coordinator observes the raw screen-parameters notification
        // itself, so this is a backstop like the line above, not the trigger.
        self.model.mirroring.refreshTopology()
        // Return value ignored: this loop often JOINS a pass a menu close started,
        // and a joiner gets an empty list. Cleanup rides `onDisplaysDeparted`.
        await self.model.refresh()
        self.refreshTapConfig()
        self.updateStatusItemVisibility()
        // OLED care: display IDs can be REASSIGNED with every display still
        // present (measured: two panels swapped IDs across one dock cycle), so the
        // coordinator tears its overlays down and re-renders from state under
        // freshly resolved IDs, never a repin. After `refresh()` so it reconciles
        // against the post-event display list.
        self.model.oledCare.displaysReconfigured()
        // A reconfigure pass restores once (the wake repeat chain, when
        // one is running, keeps re-asserting on its own schedule).
        self.restoreCoordinator.noteLaunchOrReconfigure()
        self.wireInterferenceHooks()
        self.warmModeCatalogs()
        self.restoreUnattended()
        // Setup re-derives its pages from the post-event display list. Inside
        // this loop because the stream has ONE consumer; a second `for await`
        // would split the events between them. After `refresh()` and the
        // catalog warm so the harvest reads the new topology.
        self.onboardingController?.displayTopologyChanged()
        // The counter zeroes on every configure so unrelated events across a long
        // session never add up to an offer. `suspendedForSession` survives.
        self.interferenceMonitor.resetCounter()
        // HDR state may have changed under the 2 s cache, since a mode switch is
        // itself a reconfiguration. Dropped BEFORE the per-display re-evaluation
        // so fresh state is read.
        await self.model.hdrToggling.displaysReconfigured()
        // Gamma reset once per event, before any recapture (reset →
        // recapture → re-apply; recapture must see an OS-owned table). Done
        // here rather than per display so a later display's
        // reset cannot wipe an earlier display's just-reapplied dim.
        self.gammaController.resetAllGamma()
        // Shades reset the same way, for a reason the gamma line does not have: a
        // shade is keyed by the DRAWABLE id, so a topology change MOVES ITS KEY.
        //
        // A mirror ENGAGING is the direction that strands one. A display dimming
        // under its own key becomes a slave, its controller resolves to the master
        // from that instant, the key is never named again, and `repinFrames()`
        // skips it (a slave has no `NSScreen`). What is left is a full-screen
        // black window at `CGShieldingWindowLevel()` holding its last dim alpha
        // over a display with no desktop, with no way out short of quitting.
        //
        // A mirror BREAKING strands nothing: the ex-master re-names its own key
        // and the ex-slave gets a fresh shade. Stated so nobody narrows this call
        // to that path; removing wholesale covers both, so it is unconditional.
        //
        // `MirroringCoordinator` performs the same teardown from the RAW
        // screen-parameters notification, earlier than this debounced stream, so
        // this is the backstop for a change that posts no notification.
        //
        // Safe wholesale because the loop below re-establishes it:
        // `handleReconfigure` nils the software dedupe memo and re-runs the
        // software leg, recreating the shade under the NEW drawable id. Displays
        // with no shade (native path, pure DDC, the built-in slot) are
        // unaffected.
        self.shadeOverlay.removeAllShades()
        for state in self.model.displays {
          await state.controller.noteHDRStateMayHaveChanged()
          await state.controller.handleReconfigure()
        }
        #if DEBUG
          // Panel row model, last in the pass: the HDR state above and the
          // re-applied dimming are what a dump taken here can report.
          DebugPanelDump.dumpIfRequested(self.model)
        #endif
      }
    }

    // Media keys: the tap delivers on its own thread, so hop to the main actor,
    // route, execute. Strong captures are fine; executor and tap both live for
    // the app's lifetime.
    let executor = KeyActionExecutor(model: model, hud: hud)
    keyActionExecutor = executor
    shortcutManager = ShortcutManager(model: model, executor: executor)
    let tap = MediaKeyEventTap { press in
      Task { @MainActor in
        // Built INSIDE the press closure on purpose: the live read per press is
        // what closes fork bug 3, and is why the fine-scale prefs carry no
        // `.rearmTap` row in the propagation table.
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

    // After an emergency teardown (a revocation seen by the AX poll, or a
    // WindowServer wedge broken by the deadman switch), wait out the settle
    // window, then either rebuild the tap (a false alarm, say a slow display
    // reconfigure tripping the probe) or record the disarm so diagnostics reads
    // "not running". The delay matters: right after a wedge breaks, a pending TCC
    // delete commits within moments, and rebuilding at once could recreate the
    // tap the revocation was trying to kill.
    tap.onEmergencyTeardown = { [weak self] in
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        guard let self else { return }
        if AXIsProcessTrustedWithOptions(nil) {
          self.startMediaKeyTap()
        } else {
          self.model.noteTapDisarmed()
        }
      }
    }

    let permission = model.accessibility
    // On a first run the Setup window owns the Accessibility ask so it can
    // explain WHY first. Prompting here would fire the system dialog before that
    // window is on screen. `prefsSchemaVersion` is the trigger and is written at
    // Setup completion, so an interrupted first run still counts as one.
    let isFirstRun = PrefsSchema.storedVersion(in: .standard) == nil
    // Fork bug 2: gated on the SAME predicate as every other surface, never on
    // the bare grant. Custom shortcuts are Carbon hotkeys and need no grant, so
    // an all-custom rig must not be shown a TCC prompt it can only refuse.
    if !isFirstRun, permission.isWarningWarranted {
      permission.promptIfNeeded()
    }
    if permission.isGranted {
      startMediaKeyTap()
    }
    // Monitoring runs for the app's lifetime and reports both directions, not
    // a one-shot wait for the grant. An ad-hoc re-sign drops the TCC grant
    // silently, and without this the keys stop working with no banner and no way
    // back short of a relaunch.
    permission.startMonitoring { [weak self] granted in
      guard let self else { return }
      if granted {
        // Re-grant (or first grant): the old tap port is dead after a TCC
        // round-trip, so the tap is rebuilt rather than reused. `start` tears
        // down any existing tap before creating the new one, so no explicit
        // stop is needed here.
        self.startMediaKeyTap()
      } else {
        // Revocation MUST tear the tap down. [MEASURED 2026-08-05] Revoking the
        // grant under a live active head-insert tap wedges WindowServer: the whole
        // input system freezes until the tap's mach port dies. stop() invalidates
        // the port, the same kernel-level release as the process death that
        // recovered the machine both times. The banner re-appears on its own via
        // `isGranted` observation.
        self.mediaKeyTap?.stop()
        self.model.noteTapDisarmed()
      }
      // Setup's permission page mirrors the grant from THIS closure rather than
      // calling `startMonitoring` itself: a second call REPLACES the observer and
      // callback, and the tap lifecycle above must keep them. nil until Setup has
      // been presented, and ignored once its window is gone.
      self.onboardingController?.accessibilityGrantChanged(granted)
    }

    // Warm the display list before the first open. Menu tracking holds the main
    // run loop in event-tracking mode, which starves main-actor task execution,
    // so a refresh cannot be relied on to land while the menu is open. Launch,
    // menu close and the topology loop are therefore the only refresh triggers;
    // `AppModel.refresh()` coalesces overlapping calls so they never race the DDC
    // bus.
    Task {
      await model.refresh()
      refreshTapConfig()
      updateStatusItemVisibility()
      wireInterferenceHooks()
      restoreCoordinator.noteLaunchOrReconfigure()
      // Before the first open, for the same reason the display list is warmed
      // here: nothing the panel starts can be relied on to run while the menu
      // is tracking.
      warmModeCatalogs()
      restoreUnattended()
      // The launch discovery pass produces no topology event (the CG callback
      // fires only on real reconfigurations), so the initial OLED-care enrollment
      // resolve happens here, against the freshly discovered list.
      model.oledCare.displaysReconfigured()
      // Setup's re-derivation for slow discovery (a no-op unless the window is
      // visible), then the first-run presentation. HERE, after the refresh, so the
      // flow's init-time seeds derive over the discovered list: presenting at the
      // end of launch raced discovery and produced the slim no-displays flow on a
      // desk with two externals [MEASURED].
      self.onboardingController?.displayTopologyChanged()
      if isFirstRun {
        presentOnboarding()
      }
      // Here rather than at the top of launch for the same reason as the setup
      // flow: the window's display rows derive over the discovered list.
      if UpdateRelaunch.consume() {
        SettingsOpener.open(at: .pane(.about))
      }
      // Virtual display launch prelude: normalize the slot prefs, log
      // any orphan from a previous instance, and recreate the recreate-at-launch
      // slots (skipped in Safe Mode). Non-blocking; creation runs on the model's
      // serial vd queue.
      model.syncVirtualDisplaysAtLaunch()
      #if DEBUG
        // Panel row model: the first dump, after the warm refresh, so it
        // describes a discovered display list. Before the settings hook so a
        // capture run's window cannot land between the refresh and the dump.
        DebugPanelDump.dumpIfRequested(model)
        // Screenshot hook. After `model.refresh()`, so `display:first`
        // has a display list to resolve against.
        DebugSettingsHook.openIfRequested(
          externalKeys: model.displays.map(\.display.persistenceKey)
        )
      #endif
    }

    // Destroy owned virtual displays on quit for a tidy topology handoff; a
    // crash gets the same result from mach-port teardown. Blocking the
    // terminate notification briefly is fine, and the short timeout bounds it.
    let virtualDisplayHost = model.virtualDisplays
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: nil
    ) { _ in
      // Synchronous on purpose: after this notification returns the process is
      // gone and a queued task would never run. The host is captured directly (it
      // is Sendable); the MainActor model must not be touched from this
      // nonisolated closure.
      //
      // The destroy runs on a BACKGROUND thread while main blocks on a semaphore,
      // never on main itself: the departure poll would otherwise pump a nested
      // main run loop mid-termination, turning the departing displays' own
      // screen-parameter notifications into topology refreshes, shade rebuilds
      // and DDC traffic on a process that is going away. The bounded wait lets a
      // hung teardown fall through to mach-port reclaim.
      let finished = DispatchSemaphore(value: 0)
      // Per slot: the departure poll plus a CG transaction, since `destroy`
      // breaks the mirrors it masters before polling. Floored at 4 s.
      let departureTimeout: TimeInterval = 1.5
      let ceiling = max(4, (departureTimeout + 0.75) * Double(max(1, virtualDisplayHost.live().count)))
      DispatchQueue.global(qos: .userInitiated).async {
        virtualDisplayHost.destroyAll(departureTimeout: departureTimeout)
        finished.signal()
      }
      _ = finished.wait(timeout: .now() + ceiling)
    }

    // Nobody else calls this. A no-op while the version key is absent (first
    // run) and the forward path for every stored version after, so it must run
    // before Setup completion writes the schema version.
    PrefsSchema.migrateIfNeeded(in: .standard)

    settingsActions.showOnboarding = { [weak self] in self?.presentOnboarding() }
    // Display Health windows: an AppKit island, reached through a
    // closure like onboarding because the views cannot see it.
    settingsActions.openDisplayHealth = { [weak self] key in
      self?.displayHealthPresenter.open(key: key)
    }
    settingsActions.openCheckup = { [weak self] in self?.checkupController().present() }
    // A full-domain wipe removes prefsSchemaVersion, so the post-reset
    // state IS a first-run state and gets the same window.
    settingsActions.postReset = { [weak self] in self?.presentOnboarding() }

    #if DEBUG
      startHUDDemoIfRequested()
    #endif
  }

  #if DEBUG
    /// `CANDELA_DEBUG_HUD_DEMO=<brightness|volume|muted|contrast>`: keeps one
    /// indicator pill on screen for capture runs. Permanent, like
    /// `DebugSettingsHook`: a worktree debug build never holds the Accessibility
    /// grant, so no media key reaches the tap and the pill has no other route to
    /// a screenshot. Style and position are re-read from prefs every tick, so the
    /// live pill is also the picker's demo. While it runs it wins over real key
    /// presses on its display. Compiled out of Release by construction, and the
    /// env-var name is long enough for the deploy grep to see.
    private func startHUDDemoIfRequested() {
      guard let raw = ProcessInfo.processInfo.environment["CANDELA_DEBUG_HUD_DEMO"] else { return }
      let type: HUDType = switch raw {
      case "volume": .volume
      case "muted": .volumeMuted
      case "contrast": .contrast
      default: .brightness
      }
      let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          let displayID = CGMainDisplayID()
          let prefs = DisplayPrefs(persistenceKey: "app")
          let position: HUDPosition = switch type {
          case .volume, .volumeMuted: prefs.hudPositionVolume
          case .brightness, .contrast: prefs.hudPositionBrightness
          }
          let name = self.model.displays.first { $0.id == displayID }
            .map { PanelView.title(for: $0.display) } ?? "Display"
          self.hud.showHUD(
            displayID: displayID, type: type, name: name,
            value: type == .volumeMuted ? 0 : 0.62, maxValue: 1,
            nameSuffix: nil, position: position, style: prefs.hudStyle)
        }
      }
      RunLoop.main.add(timer, forMode: .common)
      hudDemoTimer = timer
    }
  #endif

  /// Not a property initializer: the environment closure has to name the
  /// controller it is being handed to.
  private func checkupController() -> CheckupWindowController {
    if let checkupWindow { return checkupWindow }
    let controller = CheckupWindowController(
      environment: { [unowned self] in
        await CheckupLiveEnvironment.current(
          model: self.model,
          presenter: self.checkupController().fieldWindow,
          coordinator: self.model.oledCare)
      },
      onSaved: { [checkupLog] envelope in
        do {
          try CheckupStore(directory: CheckupStore.defaultDirectory()).save(envelope)
        } catch {
          checkupLog.error(
            "checkup report could not be saved: \(String(describing: error), privacy: .public)")
        }
      },
      care: model.oledCare)
    checkupWindow = controller
    return controller
  }

  /// The Setup window (user-facing name; "onboarding" is internal only).
  private func presentOnboarding() {
    let controller = onboardingController ?? OnboardingWindowController(
      model: model,
      actions: settingsActions,
      onCompletion: {
        // Completion is recorded HERE, on close by any route, not at launch.
        // A force-quit mid-Setup leaves the key absent and Setup runs again.
        PrefsSchema.recordCurrentVersion(in: .standard)
      }
    )
    // "Start Using Candela" otherwise closes the window into nothing: the app
    // lives in the menu bar and a first-run user has no reason to know that. The
    // callout points at the spot the icon occupies, including on an auto-hidden
    // bar, where it aims at the top edge the bar slides out of. Pointing beats
    // auto-opening the panel (tried first): with the bar hidden, a programmatic
    // performClick shows a disembodied menu that teaches nothing.
    controller.onFirstRunClosed = { [weak self] in
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(400))
        self?.showSetupLandingCallout()
      }
    }
    onboardingController = controller
    controller.present()
  }

  /// Post-Setup "the app lives up here" callout. A borderless non-activating
  /// panel, NOT an NSPopover: from a background LSUIElement app anchored to a
  /// status-bar window that may be offscreen under auto-hide, `.transient` dies
  /// to the first system dialog and `.semitransient` never appeared at all [both
  /// observed on hardware]. Skipped when the icon is hidden.
  private var setupLandingPanel: NSPanel?
  /// Bumped by every show. A pending dismissal compares the generation it
  /// captured against this one and stands down if a newer callout took over.
  private var setupLandingGeneration: UInt64 = 0
  private func showSetupLandingCallout() {
    guard let button = statusItem?.button, let buttonWindow = button.window else { return }

    // The global-domain auto-hide pref is in every app's defaults search list.
    // When the bar hides itself the icon's spot is empty air, so the words have
    // to say to move the pointer there; the hover reveals the bar with the icon
    // right where the arrow points.
    let barAutoHides = UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
    let message = barAutoHides
      ? "\(AppInfo.productName) lives in the menu bar, which is set to hide itself. Move the pointer to the top of the screen: the icon is right about here."
      : "\(AppInfo.productName) lives up here in the menu bar. Click the icon whenever you need it."

    // Plain AppKit, deliberately: an NSHostingView used as a borderless panel's
    // contentView re-sizes the WINDOW to SwiftUI's ideal size (a 1631-pt-tall
    // window growing off the screen, showing only empty background), and
    // `sizingOptions = []` did not stop it [both measured via CGWindowList].
    let icon = NSImageView()
    icon.image = NSImage(
      systemSymbolName: "menubar.arrow.up.rectangle", accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
    icon.contentTintColor = .secondaryLabelColor
    icon.setFrameSize(NSSize(width: 28, height: 24))

    let label = NSTextField(wrappingLabelWithString: message)
    label.font = .systemFont(ofSize: NSFont.systemFontSize)
    label.preferredMaxLayoutWidth = 240
    let labelSize = label.sizeThatFits(NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
    label.frame = NSRect(origin: .zero, size: labelSize)

    let inset: CGFloat = 14
    let contentSize = NSSize(
      width: inset + icon.frame.width + 10 + labelSize.width + inset,
      height: max(labelSize.height, icon.frame.height) + inset * 2
    )
    let card = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
    card.material = .popover
    card.state = .active
    card.wantsLayer = true
    card.layer?.cornerRadius = 12
    card.layer?.masksToBounds = true
    icon.setFrameOrigin(NSPoint(
      x: inset, y: (contentSize.height - icon.frame.height) / 2
    ))
    label.setFrameOrigin(NSPoint(
      x: inset + icon.frame.width + 10, y: (contentSize.height - labelSize.height) / 2
    ))
    card.addSubview(icon)
    card.addSubview(label)

    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.contentView = card
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .statusBar
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false

    // Placement anchors to the screen holding the POINTER: the user just clicked
    // "Start Using" there. The status window's own geometry is NOT trusted
    // blindly, since with an auto-hidden bar on a multi-display rig it reports a
    // chimera (measured: icon x from one display, y from another) that put the
    // panel on a monitor nobody was looking at. The icon's x is used only when it
    // is sane for the pointer's screen; otherwise the panel sits at the top
    // right, where the icon lives on every screen's bar anyway.
    let iconRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? buttonWindow.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? .zero
    let iconXSane = iconRect.midX >= visible.minX && iconRect.midX <= visible.maxX
    let anchorX = iconXSane ? iconRect.midX : visible.maxX - 160
    var origin = NSPoint(
      x: anchorX - contentSize.width / 2,
      y: visible.maxY - contentSize.height
    )
    origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - contentSize.width - 8))
    panel.setFrameOrigin(origin)

    // Every show builds its own window, so no fade is in flight on the arriving
    // one. The generation strands a superseded panel's pending dismissal, which
    // is why the outgoing panel is ordered out here at once: waiting for its own
    // timeout would leave an identical card sitting behind the new one.
    setupLandingGeneration &+= 1
    let generation = setupLandingGeneration
    setupLandingPanel?.orderOut(nil)
    // Reduce Motion takes the direct assignment: no animation at all, not even
    // a zero-duration one that could show a frame at the wrong opacity.
    let fadeIn = Motion.windowFadeIn(reduceMotion: Motion.systemReduceMotion)
    panel.alphaValue = fadeIn > 0 ? 0 : 1
    panel.orderFrontRegardless()
    setupLandingPanel = panel
    if fadeIn > 0 {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = fadeIn
        panel.animator().alphaValue = 1
      }
    }

    Task { @MainActor [weak self, weak panel] in
      try? await Task.sleep(for: .seconds(10))
      guard let panel else { return }
      // A newer callout already ordered this one out; nothing left to fade.
      if let self, self.setupLandingGeneration != generation { return }
      // Alpha does not suppress hit-testing, and this card sits over the
      // status-item region, so left live it swallows a click meant for the icon it
      // points at. The panel is built fresh per show, so nothing puts this back.
      panel.ignoresMouseEvents = true
      NSAnimationContext.runAnimationGroup { context in
        context.duration = Motion.windowFadeOut(reduceMotion: Motion.systemReduceMotion)
        panel.animator().alphaValue = 0
      } completionHandler: { [weak self] in
        // Typed `@Sendable`, but fires on the main thread where the panel lives.
        MainActor.assumeIsolated {
          if let self {
            // A show that arrived mid-fade owns the screen now, and it took care
            // of this window when it superseded it.
            guard self.setupLandingGeneration == generation else { return }
            if self.setupLandingPanel === panel { self.setupLandingPanel = nil }
          }
          // Fail-open, deliberately the inverse of the HUD's guard, which returns
          // without ordering out. The HUD reuses ONE window per display, so the
          // show that superseded a fade owns that window and has re-shown it. Here
          // every show builds its own panel and this task is the only thing that
          // orders it out, so returning early would leave an invisible window over
          // the menu bar for the session. Do not "fix the inconsistency".
          panel.orderOut(nil)
        }
      }
    }
  }

  /// Remove software dimming, then hand the DDC register the full-range
  /// equivalent of the published brightness, so the monitor is not left at a
  /// combined-mode DDC floor.
  func applicationWillTerminate(_: Notification) {
    gammaController.resetAllGamma() // not DDC, always runs
    shadeOverlay.removeAllShades() // not DDC, always runs
    // Above the safe-mode guard: this writes a report, not DDC, and a run
    // started in safe mode gets its report like any other.
    checkupWindow?.abandonForTermination()
    // Safe mode sends no unattended DDC. The full-range restore undoes
    // combined-mode dimming at quit, and safe mode never installed any, so
    // skipping it leaves the monitor where the user last put it.
    guard !isSafeMode else { return }
    // Submission counters, not the display list: `restoreFullRangeDDC` returns
    // early on several paths, so a display is no evidence of a write. Marked
    // before the lock-dim release, whose native-leg write the mark must cover.
    let marks = model.displays.map { ($0, $0.controller.submissionMark()) }
    // AFTER the gamma reset and shade removal, which tear the software surfaces
    // down unconditionally, so the restore below leaves the user's value on a
    // clean surface. BEFORE the full-range restore: quitting while a display is
    // lock-dimmed must hand the panel back to the user's own brightness, and
    // `restoreFullRangeDDC` returns early on the native path, which is exactly
    // where an HDR display's lock dim lives.
    model.oledCare.endAllLockDims()
    var submittedRestore = false
    for (state, mark) in marks {
      // Quitting while DisplayManager is suspended (mid-reconfigure or asleep)
      // silently drops this at the epoch gate. Best-effort is the
      // restore-choreography contract.
      state.controller.restoreFullRangeDDC()
      submittedRestore = submittedRestore || state.controller.submissionMark() != mark
    }
    // Best-effort barrier: the coalescer drains on the global executor, so a
    // short main-thread nap gives the ~20 ms/display DDC transactions time to
    // land before exit. Awaiting the main-actor waiters here would deadlock,
    // since terminate is synchronous on main.
    if submittedRestore {
      Thread.sleep(forTimeInterval: 0.25)
    }
  }

  /// Dock-less reopen (double-clicking the app in Finder, `open -a`): with no
  /// window to restore there is nothing for AppKit to do, so route it to
  /// Settings — never to onboarding, which is a first-run flow.
  ///
  /// The reopen recovery route, named by the Menu Bar pane's hidden-icon caption.
  /// Deliberately NOT gated on the icon being hidden: a reopen with the icon
  /// showing has nothing else to do either. It is also the only settings route
  /// this app controls, since ⌘, goes straight to SwiftUI's own menu item and
  /// never reaches `SettingsOpener`.
  ///
  /// Only reaches a RUNNING app. A cold launch with the icon hidden shows
  /// nothing; the second open is what lands here.
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
      warmModeCatalogs()
    }
  }

  /// Enumerates the display-mode list for every external display, once each.
  ///
  /// Every external, not just the ones the panel is showing: a display un-hidden
  /// in Settings would otherwise have no catalog on the next open, so the
  /// resolution control would be missing exactly once.
  ///
  /// Deliberately NOT driven from a `.task` inside the panel. Menu tracking holds
  /// the main run loop in event-tracking mode and starves main-actor tasks, so a
  /// view-driven enumeration lands after the menu closed and the section is
  /// missing on the open that asked for it.
  ///
  /// Enumeration is on demand and cached (never on a timer), and this
  /// re-enumerates every listed display rather than only those with no catalog: a
  /// catalog describes the panel now behind that ID, and a replug can reassign
  /// IDs between two panels while both stay present. Every call site runs it
  /// AFTER `model.refresh()`.
  private func warmModeCatalogs() {
    for state in model.displays {
      model.displayModes.refreshCatalog(for: state.id)
    }
  }

  /// The two unattended restores, remembered resolutions then the saved layout,
  /// as ONE operation.
  ///
  /// Driven from the launch warm task and the topology loop, nowhere else.
  /// The topology loop is this app's `CGDisplayReconfigurationCallBack` intake,
  /// and its one-second quiet window is why reapply hangs off it rather than the
  /// raw screen-parameters notification: applying a mode mid-burst is the case
  /// most likely to fail, and the display that just arrived is still settling.
  ///
  /// **The layout restore runs AFTER the mode reapply, as a guarantee**: a
  /// resolution change resizes the display, so a layout applied first would be
  /// tiled against footprints that are about to change. Fired onto separate
  /// queues the ordering was luck, and worse, the two starved each other: they
  /// claim the same reconfiguration gate, and a refused pass gives its arrival
  /// claims back assuming the holder's reconfiguration event will call it
  /// again, which neither produces when it applies nothing.
  /// `UnattendedRestoreSequence` has the detail.
  ///
  /// Safe mode gates BOTH here, where the flag lives. Safe mode is the launch you
  /// perform when the unattended restores are suspected of making things worse: a
  /// stored resolution can leave a screen unreadable and a restored layout can
  /// move the menu bar onto a display nobody is looking at, both with no
  /// countdown, because nobody is watching.
  private func restoreUnattended() {
    guard !isSafeMode else { return }
    unattendedRestores.run([
      { [model] in await model.displayModes.reapplyStoredModes() },
      { [model] in await model.arrangement.restoreSavedArrangement() },
    ])
  }

  /// Full-domain wipe, explicitly confirmed by the caller. The General pane
  /// owns the confirmation and its copy is bound to this function, so it names
  /// the hardware effects below (HDR off, unmute, OLED care torn down with the
  /// hour counters cleared) as well as what is destroyed, including the login
  /// item and the stored brightness, volume and contrast, which on a write-only
  /// panel are the only record of where the display is.
  func performSettingsReset() {
    Task { @MainActor in await runSettingsReset() }
  }

  private func runSettingsReset() async {
    // One reset at a time, app-wide (the latch a per-display reset claims too).
    // Overlapping them lets that reset restore HDR through a controller step 5
    // has already thrown away.
    guard model.beginReset() else { return }
    defer { model.endReset() }
    // ---- 0. OLED care first (the mute-strand rule's ordering applied to
    //         dimming): overlays down and hour counters reset while their
    //         objects are still alive. The domain wipe never reaches them,
    //         since `rebuildControllers()` does not touch `model.oledCare`, so
    //         a live tracker's debounced write-through would re-persist the
    //         hours just cleared.
    model.oledCare.prepareForReset()
    // The other half of the contract, bound to scope exit rather than the last
    // statement: `prepareForReset()` raised a latch that swallows every topology
    // event and pref reapply for the duration (an HDR-off below IS a
    // reconfiguration, and a mid-reset reconcile would re-arm overlays from
    // still-unwiped enrollment prefs). Only this call clears it and re-derives
    // membership from the wiped domain, so an early exit added later must not be
    // able to skip it or OLED care is dead for the rest of the session.
    defer { model.oledCare.resetDidComplete() }

    // ---- 1. Drive the hardware to a known state through the engine's own
    //         doors, while the prefs that describe that state still exist.
    //         (the controllers holding this state are about to be dropped,
    //         so nothing downstream can undo it for us.)
    // Displays whose HDR the USER engaged in System Settings. Keyed by
    // `persistenceKey`, not `CGDirectDisplayID`: step 5 rebuilds every controller
    // and re-derives the display list, and the EDID key is the only identity that
    // survives that.
    var restoreHDRAfterRebuild: Set<String> = []
    // Displays left muted as far as anyone can tell: the unmute stood down, or it
    // went out unconfirmed. Their mute state and their strategy have to survive
    // the wipe. The mute-strand rule's first clause orders unmute before
    // disabling, and where the unmute could not be established the only way to
    // honour that is to not disable.
    // Written back after the wipe rather than exempted from it, because a domain
    // removal has no per-key exemptions to give.
    var keepMuteStateFor: [String: Bool] = [:]

    for state in model.displays {
      let prefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)

      // HDR first. Wiping the pref under an engaged controller strands the panel
      // in HDR while the app believes it is off, and the next launch writes DDC
      // into a register the monitor has locked, so brightness silently stops
      // working with no diagnostic. (Never write `prefs.hdrMode` directly;
      // the controller owns the state machine.)
      //
      // The RESET door rather than `setHDRMode(.off)`: that decides from the
      // stored mode and the cached mirror, and the mirror lags a System Settings
      // toggle until the reconfigure lands. This door measures the panel.
      //
      // It answers the restore question at the same time, and that question is
      // about two things: the display's state, and Candela's opinion. Live HDR
      // with no opinion behind it came from System Settings and goes back at the
      // end; live HDR under `.alwaysOn` is a Candela setting, and clearing it is
      // what this button is for.
      //
      // The answer is evidence, not a request: `.disengaged` comes off a measured
      // read taken after the drop settled, and it licenses the writes below.
      //
      // It also drops the duplicate memos of every queue on this display's wire,
      // which the unmute depends on: a write ACKed while the display was in HDR
      // was swallowed by the panel, so a memo built through that window would let
      // the unmute be skipped as a duplicate of a value the register never took,
      // and reported as applied.
      let hdrState = await state.controller.disengageHDRForReset()
      if case .disengaged(restoreAfterward: true) = hdrState {
        restoreHDRAfterRebuild.insert(state.display.persistenceKey)
      }

      // Clear the AVAILABILITY prefs BEFORE attempting the unmute,
      // never after. `DDCValueController.toggleMute` opens with
      // `guard command == .volume, isFresh, isAvailable`, and `isAvailable` is
      // `!unavailableDDC && !forceSoftware`, so an unmute attempted first is a
      // silent no-op and the wipe then leaves the panel hardware-muted with
      // `enableMuteUnmute` false: no code path left that can ever send
      // 0x8D = 2 again.
      prefs.forceSoftware = false
      for command in DDCCommand.allCases {
        var tuning = prefs.tuning(for: command)
        tuning.unavailableDDC = false
        prefs.setTuning(tuning, for: command)
      }

      // Now the unmute can run, and it runs while `enableMuteUnmute` still holds
      // the user's value, so the right wire goes out: 0x8D = 2 in the
      // hardware-mute strategy, a volume rewrite in the default one. Wiping first
      // would flip `enableMuteUnmute` to false and downgrade the unmute to a
      // volume write the panel may ignore.
      //
      // Skipped under `.unknown`, where the display may still be in HDR: the
      // unmute would clear the stored mute flag over a register that stayed
      // muted, and the wipe then retires the strategy that could undo it.
      // Standing down leaves the display muted and SAYING so, the recoverable
      // half of the mute-strand rule's choice. The wipe still runs; it takes no
      // hardware with it.
      //
      // An unmute that CANNOT BE CONFIRMED is the same outcome, not a log line.
      // `toggleMute` has already cleared the stored flag by then, so without the
      // same treatment the wipe would take the strategy too and the display would
      // come back reporting itself unmuted over a register nobody reached: the
      // full strand the mute-strand rule's first clause exists to prevent, from
      // the button that exists to undo it. Reachable without any race, since the
      // disengage's own reconfiguration can outlast the settle window.
      if state.volume.isMuted {
        var unmuteLanded = false
        if case .disengaged = hdrState {
          _ = state.volume.toggleMute()
          // Multi-round and gate-aware, like the restore: one immediate retry
          // falls inside the same reconfiguration window that skipped the first
          // attempt, so it proves nothing.
          unmuteLanded = await WireQuiescence.settle(
            [state.volume], isWireOpen: { state.volume.isWireOpen }
          )
        }
        if !unmuteLanded {
          log.error("""
            reset: display \
            \(DisplayLogging.tag(for: state.display.persistenceKey), privacy: .public) \
            could not be confirmed unmuted, so its mute state and strategy are kept \
            across the wipe
            """)
          // The STRATEGY AS IT STANDS, not a fixed value: restoring the wrong one
          // changes which wire a later unmute writes. Both are kept, because both
          // leave a panel silent: the dedicated command has no sender left once
          // retired, and the default strategy's volume 0 comes back as a display
          // reporting itself unmuted at a level it is not at.
          keepMuteStateFor[state.display.persistenceKey] = prefs.enableMuteUnmute
        }
      }
    }

    // ---- 2. Un-dim (fork parity): a wiped domain must not leave a gamma/shade
    //         dim installed with no pref recording it.
    gammaController.resetAllGamma()
    shadeOverlay.removeAllShades()

    // ---- 2b. Virtual displays down BEFORE the wipe removes their slot keys: a
    //          wiped `configured` with the display still standing is state the
    //          pane cannot explain, and the display would survive until quit
    //          with no control that knows it. The explicit key clear is
    //          redundant with the domain wipe today, load-bearing for any future
    //          partial reset.
    await model.destroyAllVirtualDisplaysForReset()
    DisplayPrefs(persistenceKey: "app").clearVirtualSlots()

    // ---- 3. The login item is part of "all settings" and the copy says so.
    //         `LoginItem.isEnabled` reads `SMAppService.mainApp.status` live, so
    //         any pane holding a LoginItem shows OFF right after this, with no
    //         mirrored bool to go stale.
    // The async overload is the one Swift selects, and the one we want: it
    // resolves after the unregistration is recorded, so the live `isEnabled` read
    // that follows cannot observe a stale ON.
    try? await SMAppService.mainApp.unregister()

    // ---- 3b. Sparkle stores its keys in our defaults domain, so the wipe would
    //          take the update preference, which this button does not offer to
    //          change. Read here, written back after.
    let automaticUpdateChecks = updaterModel.automaticallyChecksForUpdates

    // ---- 4. The wipe itself.
    UserDefaults.standard.removePersistentDomain(
      forName: Bundle.main.bundleIdentifier ?? "com.rydersel.Candela"
    )

    // ---- 4b. The two facts a stranded display cannot afford to lose, put back
    //          BEFORE the rebuild reads prefs at construction (`muted` is read by
    //          `DDCValueController.init`). `muted` is as load-bearing as the
    //          strategy: a display whose register holds a mute while the app
    //          reports it unmuted is the silent half of the strand.
    //
    //          This buys the ORDINARY mute control back: the display returns
    //          reporting itself muted, under the strategy it was muted with, so
    //          toggling mute drives the right wire. Not the stranded-mute banner,
    //          whose predicate also needs the command to be unavailable, which
    //          this reset just cleared.
    for (key, usedMuteCommand) in keepMuteStateFor {
      let prefs = DisplayPrefs(persistenceKey: key)
      prefs.enableMuteUnmute = usedMuteCommand
      prefs.muted = true
    }

    // ---- 4c. Through Sparkle, not its key: a key written behind the updater
    //          never reaches the running scheduler.
    updaterModel.automaticallyChecksForUpdates = automaticUpdateChecks

    // ---- 5. Rebuild, do NOT merely refresh. `refresh()` would reuse every
    //         controller for a still-connected display and leave it holding
    //         state derived from the prefs just destroyed.
    await model.rebuildControllers()

    // ---- 5a. Rebuilt controllers carry no interference hooks. Before 5b, which
    //          makes the first post-reset gamma write and would skip the check.
    wireInterferenceHooks()

    // ---- 5b. The post-reset value has to reach the GLASS, not just the slider.
    //          The wipe leaves every display with an empty store, so each rebuilt
    //          controller publishes the fresh-display default and nothing sends
    //          it: the arrival branch only READS, and the restore pass does not
    //          run here. Without this the slider claims 100% while the panel stays
    //          where the user left it, and on a write-only panel the slider's
    //          claim IS the app's belief, with no readback to correct it.
    //
    //          The built-in brightness gate is not bypassed, it is
    //          inapplicable: it exists so a LAUNCH-time restore never blasts
    //          a display this session has never known to an assumed
    //          default, and these displays were under
    //          Candela's control a moment ago. `reassertHardware` is deliberately
    //          ungated for this kind of caller.
    //
    //          Carrying the pre-reset value across the wipe instead (step 4b's
    //          shape) would not fix it: the wipe also restores the default
    //          combined switching point, so the same published number means a
    //          different physical brightness. Only a write makes the two agree.
    //
    //          Every command, for one reason: each republishes an assumed default
    //          that no door would otherwise send. The two DDC commands carry their
    //          own refusals inside `reassertHardware` so a caller cannot forget
    //          them: it declines while the display is muted, which is how a mute
    //          this reset carried across the wipe survives (the mute-strand
    //          rule's first clause), and when
    //          the command is unavailable or the display is forced to software.
    //
    //          The volume verdict is the exception that cannot live in the engine:
    //          The capabilities probe's answer is per display and observed here.
    //          `.unknown` allows,
    //          as it does for the slider; only a capability string that parsed
    //          cleanly and omits 0x62 refuses, which spares a panel that would
    //          otherwise take a volume write into a register it does not
    //          implement.
    //
    //          Externals only: macOS owns the built-in's brightness and its
    //          controller seeded from a live native read, so its slider already
    //          agrees with its glass.
    //
    //          BEFORE step 6: DDC is unlocked only while HDR is down. The writes
    //          are submitted, not settled here; `restoreExternalHDR` opens by
    //          settling this display's queues and declines to re-engage if it
    //          cannot, so a display getting HDR back cannot lock the register over
    //          a write still in the air.
    for state in model.displays {
      state.controller.reassertHardware()
      state.contrast.reassertHardware()
      if model.volumeSupport[state.display.persistenceKey] != .unsupported {
        state.volume.reassertHardware()
      }
    }

    // Through the seam's own closure, not `refreshTapConfig()` directly: the wipe
    // reset the key-mode prefs, and `.rearmTap` is where custom-shortcut
    // registration re-syncs against them. The private helper would re-arm the
    // CGEvent tap and leave the Carbon hotkeys registered against modes that no
    // longer exist.
    settingsActions.rearmTap()
    updateStatusItemVisibility()
    model.notePrefsChanged()
    // The About pane mirrors Sparkle's state, which the wipe just moved.
    updaterModel.refreshFromUpdater()
    // Post-reset state IS first-run state: prefsSchemaVersion is gone, so
    // onboarding re-runs.
    settingsActions.postReset()

    // ---- 6. LAST. The reset dropped HDR so the register was unlocked for the
    //         mute-strand-rule unmute in step 1, and re-engaging locks it again,
    //         so this cannot run before the rebuilt controllers have taken their
    //         opening writes.
    //         "Taken" means confirmed applied, not submitted: the restore settles
    //         this display's queues and declines to re-engage if it cannot.
    //
    //         SCOPE: this covers the REBUILT controllers only. Step 1's own exit
    //         write belongs to the controller step 5 discarded. What makes that
    //         harmless is NOT the epoch gate (an epoch is stamped at submit and
    //         checked at dequeue, both back in step 1) but that the write is long
    //         since drained: its queue runs on its own task, the reset suspends
    //         many times in between, and teardown ends the drain loop only after
    //         every submitted target has COMPLETED. Nothing in this step enforces
    //         any of that, and it should not be read as if it did.
    //
    //         It restores the display's state, NOT a mode: `restoreExternalHDR`
    //         persists nothing, because a reset that promises to clear Candela's
    //         settings must not end by writing one.
    for state in model.displays
      where restoreHDRAfterRebuild.contains(state.display.persistenceKey) {
      await state.controller.restoreExternalHDR()
    }
    // OLED care's latch is cleared by the `defer` at the top of this function,
    // which runs here, after every statement above.
  }

  /// Hands every display's controller a pre-gamma-apply hook that runs the
  /// interference check for that display. Idempotent, and re-run after each
  /// refresh so new displays get one and no hook outlives the display it names.
  private func wireInterferenceHooks() {
    for state in model.displays {
      let displayID = state.id
      let displayName = state.display.name
      let persistenceKey = state.display.persistenceKey
      let monitor = interferenceMonitor
      state.controller.preGammaApplyHook = { [weak controller = state.controller] in
        monitor.checkBeforeApply(displayID: displayID, displayName: displayName) {
          // Accept: this display stops using gamma for good...
          DisplayPrefs(persistenceKey: persistenceKey).avoidGamma = true
          // ...hand its tables back (per-display; `resetAllGamma` would drop
          // every other display's dimming too)...
          // Through the controller, not straight to the island: under an engaged
          // synthesis pairing the dim wrote TWO tables, and the island call
          // would restore only the panel's, leaving the virtual display holding a
          // scaled one under a display the shade now dims as well. The controller
          // also owns the enforcer target.
          controller?.handBackGammaTables()
          // ...and re-apply the current brightness through the shade backend.
          // `handleReconfigure` is the door: it clears the software dedupe memo
          // (which `setBrightness` alone would trip over, the value being
          // unchanged) and re-runs the software leg, now routed to the shade.
          // Async, so this returns to the alert at once. `recapture: false`
          // because the interfering app may own the table right now, and a
          // baseline capture would bake its curve in as the default.
          Task { @MainActor in await controller?.handleReconfigure(recapture: false) }
        }
      }
    }
  }

  private func startMediaKeyTap() {
    guard let mediaKeyTap else { return }
    // Computed once and recorded only on success: `lastArmedTapConfig` is what is
    // actually being watched, and a config that failed to arm is not that.
    let config = model.tapConfig
    do {
      try mediaKeyTap.start(config: config)
      model.noteTapArmed(config)
    } catch MediaKeyEventTap.TapError.eventFieldsUnrecognized {
      // Not a relaunch away: the private CGEvent field indices the decode depends
      // on no longer behave, which takes an app update to fix.
      log.error(
        """
        media-key tap disarmed: this macOS version does not answer the CGEvent \
        fields the media-key decode reads; media keys are off until Candela is updated
        """
      )
    } catch {
      log.error("media-key tap failed to start: \(error); keys disabled until relaunch")
    }
  }

  /// Re-arms or disarms brightness keys after display topology changes (the
  /// fork's `updateMediaKeyTap`). No-op unless the tap is running.
  private func refreshTapConfig() {
    guard let mediaKeyTap, mediaKeyTap.isRunning else { return }
    let config = model.tapConfig
    mediaKeyTap.update(config: config)
    model.noteTapArmed(config)
  }

  /// Filled while a keep-awake assertion is held: it suppresses every OLED care
  /// dim for the session, so a hold visible only inside the panel is one nobody
  /// remembers taking. A refused assertion leaves `isOn` false and the glyph idle.
  private func updateStatusItemImage() {
    guard let statusItem else { return }
    let isHeld = model.keepAwake.isOn
    statusItem.button?.image = NSImage(
      systemSymbolName: isHeld ? "sun.max.fill" : "sun.max",
      accessibilityDescription: isHeld ? "Candela, keeping the display awake" : "Candela")
  }

  /// `withObservationTracking` fires once, before the write lands, so the value
  /// is read on the hop and the tracking re-armed there.
  private func trackKeepAwake() {
    withObservationTracking {
      _ = model.keepAwake.isOn
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        self.updateStatusItemImage()
        self.trackKeepAwake()
      }
    }
  }

  /// Applies the `menuIcon` mode to the status item. Called at launch, after
  /// every display refresh, and from the settings seam's `.updateStatusItem`
  /// effect, which fires for the hide-display prefs too because they decide
  /// `hasVisibleSlider`.
  private func updateStatusItemVisibility() {
    guard let statusItem else { return }
    let visible = MenuIconPolicy.isStatusItemVisible(
      mode: DisplayPrefs(persistenceKey: "app").menuIcon,
      hasExternalDisplay: !model.displays.isEmpty,
      // Exactly the panel's own question, same statics, so the icon and the
      // panel cannot disagree about whether a slider exists.
      hasVisibleSlider: !PanelView.visibleDisplays(model).isEmpty || PanelView.showsBuiltIn(model)
    )
    guard statusItem.isVisible != visible else { return }
    isApplyingStatusItemVisibility = true
    statusItem.isVisible = visible
    isApplyingStatusItemVisibility = false
  }

  /// KVO sink for `NSStatusItem.isVisible`: the user dragged the icon out of the
  /// menu bar, or we hid it ourselves.
  private func statusItemVisibilityChanged(isVisible: Bool) {
    let prefs = DisplayPrefs(persistenceKey: "app")
    guard let mode = MenuIconPolicy.modeAfterVisibilityChange(
      isVisible: isVisible,
      changedByUser: !isApplyingStatusItemVisibility,
      current: prefs.menuIcon
    ) else { return }
    prefs.menuIcon = mode
    // Deliberately NOT `settingsActions.prefDidChange(.menuIcon)`: that row also
    // fires `.updateStatusItem`, which would re-apply visibility on top of the
    // drag the user just performed. Only the re-render is wanted.
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

/// Hosting view that keeps its frame matched to SwiftUI's ideal size. Menu item
/// views are frame-based with no Auto Layout parent, so when the panel's content
/// changes the frame has to follow the new fitting size.
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
