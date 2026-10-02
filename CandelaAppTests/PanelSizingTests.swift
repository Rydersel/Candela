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
    EnhancedAccessibility.enable()
    defer { EnhancedAccessibility.disable() }
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
      ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake options"
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
    EnhancedAccessibility.enable()
    defer { EnhancedAccessibility.disable() }
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
      ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake options"
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
      ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake options"
    })
    let currentHeader = try #require(current.object.accessibilityFrame?())
    let currentBrightness = try #require(brightness.object.accessibilityFrame?())
    #expect(abs(currentHeader.minY - currentBrightness.minY - headerGap) <= 1,
      "The Keep Awake header must keep its position relative to the display content")
  }

  /// Opt-in: runs only with `CANDELA_NATIVE_MENU_TEST=1` in the test
  /// environment. It pops up a real `NSMenu` and runs AppKit's tracking loop,
  /// which takes the screen and the pointer's menu for several seconds, so it
  /// cannot run unattended in `make check` or CI. The controller runs it by hand
  /// before a release.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CANDELA_NATIVE_MENU_TEST"] == "1"),
    arguments: [(false, false), (false, true), (true, true)])
  func theTrackingMenuGrowsAndKeepsTheFooterVisible(withExternal: Bool, withBanner: Bool) async throws {
    let mode = (withBanner ? KeyMode.media : .custom).rawValue
    let keys = ["keyboardBrightness", "keyboardVolume"]
    VolatilePrefs.set(Dictionary(uniqueKeysWithValues: keys.map { ($0, mode) }))
    defer { VolatilePrefs.remove(keys) }
    let model = TestFixtures.appModel(discovery: ScriptedDiscovery(withExternal ? [
      (id: 7, key: "native-disclosure-sizing", name: "Single Display")] : []))
    await model.refresh()
    EnhancedAccessibility.enable()
    defer { EnhancedAccessibility.disable() }
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
            guard let label = node.object.accessibilityLabel?(), (label.hasSuffix(" brightness") || label == "Keep display awake options" || label == "Keep display awake"),
                  let frame = node.object.accessibilityFrame?(), !frame.isEmpty else { return nil }
            return (label, frame)
          })
          result.originalHeight = window.frame.height
          result.originalWindow = window
          result.originalTop = window.frame.maxY
          result.phase = 1
          guard let disclosure = accessibilityNodes(host).first(where: {
            ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake options"
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
            ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake options"
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
            ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake options"
          }
          _ = disclosure?.object.accessibilityPerformPress?()
        } else if result.phase == 3 {
          result.samplePinnedControls(nodes: accessibilityNodes(host))
          guard Date().timeIntervalSince(result.phaseStarted!) >= 0.35 else { return }
          guard let custom = accessibilityNodes(host).first(where: {
            ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake, Custom End Time…"
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

  // MARK: - One-line rows

  private static func textWidth(_ text: String, size: CGFloat) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width
  }

  /// Every end time a deadline up to a year away can produce, each day at the
  /// widest clock reading: the day and the time are separate words, so their
  /// widest forms add.
  private static func widestEndTimes(size: CGFloat, render: (Date) -> String) -> String {
    let clock = PanelRowModelTests.clock
    let start = clock.calendar.startOfDay(for: clock.now)
    let minutes = (0 ..< 24 * 60).map { start.addingTimeInterval(TimeInterval($0 * 60)) }
    let widestTime = minutes.max {
      textWidth(render($0), size: size) < textWidth(render($1), size: size)
    }!
    let offset = widestTime.timeIntervalSince(start)
    let days = (0 ... 366).map {
      clock.calendar.date(byAdding: .day, value: $0, to: start)!.addingTimeInterval(offset)
    }
    return days.map(render).max { textWidth($0, size: size) < textWidth($1, size: size) }!
  }

  /// The row's height must never change with state (the footer clip of
  /// 2026-08-19), so its widest label has to fit beside the switch on one line.
  /// The column is measured from the laid-out row, not assumed.
  @Test func theWidestKeepAwakeLabelFitsOneLine() async throws {
    let model = TestFixtures.appModel()
    EnhancedAccessibility.enable()
    defer { EnhancedAccessibility.disable() }
    let host = PanelHostingView(rootView: PanelView(maximumHeight: 700).environment(model))
    host.setFrameSize(host.fittingSize)
    let window = mount(host)
    defer { window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    let nodes = accessibilityNodes(host)
    let button = try #require(nodes.first {
      ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake options"
    }?.object.accessibilityFrame?())
    let toggle = try #require(nodes.first {
      ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake"
    }?.object.accessibilityFrame?())
    let size = PanelView.keepAwakeFontSize
    let chrome = button.width - Self.textWidth(PanelView.keepAwakeTitle(expiresAt: nil), size: size)
    let column = toggle.minX - 8 - button.minX - chrome
    let clock = PanelRowModelTests.clock
    let widest = Self.widestEndTimes(size: size) {
      PanelView.keepAwakeTitle(expiresAt: $0, now: clock.now, calendar: clock.calendar, locale: clock.locale)
    }
    #expect(column > 100, "The measured column is implausible: \(column)")
    #expect(Self.textWidth(widest, size: size) <= column,
      "\"\(widest)\" needs \(Self.textWidth(widest, size: size)) pt in a \(column) pt column")
  }

  /// Measured with a five-figure hour count so the test still holds if the
  /// paused form ever takes the hours back.
  @Test func theWidestPausedCareLineFitsOneLine() async throws {
    let key = "paused-care-width-\(UUID().uuidString)"
    VolatilePrefs.set(["oledCareEnrolled.\(key)": true])
    defer { VolatilePrefs.remove(["oledCareEnrolled.\(key)"]) }
    let name = "Paused Width"
    let model = TestFixtures.appModel(discovery: ScriptedDiscovery([(id: 7, key: key, name: name)]))
    await model.refresh()
    EnhancedAccessibility.enable()
    defer { EnhancedAccessibility.disable() }
    let host = PanelHostingView(rootView: PanelView(maximumHeight: 700).environment(model))
    host.setFrameSize(host.fittingSize)
    let window = mount(host)
    defer { window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    let row = try #require(accessibilityNodes(host).first {
      ($0.object.accessibilityLabel?() ?? nil) == "\(name) dimming controls"
    }?.object.accessibilityFrame?())
    let chevron = try #require(NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))).size.width
    // The status, the 6 pt gap, the 4 pt minimum spacer and the chevron.
    let column = row.width - 6 - 4 - chevron
    let clock = PanelRowModelTests.clock
    let widest = Self.widestEndTimes(size: 11) {
      PanelView.careLine(
        enrolled: true, hours: 99_999, summary: nil, safeMode: false, suspended: false,
        pausedUntil: $0, now: clock.now, calendar: clock.calendar, locale: clock.locale) ?? ""
    }
    #expect(column > 100, "The measured column is implausible: \(column)")
    #expect(Self.textWidth(widest, size: 11) <= column,
      "\"\(widest)\" needs \(Self.textWidth(widest, size: 11)) pt in a \(column) pt column")
  }

  /// The native slider is its own accessibility element, so the label and the
  /// spoken stop have to be set on it; a SwiftUI modifier on the representable
  /// is not proof they arrive.
  @Test func theDurationSliderSpeaksTheStopNotItsIndex() async throws {
    var value = 2.0
    let binding = Binding(get: { value }, set: { value = $0 })
    let host = NSHostingView(rootView: SelectionSlider(
      value: binding, stopCount: KeepAwakeDuration.allCases.count,
      accessibilityLabel: "Keep awake duration", valueDescription: PanelView.keepAwakeStopTitle))
    host.setFrameSize(NSSize(width: 200, height: 24))
    let window = mount(host)
    defer { window.contentView = nil; window.close() }
    host.layoutSubtreeIfNeeded()
    let control = try #require(descendants(host).compactMap { $0 as? NSSlider }.first)
    let slider = try #require(control.cell)
    #expect(slider.accessibilityLabel() == "Keep awake duration")
    #expect(slider.accessibilityValueDescription() == "1 hour")
    value = 5
    host.rootView = SelectionSlider(
      value: binding, stopCount: KeepAwakeDuration.allCases.count,
      accessibilityLabel: "Keep awake duration", valueDescription: PanelView.keepAwakeStopTitle)
    host.layoutSubtreeIfNeeded()
    #expect(slider.accessibilityValueDescription() == "8 hours")
  }

  @Test func theOpenedKeepAwakeRowPublishesOneSpokenSlider() async throws {
    let model = TestFixtures.appModel()
    EnhancedAccessibility.enable()
    defer { EnhancedAccessibility.disable() }
    let host = PanelHostingView(rootView: PanelView(maximumHeight: 700).environment(model))
    host.setFrameSize(host.fittingSize)
    let window = mount(host)
    defer { window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    let disclosure = try #require(accessibilityNodes(host).first {
      ($0.object.accessibilityLabel?() ?? nil) == "Keep display awake options"
    })
    #expect((disclosure.object as? NSAccessibilityElementProtocol).flatMap {
      ($0 as AnyObject).accessibilityValue() as? String
    } == "Off, collapsed")
    #expect(disclosure.object.accessibilityPerformPress?() == true)
    try await Task.sleep(for: .milliseconds(300))
    host.setFrameSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    let sliders = accessibilityNodes(host).filter {
      ($0.object.accessibilityRole?() ?? nil) == .slider
    }
    #expect(sliders.count == 1)
    #expect((sliders.first?.object.accessibilityLabel?() ?? nil) == "Keep awake duration")
    #expect((sliders.first?.object.accessibilityValueDescription?() ?? nil)
      == KeepAwakeDuration.untilTurnedOff.title)
    #expect(!model.keepAwake.isOn, "Opening the duration choices must not start a hold")
  }

  // MARK: - The care disclosure

  private func carePanel(
    enrolled: Bool, safeMode: Bool, paused: Bool = false
  ) async throws -> (nodes: () -> [Node], host: NSView, model: AppModel, close: () -> Void) {
    let key = "care-disclosure-\(UUID().uuidString)"
    if enrolled { VolatilePrefs.set(["oledCareEnrolled.\(key)": true]) }
    let model = TestFixtures.appModel(
      discovery: ScriptedDiscovery([(id: 7, key: key, name: Self.careName)]), safeMode: safeMode)
    await model.refresh()
    if paused { model.oledCare.pauseDimming(for: key, duration: 15 * 60) }
    let host = PanelHostingView(rootView: PanelView(maximumHeight: 700).environment(model))
    host.setFrameSize(host.fittingSize)
    let window = mount(host)
    try await Task.sleep(for: .milliseconds(150))
    host.layoutSubtreeIfNeeded()
    return ({ self.accessibilityNodes(host) }, host, model, {
      model.oledCare.resumeDimming(for: key)
      VolatilePrefs.remove(["oledCareEnrolled.\(key)"])
      window.contentView = nil
      window.close()
    })
  }

  private static let careName = "Care Rows"

  private static func labels(_ nodes: [Node]) -> Set<String> {
    Set(nodes.compactMap { $0.object.accessibilityLabel?() ?? nil })
  }

  @Test(arguments: [false, true])
  func anEnrolledDisplaysCareLineOpensToItsPauseRows(paused: Bool) async throws {
    EnhancedAccessibility.enable()
    defer { EnhancedAccessibility.disable() }
    let panel = try await carePanel(enrolled: true, safeMode: false, paused: paused)
    defer { panel.close() }
    let rows = PanelView.careActions(enrolled: true, safeMode: false, paused: paused)
      .map { "\(Self.careName), \($0.title)" }
    #expect(Self.labels(panel.nodes()).isDisjoint(with: rows), "Closed, the rows are absent")
    let disclosure = try #require(panel.nodes().first {
      ($0.object.accessibilityLabel?() ?? nil) == "\(Self.careName) dimming controls"
    })
    #expect(disclosure.object.accessibilityPerformPress?() == true)
    try await Task.sleep(for: .milliseconds(300))
    panel.host.setFrameSize(panel.host.fittingSize)
    panel.host.layoutSubtreeIfNeeded()
    let open = Self.labels(panel.nodes())
    for row in rows { #expect(open.contains(row), "\(row) is missing") }
    #expect(open.contains("\(Self.careName), Resume Now") == paused)
  }

  /// No disclosure where there is no dimming to pause. Safe Mode leaves the
  /// line itself to the hours, which a fresh key has none of.
  @Test(arguments: [(false, false), (true, true)])
  func theCareLineIsNotAControlWhereNothingDims(enrolled: Bool, safeMode: Bool) async throws {
    EnhancedAccessibility.enable()
    defer { EnhancedAccessibility.disable() }
    let panel = try await carePanel(enrolled: enrolled, safeMode: safeMode)
    defer { panel.close() }
    let labels = Self.labels(panel.nodes())
    #expect(!labels.contains("\(Self.careName) dimming controls"))
    #expect(!labels.contains { $0.hasPrefix("\(Self.careName), Pause Dimming") })
    #expect(labels.contains("\(Self.careName) brightness"), "The display's section rendered")
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
    EnhancedAccessibility.enable()
    defer { EnhancedAccessibility.disable() }
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

/// The panel and the accessibility predicate read `UserDefaults.standard` with
/// no seam to inject through. The argument domain is volatile and outranks the
/// app's own domain, so a value placed there reads like a stored pref and never
/// reaches disk. Removal is per key rather than a restore of a saved copy, so
/// two tests interleaving on the main actor cannot undo each other.
@MainActor enum VolatilePrefs {
  static func set(_ values: [String: Any]) {
    mutate { domain in domain.merge(values) { $1 } }
  }

  static func remove(_ keys: [String]) {
    mutate { domain in for key in keys { domain.removeValue(forKey: key) } }
  }

  private static func mutate(_ change: (inout [String: Any]) -> Void) {
    let defaults = UserDefaults.standard
    let name = UserDefaults.argumentDomain
    var domain = defaults.volatileDomain(forName: name)
    change(&domain)
    defaults.removeVolatileDomain(forName: name)
    defaults.setVolatileDomain(domain, forName: name)
  }
}

/// Set so SwiftUI publishes its accessibility tree to the in-process walks
/// these tests make. It is one process-wide flag, and the walks sleep on the
/// main actor while it is on, so another suite can run in that gap: enables
/// are counted, and only the last disable puts the flag back as it was found.
@MainActor enum EnhancedAccessibility {
  private static let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
  private static var holders = 0
  private static var prior = false

  static func enable() {
    _ = NSApplication.shared
    if holders == 0 {
      prior = ((NSApp as NSObject).accessibilityAttributeValue(attribute) as? Bool) ?? false
      (NSApp as NSObject).accessibilitySetValue(true, forAttribute: attribute)
    }
    holders += 1
  }

  static func disable() {
    guard holders > 0 else { return }
    holders -= 1
    if holders == 0 {
      (NSApp as NSObject).accessibilitySetValue(prior, forAttribute: attribute)
    }
  }
}
