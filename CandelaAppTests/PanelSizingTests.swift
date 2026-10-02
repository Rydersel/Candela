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

  @Test func expandingKeepAwakeGrowsAShortPanelWithoutDiscardingTheDisplayViewport() async throws {
    let discovery = ScriptedDiscovery([(id: 7, key: "short-panel-sizing", name: "Single Display")])
    let model = TestFixtures.appModel(discovery: discovery)
    await model.refresh()
    _ = NSApplication.shared
    (NSApp as NSObject).accessibilitySetValue(true,
      forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let host = PanelHostingView(rootView: PanelView(maximumHeight: 700).environment(model))
    host.setFrameSize(host.fittingSize)
    let window = mount(host)
    defer { window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    let initialHeight = host.frame.height
    let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
    let originalViewport = scroll.contentView.bounds.height
    let disclosure = try #require(accessibilityNodes(host).first {
      ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake duration"
    })
    #expect(disclosure.object.accessibilityPerformPress?() == true)
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    #expect(host.frame.height > initialHeight + 60,
      "Expanded content must grow the host instead of consuming the short display viewport: \(initialHeight) -> \(host.frame.height), fitting \(host.fittingSize)")
    #expect(scroll.contentView.bounds.height >= originalViewport - 1)
    for label in ["Settings…", "Quit"] {
      let node = try #require(accessibilityNodes(host).first {
        ($0.object.accessibilityLabel?() ?? nil) == label
      })
      let frame = node.object.accessibilityFrame?() ?? .zero
      let hostFrame = host.convert(host.bounds, to: nil)
      let screenFrame = window.convertToScreen(hostFrame)
      #expect(screenFrame.contains(frame), "The entire footer button must remain inside the host")
    }
  }

  @Test func disclosureLayoutKeepsTheViewportUnderThePreviousHostHeight() async throws {
    let model = TestFixtures.appModel(discovery: ScriptedDiscovery([
      (id: 7, key: "stale-host-proposal", name: "Single Display")]))
    await model.refresh()
    _ = NSApplication.shared
    (NSApp as NSObject).accessibilitySetValue(true,
      forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    // A plain host deliberately keeps its old frame, reproducing the interval
    // between SwiftUI's state change and the native menu window's resize.
    let host = NSHostingView(rootView: PanelView(maximumHeight: 700).environment(model))
    host.sizingOptions = []
    host.setFrameSize(host.fittingSize)
    let window = mount(host)
    defer { window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    let originalHeight = host.frame.height
    let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
    let viewportHeight = scroll.contentView.bounds.height
    let disclosure = try #require(accessibilityNodes(host).first {
      ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake duration"
    })
    let headerFrame = try #require(disclosure.object.accessibilityFrame?())
    let brightness = try #require(accessibilityNodes(host).first {
      ($0.object.accessibilityLabel?() ?? nil)?.hasSuffix(" brightness") == true
    })
    let brightnessFrame = try #require(brightness.object.accessibilityFrame?())
    let headerGap = headerFrame.minY - brightnessFrame.minY
    #expect(disclosure.object.accessibilityPerformPress?() == true)
    try await Task.sleep(for: .milliseconds(250))
    host.layoutSubtreeIfNeeded()
    #expect(host.frame.height == originalHeight, "The test must retain the old native height")
    #expect(abs(scroll.contentView.bounds.height - viewportHeight) <= 1,
      "The old height proposal must not collapse the viewport")
    let current = try #require(accessibilityNodes(host).first {
      ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake duration"
    })
    let currentHeader = try #require(current.object.accessibilityFrame?())
    let currentBrightness = try #require(brightness.object.accessibilityFrame?())
    #expect(abs(currentHeader.minY - currentBrightness.minY - headerGap) <= 1,
      "The Keep Awake header must keep its position relative to the display content")
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["CANDELA_NATIVE_MENU_TEST"] == "1"),
    arguments: [(false, false), (false, true), (true, true)])
  func theTrackingMenuGrowsAndKeepsTheFooterVisible(withExternal: Bool, withBanner: Bool) async throws {
    let defaults = UserDefaults.standard
    let keys = ["keyboardBrightness", "keyboardVolume"]
    let saved = keys.map { defaults.object(forKey: $0) }
    defer {
      for (key, value) in zip(keys, saved) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
      }
    }
    let prefs = DisplayPrefs(persistenceKey: "app")
    prefs.keyboardBrightness = withBanner ? .media : .custom
    prefs.keyboardVolume = withBanner ? .media : .custom
    let model = TestFixtures.appModel(discovery: ScriptedDiscovery(withExternal ? [
      (id: 7, key: "native-disclosure-sizing", name: "Single Display")] : []))
    await model.refresh()
    _ = NSApplication.shared
    (NSApp as NSObject).accessibilitySetValue(true,
      forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    #expect(model.accessibility.isWarningWarranted == withBanner)
    let host = PanelHostingView(rootView: PanelRoot(model: model, updater: nil, maximumHeight: 700))
    host.configureDisclosures()
    host.setFrameSize(host.fittingSize)
    let item = NSMenuItem()
    item.view = host
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(item)
    let previousMenu = PanelMenu.menu
    PanelMenu.menu = menu
    PanelMenu.beginTracking()
    defer { PanelMenu.menu = previousMenu; model.endTimePicker.dismiss() }
    let result = TrackingResult(menu: menu)
    // Timers run inside AppKit's tracking loop, where a main-actor Task cannot.
    let timer = Timer(timeInterval: 0.016, repeats: true) { _ in
      MainActor.assumeIsolated {
        if Date() > result.deadline {
          result.error = "The native menu did not complete its disclosure checks"
          result.didCheck = true
          result.timer?.invalidate(); result.menu.cancelTracking(); return
        }
        if result.phase == 0 {
          guard let window = host.window, window.isVisible else { return }
          if result.openedAt == nil { result.openedAt = Date(); return }
          guard Date().timeIntervalSince(result.openedAt!) >= 0.3 else { return }
          result.pinnedControlBaseline = Dictionary(uniqueKeysWithValues: accessibilityNodes(host).compactMap { node in
            guard let label = node.object.accessibilityLabel?(), (label.hasSuffix(" brightness") || label == "Keep display awake duration" || label == "Keep display awake"),
                  let frame = node.object.accessibilityFrame?(), !frame.isEmpty else { return nil }
            return (label, frame)
          })
          result.originalHeight = window.frame.height
          result.originalWindow = window
          result.originalTop = window.frame.maxY
          result.phase = 1
          guard let disclosure = accessibilityNodes(host).first(where: {
            ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake duration"
          }) else {
            result.error = "The live menu did not publish its disclosure"
            result.didCheck = true
            result.timer?.invalidate(); result.menu.cancelTracking(); return
          }
          result.pressed = disclosure.object.accessibilityPerformPress?() == true
        } else if result.phase == 1 {
          result.samplePinnedControls(nodes: accessibilityNodes(host))
          guard let window = host.window, window.isVisible else { return }
          result.sameWindow = window === result.originalWindow
          result.heights.append(window.frame.height)
          result.topStayedFixed = result.topStayedFixed && abs(window.frame.maxY - result.originalTop) <= 1
          if result.expandedVisibleSince == nil { result.expandedVisibleSince = Date(); return }
          guard Date().timeIntervalSince(result.expandedVisibleSince!) >= 0.75 else { return }
          result.expandedHeight = window.frame.height
          result.footersVisible = ["Settings…", "Quit"].allSatisfy { label in
            guard let node = accessibilityNodes(host).first(where: {
              ($0.object.accessibilityLabel?() ?? nil) == label
            }) else { return false }
            let frame = node.object.accessibilityFrame?() ?? .zero
            return !frame.isEmpty && window.frame.contains(frame)
          }
          result.pinnedControlsVisible = result.pinnedControlBaseline.keys.allSatisfy { label in
            accessibilityNodes(host).contains {
              ($0.object.accessibilityLabel?() ?? nil) == label &&
                window.frame.contains($0.object.accessibilityFrame?() ?? .zero)
            }
          }
          result.phase = 2
          result.phaseStarted = Date()
          let disclosure = accessibilityNodes(host).first {
            ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake duration"
          }
          _ = disclosure?.object.accessibilityPerformPress?()
        } else if result.phase == 2 {
          result.samplePinnedControls(nodes: accessibilityNodes(host))
          guard Date().timeIntervalSince(result.phaseStarted!) >= 0.35 else { return }
          result.collapsedHeight = host.window?.frame.height ?? 0
          result.sliderAbsentAfterCollapse = !accessibilityNodes(host).contains {
            ($0.object.accessibilityLabel?() ?? nil) == "Keep awake duration"
          }
          result.phase = 3
          result.phaseStarted = Date()
          let disclosure = accessibilityNodes(host).first {
            ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake duration"
          }
          _ = disclosure?.object.accessibilityPerformPress?()
        } else if result.phase == 3 {
          result.samplePinnedControls(nodes: accessibilityNodes(host))
          guard Date().timeIntervalSince(result.phaseStarted!) >= 0.35 else { return }
          guard let custom = accessibilityNodes(host).first(where: {
            ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake, Custom end time…"
          }) else {
            result.error = "The expanded menu did not publish its custom end-time action"
            result.didCheck = true
            result.timer?.invalidate(); result.menu.cancelTracking(); return
          }
          result.phase = 4
          result.customPressed = custom.object.accessibilityPerformPress?() == true
        } else {
          guard NSApp.windows.contains(where: { $0.title == "Keep Display Awake" && $0.isVisible }) else { return }
          if result.pickerVisibleSince == nil { result.pickerVisibleSince = Date(); return }
          guard Date().timeIntervalSince(result.pickerVisibleSince!) >= 0.75 else { return }
          result.didCheck = true
          result.menuClosedForPicker = host.window?.isVisible != true
          result.timer?.invalidate(); result.menu.cancelTracking()
        }
      }
    }
    result.timer = timer
    RunLoop.main.add(timer, forMode: .eventTracking)
    RunLoop.main.add(timer, forMode: .default)
    defer { timer.invalidate(); result.timer = nil; menu.cancelTracking() }
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    menu.popUp(positioning: nil, at: NSPoint(x: screen.minX + 30, y: screen.maxY - 50), in: nil)
    while !result.didCheck && Date() <= result.deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(result.didCheck)
    #expect(result.error == nil)
    #expect(result.pressed)
    #expect(result.originalHeight > 0)
    #expect(result.expandedHeight > result.originalHeight + 60,
      "The actual tracking window must grow: \(result.originalHeight) -> \(result.expandedHeight)")
    #expect(result.footersVisible)
    #expect(result.sameWindow, "A disclosure must not replace its tracking window")
    #expect(result.pinnedControlsVisible)
    #expect(!result.pinnedControlBaseline.isEmpty)
    #expect(result.maximumPinnedMovement <= 1,
      "Existing controls must remain anchored; maximum movement was \(result.maximumPinnedMovement) points")
    print("Native disclosure withExternal=\(withExternal) withBanner=\(withBanner): anchored controls movement=\(result.maximumPinnedMovement), height=\(result.originalHeight)->\(result.expandedHeight)->\(result.collapsedHeight)")
    #expect(result.topStayedFixed, "The menu top must remain at \(result.originalTop)")
    #expect(abs(result.collapsedHeight - result.originalHeight) <= 1,
      "The collapsed window must return to \(result.originalHeight), got \(result.collapsedHeight), expanded \(result.expandedHeight)")
    #expect(result.sliderAbsentAfterCollapse)
    if !Motion.systemReduceMotion {
      #expect(result.heights.contains { $0 > result.originalHeight + 1 && $0 < result.expandedHeight - 1 },
        "The window must pass through intermediate sizes")
    }
    #expect(result.customPressed)
    #expect(result.menuClosedForPicker, "Opening the picker must not reopen the compact menu")
  }

  @MainActor private final class TrackingResult {
    let menu: NSMenu
    var timer: Timer?
    init(menu: NSMenu) { self.menu = menu }
    let deadline = Date().addingTimeInterval(5)
    var phase = 0
    var openedAt: Date?
    var pinnedControlBaseline: [String: NSRect] = [:]
    var maximumPinnedMovement: CGFloat = 0
    func samplePinnedControls(nodes: [Node]) {
      for node in nodes {
        guard let label = node.object.accessibilityLabel?(), let baseline = pinnedControlBaseline[label],
              let frame = node.object.accessibilityFrame?() else { continue }
        let differences = [abs(frame.minX - baseline.minX), abs(frame.minY - baseline.minY),
          abs(frame.width - baseline.width), abs(frame.height - baseline.height)]
        let movement = differences.max() ?? 0
        maximumPinnedMovement = max(maximumPinnedMovement, movement)
      }
    }
    var originalHeight: CGFloat = 0
    var expandedHeight: CGFloat = 0
    var originalWindow: NSWindow?
    var sameWindow = false
    var originalTop: CGFloat = 0
    var topStayedFixed = true
    var pinnedControlsVisible = false
    var collapsedHeight: CGFloat = 0
    var sliderAbsentAfterCollapse = false
    var phaseStarted: Date?
    var heights: [CGFloat] = []
    var expandedVisibleSince: Date?
    var pickerVisibleSince: Date?
    var customPressed = false
    var menuClosedForPicker = false
    var pressed = false
    var footersVisible = false
    var error: String?
    var didCheck = false
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
