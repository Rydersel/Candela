import AppKit
import CandelaKit
import SwiftUI

/// Presents Display Health windows (OCR-A1, #185) as an AppKit island, the
/// pattern `StatusItemController` already holds for the confirmation windows.
///
/// NOT a SwiftUI `WindowGroup`: adding one to this LSUIElement app changed
/// PLAIN launch behavior, opening the settings window where a control build
/// opened nothing [MEASURED 2026-08-17, control-verified against the
/// pre-#185 installed build], and the API that would suppress that
/// (`defaultLaunchBehavior(.suppressed)`) does not exist at the macOS 14
/// floor (§4). An NSWindow made on demand changes nothing at launch by
/// construction.
///
/// One window per persistence key: `open(key:)` re-focuses an existing
/// window rather than duplicating it, and the in-window display switcher
/// re-keys its window so the map keeps one surface per display. Windows are
/// non-resizable by the user; `NSHostingView.sizingOptions =
/// .preferredContentSize` sizes each to its SwiftUI content and follows the
/// switcher's shape changes, which is the whole point of the window: a
/// portrait display's map gets a portrait window.
@MainActor
final class DisplayHealthWindowPresenter {
  private let model: AppModel
  private var windows: [String: NSWindow] = [:]
  private var closeObservers: [ObjectIdentifier: any NSObjectProtocol] = [:]

  init(model: AppModel) {
    self.model = model
  }

  func open(key: String) {
    if let existing = windows[key] {
      existing.makeKeyAndOrderFront(nil)
      return
    }
    let window = NSWindow(
      contentRect: .zero,
      // No `.resizable`: the window's size IS the content's, and a free
      // resize would fight `preferredContentSize` sizing.
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered, defer: false)
    window.title = "Display Health"
    // Dark-only (SV2), on the WINDOW and not just in SwiftUI: the titlebar,
    // the traffic lights and the AppKit-drawn controls inside (the display
    // switcher, the lens picker) take their look from the window's
    // appearance, and a light titlebar over the page's canvas is the seam
    // this window is opened from settings to avoid.
    window.appearance = NSAppearance(named: .darkAqua)
    // State restoration would resurrect the window at the next launch with
    // no display resolution having run, the unprompted-window defect class.
    window.isRestorable = false
    // We own the lifetime through `windows`; AppKit must not deallocate a
    // closed window out from under the dictionary prune.
    window.isReleasedWhenClosed = false

    let root = DisplayHealthWindowRoot(
      initialKey: key,
      // The root resolves its key each render and closes on departure; the
      // window is the thing that closes, and the prune below follows.
      close: { [weak window] in window?.close() },
      // The switcher repoints THIS window; the dictionary follows so a later
      // `open(key:)` finds the truth.
      rekey: { [weak self, weak window] old, new in
        guard let self, let window else { return }
        self.rekey(window: window, from: old, to: new)
      })
    let hosting = NSHostingView(
      // The same environment the settings scene applies, or the health view
      // renders without its model.
      rootView: root
        .environment(model)
    )
    hosting.sizingOptions = [.preferredContentSize]
    window.contentView = hosting
    window.setContentSize(hosting.fittingSize)
    window.center()

    windows[key] = window
    // Prune by window identity, not by key: the switcher can have re-keyed
    // the window since it opened.
    let token = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] notification in
      guard let closing = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        self?.prune(window: closing)
      }
    }
    closeObservers[ObjectIdentifier(window)] = token

    window.makeKeyAndOrderFront(nil)
  }

  /// The in-window switcher moved `window` from one display to another. If
  /// the target display already has its own window, that one closes: the
  /// user deliberately steered THIS window there, and two windows on one
  /// display's map is what the one-per-key rule exists to prevent.
  private func rekey(window: NSWindow, from old: String, to new: String) {
    if let occupying = windows[new], occupying !== window {
      occupying.close()
    }
    if windows[old] === window {
      windows[old] = nil
    }
    windows[new] = window
  }

  private func prune(window: NSWindow) {
    windows = windows.filter { $0.value !== window }
    if let token = closeObservers.removeValue(forKey: ObjectIdentifier(window)) {
      NotificationCenter.default.removeObserver(token)
    }
  }
}
