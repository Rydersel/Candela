import AppKit
import CandelaKit
import SwiftUI
import Testing

/// Native hosting is required: ImageRenderer leaves ScrollView contents blank
/// on macOS. These checks cover layout and the published accessibility tree;
/// scroll-wheel delivery during real menu tracking remains an interactive check.
@Suite("Panel sizing") @MainActor
struct PanelSizingTests {
  @Test(arguments: [false, true])
  func returningToNaturalHeightKeepsTheDisplayContentMounted(scrolled: Bool) async throws {
    let model = await populatedModel()
    let host = PanelHostingView(rootView: PanelView(maximumHeight: 400).environment(model))
    host.setFrameSize(host.fittingSize)
    let window = mount(host)
    defer { window.contentView = nil; window.close() }
    await settleScrollContent(host)
    let original = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
    let document = try #require(original.documentView)
    if scrolled {
      original.contentView.scroll(to: NSPoint(
        x: 0, y: document.bounds.height - original.contentView.bounds.height))
      original.reflectScrolledClipView(original.contentView)
      #expect(original.contentView.bounds.minY > 0)
    }

    // Crossing the scroll threshold must not replace the display hierarchy
    // while a disclosure is animating its rows out.
    host.rootView = PanelView(maximumHeight: 2000).environment(model)
    host.setFrameSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let current = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
    #expect(current === original)
    #expect(current.documentView === document)
    #expect(document.frame.height <= current.contentView.bounds.height + 1)
    #expect(abs(current.contentView.bounds.minY) <= 1)
  }

  @Test func aLongDisplayListScrollsWithinTheHeightBudget() async throws {
    let model = await populatedModel()
    let host = PanelHostingView(rootView: PanelView(maximumHeight: 400).environment(model))
    host.setFrameSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    #expect(host.frame.width == 280)
    #expect(host.frame.height <= 400)
    let window = mount(host)
    defer { window.contentView = nil; window.close() }
    await settleScrollContent(host)
    let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
    let document = try #require(scroll.documentView)
    #expect(document.frame.height > scroll.contentView.bounds.height)
    #expect(scroll.contentView.bounds.height > 100)
  }

  @Test func aShortPanelKeepsItsNaturalHeight() {
    let model = TestFixtures.appModel()
    let natural = NSHostingView(rootView: PanelView().environment(model))
    let bounded = PanelHostingView(rootView: PanelView(maximumHeight: 700).environment(model))
    #expect(natural.fittingSize == bounded.fittingSize)
    bounded.setFrameSize(bounded.fittingSize)
    bounded.layoutSubtreeIfNeeded()
    #expect(bounded.frame.height < 700)
  }

  @Test func theSameHostAdaptsToEachOpeningHeight() async {
    let model = await populatedModel()
    let host = PanelHostingView(rootView: PanelView().environment(model))
    let naturalHeight = host.fittingSize.height
    #expect(naturalHeight > 600)
    for height in [CGFloat(400), 600, 300, 2000] {
      host.rootView = PanelView(maximumHeight: height).environment(model)
      host.setFrameSize(host.fittingSize)
      host.layoutSubtreeIfNeeded()
      #expect(abs(host.frame.height - min(height, naturalHeight)) <= 1)
    }
  }

  @Test(arguments: [false, true])
  func scrollingLeavesFooterAndPersistentControlsInPlace(withReminder: Bool) async throws {
    let model = await populatedModel()
    _ = NSApplication.shared
    (NSApp as NSObject).accessibilitySetValue(
      true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let reminder = UpdateReminderState()
    let host = PanelHostingView(rootView: PanelView(maximumHeight: 400)
      .environment(model).environment(reminder))
    host.setFrameSize(host.fittingSize)
    let window = mount(host)
    defer { window.contentView = nil; window.close() }
    host.layoutSubtreeIfNeeded()

    await settleScrollContent(host)
    let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
    let initialViewportHeight = scroll.contentView.bounds.height
    if withReminder {
      reminder.willShowUpdate(version: "1.0.5", userInitiated: false, handledByStandardDriver: false)
      reminder.freezeForMenuOpen()
      // The same synchronous root update and fitting-size read as menuWillOpen,
      // after a marker arrives for the next opening. No Sparkle service starts.
      host.rootView = PanelView(maximumHeight: 400).environment(model).environment(reminder)
      host.setFrameSize(host.fittingSize)
      host.layoutSubtreeIfNeeded()
      #expect(scroll.contentView.bounds.height < initialViewportHeight)
    }
    #expect(host.frame.height <= 400)
    let nodes = accessibilityNodes(host)
    var labels = ["Settings…", "Quit"]
    if withReminder { labels.append("Show Update") }
    if PanelView.showsKeepAwake(appPrefs: DisplayPrefs(persistenceKey: "app")) {
      labels.append("Keep display awake")
    }
    if model.accessibility.isWarningWarranted { labels.append("Open Settings…") }
    let pinned = try labels.map { label in
      let node = try #require(nodes.first {
        !$0.inScrollArea && ($0.object.accessibilityLabel?() ?? nil) == label
      }, "\(label) must be outside the scrolling display list")
      let frame = node.object.accessibilityFrame?() ?? .zero
      #expect(!frame.isEmpty)
      return (node.object, frame)
    }
    let document = try #require(scroll.documentView)
    scroll.contentView.scroll(to: NSPoint(
      x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(scroll.contentView.bounds.minY > 0)
    for (object, frame) in pinned {
      #expect(object.accessibilityFrame?() == frame)
    }
  }

  private func mount(_ host: NSView) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    return window
  }

  private func settleScrollContent(_ host: NSView) async {
    for _ in 0..<50 {
      host.layoutSubtreeIfNeeded()
      if let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
        let document = scroll.documentView,
        document.frame.height > scroll.contentView.bounds.height {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func populatedModel() async -> AppModel {
    let discovery = ScriptedDiscovery((2...11).map {
      (id: CGDirectDisplayID($0), key: "sizing-panel-\($0)", name: "Sizing Panel \($0)")
    })
    let model = TestFixtures.appModel(discovery: discovery)
    await model.refresh()
    #expect(model.displays.count == 10)
    return model
  }

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private struct Node {
    let object: AnyObject
    let inScrollArea: Bool
  }

  private func accessibilityNodes(_ element: Any, inScrollArea: Bool = false, depth: Int = 0) -> [Node] {
    guard depth < 30 else { return [] }
    let object = element as AnyObject
    let scrolling = inScrollArea || (object.accessibilityRole?() ?? nil) == .scrollArea
    let children = (object.accessibilityChildren?() ?? nil) ?? []
    return [Node(object: object, inScrollArea: scrolling)] + children.flatMap {
      accessibilityNodes($0, inScrollArea: scrolling, depth: depth + 1)
    }
  }
}
