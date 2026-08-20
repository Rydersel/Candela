import AppKit
import CandelaKit
import SwiftUI

/// The AppKit island that hosts the guided setup flow. An `LSUIElement` app
/// has no ordinary window scene, and a `Window` scene would be permanently
/// listed in the Window menu (and a `WindowGroup` opened the settings window
/// on plain launch, a measured regression), so this is a plain `NSWindow`
/// created on demand.
///
/// D14's load-bearing detail lives in `windowWillClose`: completion is recorded
/// when the window goes away (by the flow's finish, by ⌘W, or by the close
/// button), never at launch. Force-quitting mid-Setup therefore re-runs it,
/// which the fork could not do (it set `appAlreadyLaunched` two statements
/// after presenting the window).
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
  private let model: AppModel
  private let actions: SettingsActions
  private let onCompletion: () -> Void
  /// Fires after the window closes ONLY when the close came from the finish
  /// page's "Start Using …" action, the explicit "I'm done, show me the app"
  /// action. ⌘W, the red close button and Skip Setup complete Setup (D14) but
  /// stay quiet: the user asked to dismiss a window, not to be handed a menu.
  var onFinishedByButton: (() -> Void)?
  private var closedByFinishButton = false
  /// Constructed once and reused, exactly like the window, and that is only
  /// safe because `isEnabled` is a LIVE read of `SMAppService.mainApp.status`
  /// (D10). This object holds no copy of the registration state, so there is
  /// nothing here to go stale after a settings reset unregisters the login
  /// item.
  private let loginItem = LoginItem()
  private var window: NSWindow?
  /// The live flow, rebuilt on every fresh presentation so the environment is
  /// harvested at present time and a re-run starts from its first page.
  private var flowModel: OnboardingFlowModel?
  private var applier: OnboardingLiveApplier?

  init(model: AppModel, actions: SettingsActions, onCompletion: @escaping () -> Void) {
    self.model = model
    self.actions = actions
    self.onCompletion = onCompletion
    super.init()
  }

  func present() {
    let window = window ?? makeWindow()
    self.window = window
    // A fresh presentation gets a fresh flow over a fresh harvest; a present()
    // while the window is already up only brings it forward, keeping the
    // user's place.
    if !window.isVisible {
      installFlow(in: window)
    }
    // Belt and braces on top of the live read and `LoginItem`'s own
    // didBecomeActive observer: a presentation is the one moment we know the
    // toggle is about to be looked at, and `refresh()` is an integer bump.
    loginItem.refresh()
    window.center()
    // MUST be `activate(ignoringOtherApps: true)`, NOT the modern
    // `NSApp.activate()`: the modern call cannot activate an accessory
    // (LSUIElement) app from inside a status-item menu tracking session, so
    // Setup opens BEHIND the frontmost app. Measured on an isolated harness
    // (4/4 runs). The deprecation is accepted deliberately here.
    //
    // The call must also stay inside the click's event context: every
    // `DispatchQueue.main.async` variant lost the activation grant, and
    // neither `makeKeyAndOrderFront` nor `orderFrontRegardless` rescues it.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    // D13 safety net: `recordCurrentVersion` is otherwise written ONLY from
    // `windowWillClose`. If presentation ever fails (an `LSUIElement` window
    // that will not order front, a future AppKit change), the version key
    // would never be written, the app would re-run Setup on every launch, and
    // `migrateIfNeeded` would never have a stored version to advance.
    // Recording it here in that case costs the (already broken) Setup window
    // and keeps the schema honest.
    if !window.isVisible {
      onCompletion()
    }
  }

  /// Mirror of the app's ONE `AccessibilityPermission.startMonitoring`
  /// closure, which `StatusItemController` owns for the media-key tap's
  /// lifecycle. Called from an extension of that closure, never from a second
  /// `startMonitoring`: a second call REPLACES the observer and callback, and
  /// stealing the tap's would wedge its grant and revocation handling.
  func accessibilityGrantChanged(_ granted: Bool) {
    flowModel?.accessibilityGranted = granted
  }

  /// Called from the app's single topology consumption loop after
  /// `model.refresh()`: the display list changed, so the flow re-derives its
  /// pages from a fresh harvest. Launch discovery produces no topology event;
  /// presentation seeds from current state instead.
  func displayTopologyChanged() {
    guard let flowModel, window?.isVisible == true else { return }
    flowModel.update(
      environment: OnboardingLiveEnvironment.current(model: model, loginItem: loginItem))
  }

  private func installFlow(in window: NSWindow) {
    // A fresh flow replaces the applier; the old one forgets its pending
    // apply so its observation loop can die instead of reporting into a
    // discarded flow.
    self.applier?.cancel()
    let flow = OnboardingFlowModel(
      environment: OnboardingLiveEnvironment.current(model: model, loginItem: loginItem))
    let applier = OnboardingLiveApplier(model: model, flow: flow)
    flow.applierCountdownSeconds = OnboardingLiveApplier.countdownSeedSeconds
    let router = liveRouter()
    let permission = model.accessibility
    flow.onCommit = { router.route($0) }
    flow.onRequestAccessibility = { permission.promptIfNeeded() }
    flow.onOpenAccessibilitySettings = { AccessibilityPermission.openSystemSettings() }
    // OB5: the request and nothing else. The return value means "already
    // granted", not "granted now" (it is false when the dialog was merely
    // shown), so nothing may gate on it; the telemetry pref itself is written
    // later through the commit router when the care page is advanced past.
    flow.onRequestScreenRecording = { _ = CGRequestScreenCaptureAccess() }
    // Achieved state for the care page's copy: the preflight, never the
    // request's return value.
    flow.onPreflightScreenRecording = { CGPreflightScreenCaptureAccess() }
    flow.onApplySize = { [weak applier] key, width, height in
      applier?.applySize(displayKey: key, looksLikeWidth: width, looksLikeHeight: height)
    }
    flow.onKeepSize = { [weak applier] in applier?.keep() }
    flow.onRevertSize = { [weak applier] in applier?.revert() }
    flow.onClose = { [weak self, weak flow] in
      guard let self else { return }
      // The flow's own close fires from the finish advance and from Skip
      // Setup. On the finish page the skip link never renders, so a close
      // arriving there IS the finish, and only that close earns the landing
      // callout.
      if flow?.currentPage == .finish {
        self.closedByFinishButton = true
      }
      self.window?.performClose(nil)
    }
    self.flowModel = flow
    self.applier = applier
    window.contentView = NSHostingView(rootView: OnboardingFlowView(model: flow))
    window.setContentSize(NSSize(width: 760, height: 560))
  }

  /// The commit router over the real write paths (OB6): D27 pref writes
  /// through `DisplayPrefWriter`, launch at login through `LoginItem`'s live
  /// SMAppService read and setter (D10).
  private func liveRouter() -> OnboardingCommitRouter {
    let actions = actions
    let loginItem = loginItem
    return OnboardingCommitRouter(
      writeFriendlyName: { key, name in
        // Arrives normalized from the router's own guard; no second trim.
        DisplayPrefWriter(persistenceKey: key, actions: actions)
          .write(.friendlyName) { $0.friendlyName = name }
      },
      enrollInCare: { key in
        DisplayPrefWriter(persistenceKey: key, actions: actions)
          .write(.oledCareEnrolled) { $0.oledCareEnrolled = true }
      },
      enableMeasuredTelemetry: { key in
        DisplayPrefWriter(persistenceKey: key, actions: actions)
          .write(.oledTelemetry) { $0.oledTelemetry = true }
      },
      isLoginItemEnabled: { loginItem.isEnabled },
      setLaunchAtLogin: { loginItem.setEnabled($0) },
      // Deliberately nothing: a kept preview already wrote
      // `sizeAppliedByUser` inside the coordinator, and a second record would
      // be redundant.
      acknowledgeAppliedSize: { _, _, _ in }
    )
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 760, height: 560)),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    // Hidden in the titlebar, but still what VoiceOver and the Window menu
    // read, so it uses the user-facing name for this flow, "Setup".
    window.title = "\(AppInfo.productName) Setup"
    // The flow is composed against its own dark palette; the window forces it
    // so a light-mode system does not render dark text on dark canvas.
    window.appearance = NSAppearance(named: .darkAqua)
    // Without this the window is deallocated on close and the next
    // `present()` messages freed memory.
    window.isReleasedWhenClosed = false
    window.delegate = self
    return window
  }

  func windowWillClose(_: Notification) {
    // The red close button and ⌘W bypass the flow's own skip route, so an
    // open countdown is answered here with the revert the model already owns;
    // idempotent when the flow closed itself.
    flowModel?.sizePageDisappeared()
    // After the revert routed, the applier forgets any pending apply so its
    // observation loop dies rather than staying armed behind a closed window.
    // An answer still waiting on its first preview observation survives the
    // cancel and is delivered when that preview appears.
    applier?.cancel()
    onCompletion()
    if closedByFinishButton {
      closedByFinishButton = false
      onFinishedByButton?()
    }
  }
}
