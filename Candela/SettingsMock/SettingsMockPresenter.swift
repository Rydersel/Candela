#if DEBUG
  import AppKit
  import SwiftUI

  /// Presents the settings visual mock in its own always-dark window, the
  /// OnboardingMockPresenter shape: presented only by the debug hook,
  /// compiled out of Release by construction like the rest of the family.
  /// Nothing in the mock reads or writes real state.
  @MainActor
  enum SettingsMockPresenter {
    private static var window: NSWindow?

    static func present() {
      let hosting = NSHostingController(rootView: SettingsMockShell())
      let window = NSWindow(contentViewController: hosting)
      window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.isMovableByWindowBackground = true
      window.title = "\(AppInfo.productName) Settings (Mock)"
      window.appearance = NSAppearance(named: .darkAqua)
      window.isReleasedWhenClosed = false
      window.setContentSize(NSSize(width: 1100, height: 680))
      window.center()
      Self.window = window
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    }
  }
#endif
