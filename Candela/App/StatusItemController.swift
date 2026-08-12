import AppKit
// @preconcurrency: same mutable-C-global import quirk as AccessibilityPermission.
@preconcurrency import ApplicationServices
import CandelaKit
import os
import ServiceManagement
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
  /// D11: Shift held at launch. Read once in `init` — a modifier poll, fork
  /// parity — and never re-read, so the mode cannot change mid-session.
  let isSafeMode: Bool

  override init() {
    let safeMode = NSEvent.modifierFlags.contains(.shift)
    isSafeMode = safeMode
    let shade = ShadeOverlay()
    let gamma = GammaController()
    shadeOverlay = shade
    gammaController = gamma
    // Bound to a local as well as to the property: reading `self`'s stored
    // properties before `super.init()` is not allowed, and the handoff below
    // needs the same instance.
    let monitor = GammaInterferenceMonitor(gamma: gamma, alerts: EngineAlerts())
    interferenceMonitor = monitor
    let model = AppModel(shade: shade, gamma: gamma, safeMode: safeMode)
    self.model = model
    // Reporting-only handoff (B7): the monitor is constructed here because it
    // needs the AppKit alert island, and read there because the diagnostics
    // pane has no other way to say how often another app took a display's
    // color profile back.
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
  // Media-key pipeline (tap → router → executor → controllers + HUD). Stored
  // as properties: the tap's thread and the executor must outlive launch.
  private var keyActionExecutor: KeyActionExecutor?
  private var mediaKeyTap: MediaKeyEventTap?
  /// Custom-shortcut dispatch. Held for the app's lifetime — the handlers it
  /// registers capture it weakly, so dropping it would silently kill every
  /// custom shortcut.
  private var shortcutManager: ShortcutManager?
  /// Held for the app's lifetime so "Run Setup Again…" and the post-reset
  /// re-run reuse one window instead of stacking copies.
  private var onboardingController: OnboardingWindowController?
  /// Answers a resolution preview started from the panel. Held here because the
  /// coordinator references it weakly — the countdown must outlive the menu
  /// tracking session that started it, so the window cannot be owned by a view.
  private var modeConfirmation: ModeConfirmationWindow?
  /// Answers a mirror preview, and reports a mirror change that was refused,
  /// failed, or only partly happened. Held for the same reason as the mode
  /// window above — and additionally because the hotkey has no other surface at
  /// all, so this is the only thing that can say anything about it.
  private var mirrorConfirmation: MirrorConfirmationWindow?
  private var rotationConfirmation: RotationConfirmationWindow?
  /// Answers an arrangement preview. Held for the same reason as the three
  /// above: the coordinator references it weakly and the countdown outlives
  /// whatever started the change.
  private var arrangementConfirmation: ArrangementConfirmationWindow?
  /// Stored (review M23) so the topology loop can `cleanupDisplay` departed
  /// displays' HUD panels; the executor shares this same instance.
  private let hud = BrightnessHUD()
  /// Sleep/wake observation tokens (block-based observers stay registered
  /// only while retained). Never removed — fork parity, app-lifetime.
  private var sleepWakeObservers: [any NSObjectProtocol] = []
  /// Startup/wake DDC restore choreography (D5). `startupAction` is app-level
  /// but read through DisplayPrefs like every other engine pref — and, under
  /// safe mode, through a prefs object whose getter reports `.doNothing`
  /// (D11), which is what disables both restores for the session. Assigned in
  /// `init` rather than inline because it needs that flag.
  private let restoreCoordinator: RestoreCoordinator
  /// The two unattended restore passes, chained (see `restoreUnattended()`).
  /// A property rather than a local so two topology events cannot interleave
  /// their halves — the second call's passes wait on the first call's.
  private let unattendedRestores = UnattendedRestoreSequence()
  /// The only writer to `model.mirrorTopology`. Held for the app's lifetime —
  /// it owns a block-based notification registration, and dropping it would
  /// freeze the store at the launch sample without anything saying so.
  private lazy var mirrorSampler = MirrorTopologySampler(store: model.mirrorTopology)
  private let log = Logger(subsystem: "com.rydersel.Candela", category: "keys")

  func applicationDidFinishLaunching(_: Notification) {
    // D11: the notice states exactly what safe mode does and exactly what it
    // does not. The fork's copy ("Default settings are reloaded, DDC read is
    // blocked") is wrong twice — nothing is reloaded, and it blocks the
    // startup write too. Shipping a different false statement about the same
    // feature would reproduce the defect D11 exists to fix, in the more
    // dangerous direction: a user reaching for safe mode because a DDC write
    // is wedging their monitor must not be told the traffic has stopped when
    // it has not. Sliders and keys stay live on purpose — gating them would
    // make every panel control silently dead and would disable the only
    // unmute affordance a hardware-muted display has (D29 rule 3).
    if isSafeMode {
      let alert = NSAlert()
      alert.messageText = "Safe Mode"
      // The words live in `SafeModeCopy` (#147), with the Diagnostics row and
      // the General pane caption, because this notice named three suppressions
      // for a milestone while the app performed four: W3a added OLED care to
      // the code and to one of the three surfaces. The list is one enum now, so
      // a fifth suppression cannot reach only one of them.
      var informative = SafeModeCopy.launchNotice(app: AppInfo.productName)
      // The one piece of traffic the list does not cover, and the reason the
      // paragraph is appended here rather than folded in: it is conditional on
      // a pref, and it is additional to the four rather than one of them.
      if DisplayPrefs(persistenceKey: "app").enableBrightnessSync {
        informative += "\n\n" + SafeModeCopy.brightnessSyncParagraph
      }
      alert.informativeText = informative
      // Accessory-policy app: without activating first, a launch-time alert can
      // come up behind whatever was frontmost. `NSApp.activate()` is enough
      // here — the SettingsOpener caveat about the deprecated variant applies
      // only inside a menu tracking session, and there is none at launch. Same
      // shape as `EngineAlerts`.
      NSApp.activate()
      alert.runModal()
    }

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
    // appear a beat later, once the warm refresh below discovers the external —
    // acceptable, and the correct trade: `.hide` must take effect at once.
    updateStatusItemVisibility()

    // The mirror topology's only writer, started BEFORE the first discovery
    // pass: `model.mirrorTopology` is what every drawable-ID resolution reads,
    // and an unstarted sampler leaves it holding the empty topology — i.e. the
    // identity function, which is the pre-DT15 behaviour wearing the new seam's
    // clothes. Launching into an already-engaged mirror set is an ordinary way
    // to start, so the launch sample is not a formality.
    mirrorSampler.start()

    // Reconfiguration intake: synchronous registration on the main thread is
    // load-bearing — CG delivers the callback on the registering thread's
    // run loop, and only the main thread has one that lives forever.
    model.displayManager.activate()

    // OLED care (W3a): starts the driver loop (unless Safe Mode, which still
    // builds the chrome controller — spec §7) and wires its own lock and
    // sleep/wake observers. Its display membership is resolved by the warm
    // task and the topology loop below via `displaysReconfigured()`.
    model.oledCare.start(model: model)

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

    // Re-arm when a capabilities probe lands (D24). The watched set is gated on
    // the display's own verdict for the volume and mute registers, and that
    // verdict arrives asynchronously after the display does, so the first arm
    // after a plug is always made from the pre-probe answer.
    model.onVolumeKeyRoutingChanged = { [weak self] in self?.refreshTapConfig() }

    settingsActions.rearmTap = { [weak self] in
      self?.refreshTapConfig()
      // Task 12 hand-off: a Carbon hotkey registration is exclusive and
      // system-wide, so an assigned shortcut whose mode is off silently steals
      // its combination from every other app. Registration must therefore
      // follow the modes, and the settings reset wipes those modes — without
      // this, shortcuts stay registered against prefs that no longer exist
      // until the next relaunch. Sitting in `.rearmTap` rather than in the
      // reset body covers every mode write that routes through the seam, not
      // just this one. Static: the manager instance is private here, and the
      // KeyboardShortcuts registry is global.
      ShortcutManager.syncRegistration()
    }
    settingsActions.recheckPermissions = { [weak self] in
      // D2 bug 2: the fork computes this and never calls it, so changing a
      // keyboard mode never re-prompts. Candela prompts — but only when a mode
      // change actually made the CGEvent tap wanted. Custom shortcuts are
      // Carbon hotkeys and need no grant, so an all-custom rig must not be
      // shown a TCC prompt it can only refuse.
      let prefs = DisplayPrefs(persistenceKey: "app")
      guard KeyModePolicy.requiresAccessibility(
        brightness: prefs.keyboardBrightness, volume: prefs.keyboardVolume
      ) else { return }
      self?.model.accessibility.promptIfNeeded()
    }
    settingsActions.updateStatusItem = { [weak self] in self?.updateStatusItemVisibility() }
    settingsActions.performReset = { [weak self] in self?.performSettingsReset() }

    // The panel's own naming rule, so a renamed display is named the same way in
    // the row that started a change, in the window that confirms it, and on the
    // arrangement canvas. Falls back to "" for a display `DisplayDiscovery` never
    // saw — it filters on a non-nil `IOAVService`, so virtual, AirPlay and
    // Sidecar displays have no settings state to be renamed in, and each surface
    // substitutes the topology's own name for them.
    let displayName: (CGDirectDisplayID) -> String = { [weak self] displayID in
      guard let state = self?.model.allControlledStates.first(where: { $0.id == displayID })
      else { return "" }
      return PanelView.title(for: state.display)
    }
    // Resolved through the store on each use rather than captured as a value:
    // a window outlives any single topology, and a mirror can engage while it
    // is up — which for a MIRROR preview is not a hypothetical, it is the thing
    // being previewed.
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
    // D27: the coordinator writes `storedDisplayMode` when the user PINS one
    // (SO19 — no longer on a kept preview), and the seam has to hear about it
    // whichever surface asked. Wired once here rather than in each surface —
    // the panel's window has no `SettingsActions`, and a second copy of this
    // rule is a second thing to forget.
    model.displayModes.didStoreMode = { [weak self] displayID in
      guard let self,
            let key = model.allControlledStates
            .first(where: { $0.id == displayID })?.display.persistenceKey
      else { return }
      self.settingsActions.prefDidChange(.storedDisplayMode, persistenceKey: key)
    }
    // Spec §7: a failed resolution restore joins the diagnostics event ring.
    // Wired here for the reason above — a reapply runs unattended at reconnect,
    // with no view on screen to notice it.
    model.displayModes.didReportReapply = { [weak self] displayID, notice in
      guard let self else { return }
      let name = self.model.allControlledStates
        .first { $0.id == displayID }?.display.name ?? "a display"
      self.model.noteDisplayEvent("\(name): \(DiagnosticsCopy.reapplyEvent(notice))")
    }

    // Mirroring's own surface. Same argument as the resolution window, plus one
    // this one has on its own: a mirror change can be started from a HOTKEY,
    // with no panel and no settings window anywhere, so without this a refusal
    // or a failed apply would be completely silent.
    let mirrorConfirmation = MirrorConfirmationWindow(coordinator: model.mirroring)
    mirrorConfirmation.drawableDisplayID = drawableDisplayID
    self.mirrorConfirmation = mirrorConfirmation
    model.mirroring.confirmation = mirrorConfirmation
    model.mirroring.displayName = displayName
    // Rotation's own surface, the third caller of `ConfirmationPanel`. It needs
    // one for the settings window's reason rather than the hotkey's — there is
    // no rotation hotkey (RT1) — but the settings window is very often on a
    // DIFFERENT display from the one that just rotated, which is exactly the
    // "answered blind" case the window exists to prevent.
    let rotationConfirmation = RotationConfirmationWindow(coordinator: model.rotation)
    rotationConfirmation.drawableDisplayID = drawableDisplayID
    rotationConfirmation.displayName = displayName
    self.rotationConfirmation = rotationConfirmation
    model.rotation.confirmation = rotationConfirmation

    // Arrangement's own surface, the fourth CALLER of `ConfirmationPanel` — not
    // a fourth window type, which is how one of the first three shipped with an
    // invisible primary button (#54). It has the strongest case of the four for
    // being a window: an arrangement change is the one that can move the menu
    // bar onto a different display, so the surface asking about it must go where
    // the menu bar ended up rather than where the request was made.
    let arrangementConfirmation = ArrangementConfirmationWindow(coordinator: model.arrangement)
    arrangementConfirmation.drawableDisplayID = drawableDisplayID
    arrangementConfirmation.displayName = displayName
    self.arrangementConfirmation = arrangementConfirmation
    model.arrangement.confirmation = arrangementConfirmation
    // The canvas names its tiles through the coordinator, so the map and the
    // confirmation window call a display by the same name.
    model.arrangement.displayName = displayName
    // D27, the same wiring `didStoreMode` gets and for the same reason: the
    // coordinator writes `savedArrangements` when a layout is kept, and the seam
    // has to hear about it whichever surface answered. App-level, so no
    // persistence key — the layout is a fact about the display SET.
    model.arrangement.didSaveArrangement = { [weak self] in
      self?.settingsActions.prefDidChange(.savedArrangements)
    }

    // The orphaned-shade fix (see `MirroringCoordinator.rebuildSoftwareDimming`).
    // Wired here because it needs an AppKit island and the display list; D28
    // decides WHICH door — `reapplyAfterPrefChange()`, never
    // `handleReconfigure(recapture:)` and never `setBrightness(sameValue)`,
    // because the first re-runs only the software leg and no-ops in pure-DDC
    // mode and the second is memo-suppressed.
    model.mirroring.rebuildSoftwareDimming = { [weak self] in
      guard let self else { return }
      self.shadeOverlay.removeAllShades()
      for state in self.model.displays {
        state.controller.reapplyAfterPrefChange()
      }
    }

    // Topology consumption loop — the stream's single consumer: after each
    // debounced reconfiguration (or post-wake sober), re-discover displays,
    // re-arm the media-key tap, and drop departed displays' HUD panels.
    Task { [weak self] in
      guard let stream = self?.model.displayManager.topologyChanges else { return }
      for await _ in stream {
        guard let self else { return }
        // Backstop, and first: the screen-parameters observer is the primary
        // trigger, but everything below this line may resolve a drawable ID and
        // none of it should read a topology older than this event.
        self.mirrorSampler.refresh()
        // Cheap (one `displays()` call), and it is what every drawable-ID
        // resolution in the app reads. The coordinator observes the raw
        // screen-parameters notification itself, so this is the same kind of
        // backstop the line above is — not the primary trigger.
        self.model.mirroring.refreshTopology()
        let departed = await self.model.refresh()
        self.refreshTapConfig()
        self.updateStatusItemVisibility()
        // OLED care: IDs may have been REASSIGNED even with every display
        // still present (MAG 3→2, Dell 2→3 across one dock cycle), so the
        // coordinator tears its overlays down and re-renders from state under
        // freshly resolved IDs — never a repin (W3a ruling). After `refresh()`
        // so it reconciles against the post-event display list.
        self.model.oledCare.displaysReconfigured()
        // D5: a reconfigure pass restores once (the wake repeat chain, when
        // one is running, keeps re-asserting on its own schedule).
        self.restoreCoordinator.noteLaunchOrReconfigure()
        self.wireInterferenceHooks()
        self.warmModeCatalogs()
        self.restoreUnattended()
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
        // Shades reset the same way, in the same place, and for a reason the
        // gamma line does not have: a shade is created, keyed, framed, alpha'd
        // and removed under the DRAWABLE id, so a topology change MOVES ITS KEY.
        //
        // The direction that STRANDS one is a mirror ENGAGING. Display S is
        // software-dimming under key S; S becomes a slave; S's controller
        // resolves to the master from that instant on, so key S is never named
        // again; `repinFrames()` explicitly skips it (S has no `NSScreen`, and
        // the deliberate choice there is to leave the window alone rather than
        // guess a frame); and what is left is a full-screen black window at
        // `CGShieldingWindowLevel()` holding its last dim alpha over a display
        // with no desktop, with no route out of it inside the app short of
        // quitting.
        //
        // A mirror BREAKING does not strand anything, and the distinction is
        // worth stating so nobody narrows this call to that path: the ex-master
        // resolves to itself (it was never a slave) and re-names its own key on
        // the next re-apply, and the ex-slave gets a fresh shade under its own
        // id. Removing wholesale covers both, so the call is unconditional.
        //
        // Nothing else in this path removes shades (`removeAllShades` otherwise
        // runs only at terminate and at wipe-all-settings), and this loop is
        // where the topology change becomes visible. `MirroringCoordinator`
        // performs the same teardown from the RAW screen-parameters
        // notification, which is earlier than this debounced stream — see
        // `rebuildSoftwareDimming`; this remains the backstop for a change that
        // somehow posts no notification.
        //
        // Safe to do wholesale because the loop below re-establishes it:
        // `handleReconfigure` nils the software dedupe memo and re-runs the
        // software leg, which recreates the shade under the NEW drawable id.
        // Displays with no shade to recreate — native path, pure DDC, and the
        // built-in slot (`shade: nil`, so it is never in this dictionary at
        // all) — are unaffected.
        self.shadeOverlay.removeAllShades()
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
    shortcutManager = ShortcutManager(model: model, executor: executor)
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

    // #59: after an emergency teardown (revocation seen by the AX poll, or a
    // WindowServer wedge broken by the deadman switch), wait out the settle
    // window, then either rebuild the tap (false alarm — e.g. a slow display
    // reconfigure tripped the probe) or record the disarm so diagnostics
    // reads "not running". The delay matters: right after a wedge breaks, a
    // pending TCC delete commits within moments, and rebuilding immediately
    // could recreate the tap the revocation was trying to kill.
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
    // D14 + HIG: on a first run the Setup window owns the Accessibility ask so
    // it can explain WHY first. Prompting here would fire the system dialog
    // before the window is even on screen — the one thing integrating the
    // request into Setup is supposed to prevent. `prefsSchemaVersion` is the
    // trigger (D13/D14): it is written at Setup *completion*, so an
    // interrupted first run still counts as a first run.
    let isFirstRun = PrefsSchema.storedVersion(in: .standard) == nil
    // Fork bug 2 (#60): gated on the SAME predicate as every other surface
    // (panel banner, Keyboard pane warning row, diagnostics), never on the
    // bare grant. Custom shortcuts are Carbon hotkeys and need no grant, so an
    // all-custom rig must not be shown a TCC prompt it can only refuse — one
    // question, answered one way everywhere it is asked.
    if !isFirstRun, permission.isWarningWarranted {
      permission.promptIfNeeded()
    }
    if permission.isGranted {
      startMediaKeyTap()
    }
    // D9: monitoring runs for the app's lifetime and reports both directions —
    // it is not a one-shot wait for the grant. An ad-hoc re-sign drops the TCC
    // grant silently, and before this the keys simply stopped working with no
    // banner and no way back short of a relaunch.
    permission.startMonitoring { [weak self] granted in
      guard let self else { return }
      if granted {
        // Re-grant (or first grant): the old tap port is dead after a TCC
        // round-trip, so the tap is rebuilt rather than reused. `start` tears
        // down any existing tap before creating the new one, so no explicit
        // stop is needed here.
        self.startMediaKeyTap()
      } else {
        // Revocation MUST tear the tap down (#59). [MEASURED 2026-08-05]
        // Revoking the grant under a live active head-insert tap wedges
        // WindowServer — the entire input system freezes until the tap's mach
        // port dies. stop() invalidates the port, the same kernel-level
        // release as the process death that recovered the machine both times.
        // The banner still re-appears on its own via `isGranted` observation.
        self.mediaKeyTap?.stop()
        self.model.noteTapDisarmed()
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
      // Before the first open, for the same reason the display list is warmed
      // here: nothing the panel starts can be relied on to run while the menu
      // is tracking.
      warmModeCatalogs()
      restoreUnattended()
      // The launch discovery pass produces no topology event (the CG callback
      // fires only on actual reconfigurations), so the initial OLED-care
      // enrollment resolve happens here, against the freshly discovered list.
      model.oledCare.displaysReconfigured()
      #if DEBUG
        // Screenshot hook (DT6). After `model.refresh()`, so `display:first`
        // has a display list to resolve against.
        DebugSettingsHook.openIfRequested(
          externalKeys: model.displays.map(\.display.persistenceKey)
        )
      #endif
    }

    // D13: nobody else calls this. It is a no-op while the version key is
    // absent (first run), and the forward path for every stored version after
    // that — so it must run before the schema version is written by Setup
    // completion.
    PrefsSchema.migrateIfNeeded(in: .standard)

    settingsActions.showOnboarding = { [weak self] in self?.presentOnboarding() }
    // D12: a full-domain wipe removes prefsSchemaVersion, so the post-reset
    // state IS a first-run state and gets the same window.
    settingsActions.postReset = { [weak self] in self?.presentOnboarding() }

    // Last statement of launch, per the HIG: Setup appears over a fully live
    // app (menu-bar icon already installed, displays warming) rather than as
    // part of launching.
    if isFirstRun {
      presentOnboarding()
    }
  }

  /// The Setup window (user-facing name; "onboarding" is internal only).
  private func presentOnboarding() {
    let controller = onboardingController ?? OnboardingWindowController(
      permission: model.accessibility,
      onCompletion: {
        // D14: completion is recorded HERE — on close, by any route — not at
        // launch. A force-quit mid-Setup leaves the key absent and the next
        // launch runs Setup again.
        PrefsSchema.recordCurrentVersion(in: .standard)
      }
    )
    // "Start Using Candela" otherwise closes the window into… nothing — the
    // app lives in the menu bar and a first-run user has no reason to know
    // that. A popover anchored to the status button points its arrow at the
    // exact spot the icon occupies — including on an auto-hidden menu bar,
    // where the arrow aims at the top edge the bar slides out of. Pointing
    // beats auto-opening the panel (tried first): with the bar hidden, a
    // programmatic performClick shows a disembodied menu that teaches the
    // user nothing about where the app lives.
    controller.onFinishedByButton = { [weak self] in
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(400))
        self?.showSetupLandingCallout()
      }
    }
    onboardingController = controller
    controller.present()
  }

  /// Post-Setup "the app lives up here" callout. A borderless non-activating
  /// floating panel, NOT an NSPopover: from a background LSUIElement app,
  /// anchored to a status-bar window that may itself be offscreen (auto-hide),
  /// `.transient` dies to the first system dialog and `.semitransient` never
  /// appeared at all [both observed on hardware]. A panel we position
  /// ourselves has no such moods. Skipped when the icon is hidden — there is
  /// nothing to point at.
  private var setupLandingPanel: NSPanel?
  private func showSetupLandingCallout() {
    guard let button = statusItem?.button, let buttonWindow = button.window else { return }

    // The global-domain auto-hide pref is in every app's defaults search
    // list. When the bar hides itself the icon's spot is empty air, so the
    // words must say to move the pointer there — the hover reveals the bar
    // with the icon right where the arrow points.
    let barAutoHides = UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
    let message = barAutoHides
      ? "\(AppInfo.productName) lives in the menu bar, which is set to hide itself. Move the pointer to the top of the screen: the icon is right about here."
      : "\(AppInfo.productName) lives up here in the menu bar. Click the icon whenever you need it."

    // Plain AppKit, deliberately: an NSHostingView used as a borderless
    // panel's contentView re-sizes the WINDOW to SwiftUI's ideal size — a
    // 1631-pt-tall window growing off the screen, with only empty background
    // in view — and `sizingOptions = []` did not stop it [both measured via
    // CGWindowList]. A label in a box has no opinions about window geometry.
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

    // Placement anchors to the screen holding the POINTER — the user just
    // clicked "Start Using" there, so that is where their attention is. The
    // status window's own geometry is NOT trusted blindly: with an auto-
    // hidden bar on a multi-display rig it reports a chimera (measured:
    // icon x from one display, y from another), which put the panel on a
    // monitor nobody was looking at. The icon's x is used only when it is
    // sane for the pointer's screen; otherwise the panel sits in the
    // status-item region at the top right, which is where the icon lives on
    // every screen's bar anyway.
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
    panel.orderFrontRegardless()
    setupLandingPanel = panel

    Task { @MainActor [weak self, weak panel] in
      try? await Task.sleep(for: .seconds(10))
      panel?.orderOut(nil)
      if let self, self.setupLandingPanel === panel { self.setupLandingPanel = nil }
    }
  }

  /// Review M24 + D5: remove software dimming, then hand the DDC register the
  /// full-range equivalent of the published brightness so the monitor is not
  /// left at a combined-mode DDC floor.
  func applicationWillTerminate(_: Notification) {
    gammaController.resetAllGamma() // not DDC — always runs
    shadeOverlay.removeAllShades() // not DDC — always runs
    // D11: safe mode sends no unattended DDC. The full-range restore exists to
    // undo combined-mode dimming at quit; in safe mode we never installed any
    // (no restore ran and no software leg was re-applied on our behalf), so
    // skipping it leaves the monitor exactly where the user last put it.
    guard !isSafeMode else { return }
    // Ordering, both halves of it. AFTER the gamma reset and shade removal
    // above, and that is correct rather than incidental: those two tear the
    // software surfaces down unconditionally, and the restore below re-applies
    // whatever leg is live, so the final state is the user's value on a clean
    // surface. Ending the dim first would just have it torn down again.
    // FIRST, and before the full-range restore below: quitting while a display
    // is lock-dimmed must hand the panel back to the user's own brightness.
    // `restoreFullRangeDDC` already writes the undimmed value on the DDC leg,
    // but it returns early on the native path, which is exactly where an HDR
    // display's lock dim lives. Safe Mode never starts the dimming loop, so
    // there is nothing outstanding on the other side of the guard above.
    model.oledCare.endAllLockDims()
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
  ///
  /// This is SO24's recovery route, and the Menu Bar pane's hidden-icon caption
  /// names it ("Open Candela again from Applications to get back to these
  /// settings"). Deliberately NOT gated on the icon being hidden: the caption
  /// depends on the hidden case, but a reopen with the icon showing has nothing
  /// else to do either, and gating would delete a working route to buy nothing.
  /// It is also the only settings route this app controls — ⌘, is delivered
  /// straight to SwiftUI's own menu item and never reaches `SettingsOpener`.
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
  /// Every external, not just the ones the panel is currently showing: a
  /// display un-hidden in Settings would otherwise have no catalog on the next
  /// open, and only get one on the close after that — the resolution control
  /// would be missing exactly once, which is the hardest kind of missing to
  /// report.
  ///
  /// Deliberately NOT driven from a `.task` inside the panel. Menu tracking
  /// holds the main run loop in event-tracking mode and starves main-actor task
  /// execution — the same reason the display refresh above is triggered from
  /// here rather than from the view — so a view-driven enumeration would land
  /// after the menu closed and the section would be missing on the open that
  /// asked for it, appearing only on the next one.
  ///
  /// Enumeration is on demand and cached (DM7, never on a timer): this skips
  /// displays that already have a catalog, and the coordinator keeps the rest
  /// fresh from screen-parameters notifications.
  private func warmModeCatalogs() {
    for state in model.displays where model.displayModes.catalogs[state.id] == nil {
      model.displayModes.refreshCatalog(for: state.id)
    }
  }

  /// The two unattended restores — remembered resolutions, then the saved
  /// layout — as ONE operation.
  ///
  /// Driven from exactly two places — the launch warm task and the topology
  /// loop above — and from nowhere else (DM7). The topology loop is this app's
  /// `CGDisplayReconfigurationCallBack` intake, and its one-second quiet window
  /// is why reapply hangs off it rather than off the raw screen-parameters
  /// notification the coordinator already observes: applying a mode in the
  /// middle of a reconfiguration burst is the case most likely to fail, and the
  /// display that just arrived is still settling. The coordinator decides which
  /// displays count as arrivals, so calling this on every quiet window is not
  /// the same as reapplying continuously.
  ///
  /// **The layout restore runs AFTER the mode reapply, and that is now a
  /// guarantee rather than an intent** (§7.4): a resolution change resizes the
  /// display, so a layout applied first would be tiled against footprints that
  /// are about to change. The two used to be fired back-to-back onto separate
  /// queues, which made the ordering luck — and, worse, made the two starve each
  /// other, because they claim the same AR12 gate and a refused pass gives its
  /// arrival claims back on the premise that the holder's reconfiguration event
  /// will call it again. Neither pass produces one when it decides to apply
  /// nothing, which is the dominant case for both. `UnattendedRestoreSequence`
  /// documents the whole of it.
  ///
  /// Safe mode gates BOTH here, where the flag lives. Safe mode is the launch you
  /// perform when the app's unattended restores are suspected of making things
  /// worse: a stored resolution is the one restored value that can leave a
  /// screen unreadable, and a restored layout is the one that can move the menu
  /// bar onto a display the user is not looking at — both with no countdown
  /// behind them, because nobody is watching. The alert's copy names resolution
  /// for the same reason.
  private func restoreUnattended() {
    guard !isSafeMode else { return }
    unattendedRestores.run([
      { [model] in await model.displayModes.reapplyStoredModes() },
      { [model] in await model.arrangement.restoreSavedArrangement() },
    ])
  }

  /// D12: full-domain wipe, explicitly confirmed by the caller (the General
  /// pane owns the confirmation, and SO20 binds its copy to this function: it
  /// names the hardware effects below (HDR off, unmute, OLED care torn down
  /// with the hour counters cleared) as well as what is destroyed, including
  /// the login item and the stored brightness/volume/contrast, which on a
  /// write-only panel are the only record of where the display is).
  func performSettingsReset() {
    Task { @MainActor in await runSettingsReset() }
  }

  private func runSettingsReset() async {
    // One reset at a time, app-wide (the latch a per-display reset claims too).
    // Overlapping them would let that reset restore HDR through a controller
    // step 5 has already thrown away.
    guard model.beginReset() else { return }
    defer { model.endReset() }
    // ---- 0. OLED care first (D29's ordering applied to dimming): overlays
    //         down and hour counters reset while their objects are still
    //         alive. The domain wipe below never reaches them —
    //         `rebuildControllers()` does not touch `model.oledCare` — so a
    //         live tracker's debounced write-through would re-persist the
    //         hours the user just cleared.
    model.oledCare.prepareForReset()
    // The other half of the contract, bound to scope exit rather than to the
    // last statement: `prepareForReset()` raised a latch that swallows every
    // topology event and pref reapply for the duration (an HDR-off below IS a
    // reconfiguration, and a mid-reset reconcile would re-arm overlays from
    // still-unwiped enrollment prefs). Only this call clears it and re-derives
    // membership from the wiped domain — nothing else re-reconciles after the
    // wipe, so an early exit added here later must not be able to skip it or
    // OLED care is silently dead for the rest of the session.
    defer { model.oledCare.resetDidComplete() }

    // ---- 1. Drive the hardware to a known state through the engine's own
    //         doors, while the prefs that describe that state still exist.
    //         (D30: the controllers holding this state are about to be dropped,
    //         so nothing downstream can undo it for us.)
    // Displays whose HDR the USER engaged in System Settings (#83). Keyed by
    // `persistenceKey` and not `CGDirectDisplayID`, because step 5 rebuilds
    // every controller and the display list is re-derived on the far side of
    // that; the EDID key is the only identity that survives it.
    var restoreHDRAfterRebuild: Set<String> = []
    // Displays left muted as far as anyone can tell: the unmute stood down, or
    // it went out and could not be confirmed. Their mute state and their
    // strategy have to survive the wipe, keyed by persistence key with the
    // strategy they were using. D29 rule 1 states the ordering as
    // unmute-before-disabling; where the unmute could not be established, the
    // only way to honour it is to not disable. Written back after the wipe
    // rather than exempted from it: the wipe is a domain removal, and it has no
    // per-key exemptions to give.
    var keepMuteStateFor: [String: Bool] = [:]

    for state in model.displays {
      let prefs = DisplayPrefs(persistenceKey: state.display.persistenceKey)

      // HDR first. Wiping the pref under an engaged controller strands the
      // panel in HDR while the app believes it is off, and the next launch then
      // writes DDC into a register the monitor has locked, so brightness
      // silently stops working with no diagnostic. (D22: never write
      // `prefs.hdrMode` directly; the controller owns the state machine.)
      //
      // The RESET door rather than `setHDRMode(.off)`: that one decides from
      // the stored mode and the cached mirror, and the mirror lags a System
      // Settings toggle until the reconfigure lands, which is exactly the state
      // this paragraph warns about. This door measures the panel.
      //
      // It answers the restore question in the same breath, and that question
      // is about two different things: the display's state, and Candela's
      // opinion. Live HDR with no opinion behind it came from System Settings
      // and goes back at the end; live HDR under `.alwaysOn` is a Candela
      // setting, and clearing it is what this button is for.
      //
      // The answer is evidence and not a request: `.disengaged` comes off a
      // measured read taken after the drop settled, and it is what licenses the
      // hardware writes below.
      //
      // The other two controllers go in because their duplicate memos have to
      // be dropped here: a write ACKed while the display was in HDR was
      // swallowed by the panel, so a memo built through that window would let
      // the unmute below be skipped as a duplicate of a value the register
      // never took, and reported as applied.
      let hdrState = await state.controller.disengageHDRForReset(
        alsoInvalidating: [state.volume, state.contrast]
      )
      if case .disengaged(restoreAfterward: true) = hdrState {
        restoreHDRAfterRebuild.insert(state.display.persistenceKey)
      }

      // D29 rule 2: clear the AVAILABILITY prefs BEFORE attempting the unmute,
      // never after. `DDCValueController.toggleMute` opens with
      // `guard command == .volume, isFresh, isAvailable`, and `isAvailable` is
      // `!unavailableDDC && !forceSoftware` — so an unmute attempted first is a
      // silent no-op, and the wipe would then leave the panel hardware-muted
      // with `enableMuteUnmute` false, i.e. with no code path left that can ever
      // send 0x8D = 2 again.
      prefs.forceSoftware = false
      for command in DDCCommand.allCases {
        var tuning = prefs.tuning(for: command)
        tuning.unavailableDDC = false
        prefs.setTuning(tuning, for: command)
      }

      // Now the unmute can actually run — and it runs while `enableMuteUnmute`
      // still holds the user's value, so the correct wire goes out: 0x8D = 2 in
      // the hardware-mute strategy, a volume rewrite in the default one. Wiping
      // first would flip `enableMuteUnmute` to false and silently downgrade the
      // unmute to a volume write the panel may ignore.
      //
      // Skipped under `.unknown`, where the display may still be in HDR: the
      // unmute would clear the stored mute flag over a register that stayed
      // muted, and the wipe below then retires the strategy that could undo it.
      // Standing the unmute down leaves the display muted and SAYING so, which
      // is the recoverable half of D29's choice. The wipe still runs: it is what
      // the user asked for, and it takes no hardware with it.
      //
      // An unmute that CANNOT BE CONFIRMED counts as the same outcome, not as a
      // log line. `toggleMute` has already cleared the stored flag by then, so
      // without the same treatment the wipe would take the strategy too and the
      // display would come back reporting itself unmuted over a register nobody
      // ever reached: the full D29 rule 1 strand, produced by the button that
      // exists to undo it. Reachable without any race, because the disengage's
      // own reconfiguration can outlast the settle window.
      if state.volume.isMuted {
        var unmuteLanded = false
        if case .disengaged = hdrState {
          _ = state.volume.toggleMute()
          // Multi-round and gate-aware, like the restore: one immediate retry
          // falls inside the same reconfiguration window that skipped the first
          // attempt, so it proves nothing the first attempt did not.
          unmuteLanded = await WireQuiescence.settle(
            [state.volume], isWireOpen: { state.volume.isWireOpen }
          )
        }
        if !unmuteLanded {
          log.error(
            "reset: display \(state.display.persistenceKey, privacy: .public) could not be confirmed unmuted, so its mute state and strategy are kept across the wipe"
          )
          // The STRATEGY AS IT STANDS, not a fixed value: restoring the wrong
          // one would change which wire a later unmute writes. Both are kept,
          // because both leave a panel silent: the dedicated command has no
          // sender left once retired, and the default strategy's volume 0 comes
          // back as a display reporting itself unmuted at a level it is not at.
          keepMuteStateFor[state.display.persistenceKey] = prefs.enableMuteUnmute
        }
      }
    }

    // ---- 2. Un-dim (fork parity): a wiped domain must not leave a gamma/shade
    //         dim installed with no pref recording it.
    gammaController.resetAllGamma()
    shadeOverlay.removeAllShades()

    // ---- 3. D12(c): the login item is part of "all settings" and the copy says
    //         so. `LoginItem.isEnabled` reads `SMAppService.mainApp.status` live
    //         (D10), so any pane or onboarding window holding a LoginItem shows
    //         OFF immediately after this — no mirrored bool to go stale.
    // The async overload is the one Swift selects here, and it is the one we
    // want: it resolves after the unregistration has actually been recorded,
    // so the live `isEnabled` read that follows cannot observe a stale ON.
    try? await SMAppService.mainApp.unregister()

    // ---- 4. The wipe itself.
    UserDefaults.standard.removePersistentDomain(
      forName: Bundle.main.bundleIdentifier ?? "com.rydersel.Candela"
    )

    // ---- 4b. The two facts a stranded display cannot afford to lose, put back
    //          BEFORE the rebuild reads prefs at construction (`muted` is read
    //          by `DDCValueController.init`). `muted` is as load-bearing as the
    //          strategy: a display whose register holds a mute while the app
    //          reports it unmuted is the silent half of the strand.
    //
    //          What this buys is the ORDINARY mute control: the display comes
    //          back reporting itself muted, under the strategy it was muted
    //          with, so toggling mute drives the right wire again. It is not
    //          the stranded-mute banner, whose predicate also requires the
    //          command to be unavailable, and this reset has just cleared that.
    for (key, usedMuteCommand) in keepMuteStateFor {
      let prefs = DisplayPrefs(persistenceKey: key)
      prefs.enableMuteUnmute = usedMuteCommand
      prefs.muted = true
    }

    // ---- 5. D30: rebuild, do NOT merely refresh. `refresh()` would reuse every
    //         controller for a still-connected display and leave it holding
    //         state derived from the prefs just destroyed.
    await model.rebuildControllers()
    // Through the seam's own closure, not `refreshTapConfig()` directly: the
    // wipe reset the key-mode prefs, and `.rearmTap` is where custom-shortcut
    // registration is re-synced against them (Task 12 hand-off). Calling the
    // private helper here would re-arm the CGEvent tap and leave the Carbon
    // hotkeys registered against modes that no longer exist.
    settingsActions.rearmTap()
    updateStatusItemVisibility()
    model.notePrefsChanged()
    // Post-reset state IS first-run state: prefsSchemaVersion is gone, so
    // onboarding re-runs (wired by Task 15; default no-op until then).
    settingsActions.postReset()

    // ---- 6. LAST. The reset dropped HDR so the DDC register was unlocked for
    //         the D29 unmute in step 1, and re-engaging locks it again, so this
    //         cannot run before the rebuilt controllers have taken their own
    //         opening writes. "Taken" means confirmed as applied, not merely
    //         submitted: the restore is handed this display's other two
    //         controllers and settles all three queues, and it declines to
    //         re-engage at all if it cannot get them settled.
    //
    //         SCOPE, stated so the guarantee is not read as wider than it is:
    //         this covers the REBUILT controllers only. Step 1's own exit write
    //         belongs to the controller step 5 discarded, and its queue is not
    //         one of these. What makes that harmless is NOT the epoch gate: an
    //         epoch is stamped at submit and checked at dequeue, both of which
    //         happened back in step 1, so nothing gates it retroactively. It is
    //         that the write is long since drained. Its queue runs on its own
    //         task and the reset suspends many times between step 1 and here
    //         (the unmute settling, the login-item unregister, the rebuild), and
    //         dropping the controller does not cancel it either: teardown ends
    //         the drain loop only after every already-submitted target has
    //         COMPLETED, which is the weaker word on purpose, since a target the
    //         gate skipped completes without reaching the panel. That is the
    //         right guarantee here: what matters is that nothing is left in
    //         flight to land after the engage. Nothing in this step enforces
    //         any of it, and nothing in this step should be read as if it did.
    //
    //         It restores the display's state, NOT a mode: `restoreExternalHDR`
    //         deliberately persists nothing, because a reset that promises to
    //         clear Candela's settings must not end by writing one.
    for state in model.displays
      where restoreHDRAfterRebuild.contains(state.display.persistenceKey) {
      await state.controller.restoreExternalHDR(alsoDraining: [state.volume, state.contrast])
    }
    // OLED care's latch is cleared by the `defer` at the top of this function,
    // which runs here — after every statement above.
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
      // Hoisted like the two above so the hook never captures `self`.
      let topology = model.mirrorTopology
      state.controller.preGammaApplyHook = { [weak controller = state.controller] in
        monitor.checkBeforeApply(displayID: displayID, displayName: displayName) {
          // Accept: this display stops using gamma for good...
          DisplayPrefs(persistenceKey: persistenceKey).avoidGamma = true
          // ...hand its table back (per-display; `resetAllGamma` would drop
          // every other display's dimming too)...
          // Scale 1.0 is a hand-back, so the write target and the enforcer
          // target are the same display; the enforcer still has to be on a
          // drawable one, which is the store's job to say (DT15).
          gamma.applyGammaScale(
            1.0, on: displayID, enforcerOn: topology.drawableDisplayID(for: displayID)
          )
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
    // Computed once and recorded only on success: `lastArmedTapConfig` is
    // "what is actually being watched", and a config that failed to arm is
    // not that (B9).
    let config = model.tapConfig
    do {
      try mediaKeyTap.start(config: config)
      model.noteTapArmed(config)
    } catch {
      log.error("media-key tap failed to start: \(error); keys disabled until relaunch")
    }
  }

  /// Re-arms/disarms brightness keys after display topology changes — the M2
  /// slice of the fork's updateMediaKeyTap. No-op unless the tap is running.
  private func refreshTapConfig() {
    guard let mediaKeyTap, mediaKeyTap.isRunning else { return }
    let config = model.tapConfig
    mediaKeyTap.update(config: config)
    model.noteTapArmed(config)
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
