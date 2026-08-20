#if DEBUG
  import AppKit
  import SwiftUI

  /// Stage 1's window (OB11): the real flow view over the rig fixture, all
  /// commits recorded rather than written, permission asks simulated so every
  /// page state is clickable. Presented only by the debug hook; compiled out
  /// of Release by construction like the rest of the hook family.
  @MainActor
  enum OnboardingMockPresenter {
    private static var window: NSWindow?

    static func present() {
      let model = OnboardingFlowModel(environment: OnboardingFixtures.rig)
      // Simulated grant: the real prompt cannot be shown twice per process
      // and the mock must be re-runnable, so the grant just lands after a
      // beat, long enough to see the requested state.
      model.onRequestAccessibility = {
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(1.4))
          model.accessibilityGranted = true
        }
      }
      model.onOpenAccessibilitySettings = {
        model.accessibilityGranted = true
      }
      model.onClose = {
        Self.window?.close()
      }

      let hosting = NSHostingController(rootView: OnboardingFlowView(model: model))
      let window = NSWindow(contentViewController: hosting)
      window.styleMask = [.titled, .closable, .fullSizeContentView]
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.isMovableByWindowBackground = true
      window.title = "\(AppInfo.productName) Setup (Mock)"
      window.appearance = NSAppearance(named: .darkAqua)
      window.isReleasedWhenClosed = false
      window.setContentSize(NSSize(width: 760, height: 560))
      window.center()
      Self.window = window
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    }
  }
#endif
