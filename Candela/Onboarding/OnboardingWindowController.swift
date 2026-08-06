import AppKit
import CandelaKit
import SwiftUI

/// The AppKit island that hosts onboarding. An `LSUIElement` app has no
/// ordinary window scene, and a `Window` scene would be permanently listed in
/// the Window menu, so this is a plain `NSWindow` created on demand.
///
/// D14's load-bearing detail lives in `windowWillClose`: completion is recorded
/// when the window goes away — by the button, by ⌘W, or by the close button —
/// never at launch. Force-quitting mid-Setup therefore re-runs it, which the
/// fork could not do (it set `appAlreadyLaunched` two statements after
/// presenting the window).
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
  private let permission: AccessibilityPermission
  private let onCompletion: () -> Void
  /// Fires after the window closes ONLY when the close came from the footer's
  /// "Start Using …" button — the explicit "I'm done, show me the app" action.
  /// ⌘W and the red close button complete Setup (D14) but stay quiet: the
  /// user asked to dismiss a window, not to be handed a menu.
  var onFinishedByButton: (() -> Void)?
  private var closedByFinishButton = false
  /// Constructed once and reused, exactly like the window — and that is only
  /// safe because `isEnabled` is a LIVE read of `SMAppService.mainApp.status`
  /// (D10). This object holds no copy of the registration state, so there is
  /// nothing here to go stale after a settings reset unregisters the login
  /// item.
  private let loginItem = LoginItem()
  private var window: NSWindow?

  init(permission: AccessibilityPermission, onCompletion: @escaping () -> Void) {
    self.permission = permission
    self.onCompletion = onCompletion
    super.init()
  }

  func present() {
    let window = window ?? makeWindow()
    self.window = window
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
    // The call must also stay inside the click's event context — every
    // `DispatchQueue.main.async` variant lost the activation grant, and
    // neither `makeKeyAndOrderFront` nor `orderFrontRegardless` rescues it.
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    // D13 safety net: `recordCurrentVersion` is otherwise written ONLY from
    // `windowWillClose`. If presentation ever fails — an `LSUIElement` window
    // that will not order front, a future AppKit change — the version key
    // would never be written, the app would re-run Setup on every launch, and
    // `migrateIfNeeded` would never have a stored version to advance.
    // Recording it here in that case costs the (already broken) Setup window
    // and keeps the schema honest.
    if !window.isVisible {
      onCompletion()
    }
  }

  private func makeWindow() -> NSWindow {
    let hosting = NSHostingView(
      rootView: OnboardingView(
        loginItem: loginItem,
        permission: permission,
        onFinish: { [weak self] in
          self?.closedByFinishButton = true
          self?.window?.performClose(nil)
        }
      )
    )
    hosting.frame.size = hosting.fittingSize
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.contentView = hosting
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.isMovableByWindowBackground = true
    // Hidden in the titlebar, but still what VoiceOver and the Window menu
    // read — so it uses the user-facing name for this flow, "Setup".
    window.title = "\(AppInfo.productName) Setup"
    // Without this the window is deallocated on close and the next
    // `present()` messages freed memory.
    window.isReleasedWhenClosed = false
    window.delegate = self
    return window
  }

  func windowWillClose(_: Notification) {
    onCompletion()
    if closedByFinishButton {
      closedByFinishButton = false
      onFinishedByButton?()
    }
  }
}
