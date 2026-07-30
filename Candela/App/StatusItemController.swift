import AppKit
import CandelaKit
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
  private let model = AppModel()
  private var statusItem: NSStatusItem?

  func applicationDidFinishLaunching(_: Notification) {
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
    statusItem = item

    // Warm the display list before the first open. Menu tracking can hold the
    // main run loop in event-tracking mode, which starves main-actor task
    // execution (see BrightnessController.setBrightness), so a refresh cannot
    // be relied on to land while the menu is open. Launch here and close
    // below are therefore the only two refresh triggers; AppModel.refresh()
    // coalesces overlapping calls, so they never race the DDC bus.
    Task { await model.refresh() }
  }

  func menuDidClose(_: NSMenu) {
    // Re-discover displays and re-read hardware once tracking has ended and
    // the run loop is back in default mode, so the next open starts fresh.
    Task { await model.refresh() }
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
