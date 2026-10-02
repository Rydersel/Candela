import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Opt-in evidence for ImageRenderer's intermittent glyph movement; differences
/// are recorded, never absorbed by a tolerance or warm-up rule.
///
/// Runs only with `CANDELA_RENDER_PROBE_DIR` set to a writable directory. The
/// tests open windows and write captures for a person to review, so they prove
/// nothing unattended and stay out of `make check` and CI. Run them by hand
/// before a release.
@Suite("Panel render probe") @MainActor
struct PanelRenderProbeTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CANDELA_RENDER_PROBE_DIR"] != nil))
  func captureConsecutivePanels() throws {
    let directory = URL(fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["CANDELA_RENDER_PROBE_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let view = PanelView().environment(TestFixtures.appModel())
    // Preserve the original probe's renderer lifetime. Keeping each renderer
    // alive or eagerly copying its pixels would test a different hypothesis.
    let images = try (0 ..< 4).map { _ in try render(view) }
    let bytes = try images.map(rgba)
    var comparisons: [[String: Any]] = []
    for index in 1 ..< images.count {
      try #require(images[index].width == images[0].width && images[index].height == images[0].height)
      comparisons.append(comparison(bytes[index - 1], bytes[index], width: images[0].width,
                                    from: index - 1, to: index))
    }
    for (index, image) in images.enumerated() {
      try save(image, to: directory.appendingPathComponent("panel-\(index).png"))
    }
    let reference = try render(view)
    let moved = try render(view.offset(y: 1))
    try #require(reference.width == moved.width && reference.height == moved.height)
    let control = comparison(try rgba(reference), try rgba(moved), width: reference.width,
                             from: 0, to: 1)
    #expect((control["maximumChannelDifference"] as? Int ?? 0) >= 64,
            "The comparison must detect deliberately moved content")
    let report: [String: Any] = [
      "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
      "width": images[0].width,
      "height": images[0].height,
      "consecutiveComparisons": comparisons,
      "onePixelOffsetControl": control,
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("report.json"))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["CANDELA_RENDER_PROBE_DIR"] != nil))
  func captureNativePauseControls() async throws {
    let directory = URL(fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["CANDELA_RENDER_PROBE_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let key = "native-pause-probe-\(UUID().uuidString)"
    let name = "OLED Display"
    VolatilePrefs.set(["oledCareEnrolled.\(key)": true])
    defer { VolatilePrefs.remove(["oledCareEnrolled.\(key)"]) }
    let model = TestFixtures.appModel(discovery: ScriptedDiscovery([(id: 7, key: key, name: name)]))
    await model.refresh()
    let state = try #require(model.displays.first)
    model.oledCare.pauseDimming(for: key, duration: 15 * 60)
    defer { model.oledCare.resumeDimming(for: key) }
    EnhancedAccessibility.enable()
    defer { EnhancedAccessibility.disable() }

    for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
      let background = scheme == .light ? Color.white : Color(white: 0.12)
      let panel = PanelHostingView(rootView: PanelView().environment(model)
        .environment(\.colorScheme, scheme).background(background))
      panel.setFrameSize(panel.fittingSize)
      let window = mount(panel, scheme: scheme)
      defer { window.contentView = nil; window.close() }
      // Let the application's entrance animation finish. This is a native
      // hosting capture, separate from the consecutive ImageRenderer probe.
      try await Task.sleep(for: .milliseconds(500))
      panel.layoutSubtreeIfNeeded()
      try save(nativeImage(panel), to: directory.appendingPathComponent("native-panel-paused-\(suffix).png"))
      let careButton = try #require(accessibilityNodes(panel).first {
        ($0.accessibilityLabel?() ?? nil) == "\(name) dimming controls"
      })
      #expect(careButton.accessibilityPerformPress?() == true)
      try await Task.sleep(for: .milliseconds(350))
      window.setContentSize(panel.fittingSize)
      panel.layoutSubtreeIfNeeded()
      try save(nativeImage(panel), to: directory.appendingPathComponent("native-panel-actions-\(suffix).png"))

      #expect(!accessibilityNodes(panel).contains {
        ($0.accessibilityLabel?() ?? nil) == "Keep awake duration"
      }, "The duration slider must be absent while the row is collapsed")
      let awakeButton = try #require(accessibilityNodes(panel).first {
        ($0.accessibilityLabel?() ?? nil) == "Keep display awake options"
      })
      #expect(awakeButton.accessibilityPerformPress?() == true)
      try await Task.sleep(for: .milliseconds(350))
      window.setContentSize(panel.fittingSize)
      panel.layoutSubtreeIfNeeded()
      try save(nativeImage(panel), to: directory.appendingPathComponent("native-panel-awake-actions-\(suffix).png"))
      #expect(!model.keepAwake.isOn, "Opening duration choices must not activate Keep Awake")
      #expect(accessibilityNodes(panel).filter {
        ($0.accessibilityLabel?() ?? nil) == "Keep awake duration"
      }.count == 1)
      let collapse = try #require(accessibilityNodes(panel).first {
        ($0.accessibilityLabel?() ?? nil) == "Keep display awake options"
      })
      #expect(collapse.accessibilityPerformPress?() == true)
      try await Task.sleep(for: .milliseconds(100))
      #expect(!accessibilityNodes(panel).contains {
        ($0.accessibilityLabel?() ?? nil) == "Keep awake duration"
      }, "Collapsing restores the simple toggle row")

      // SettingsRootView pins dark appearance in the app. Forcing this page
      // light would exercise an unsupported standalone fixture, not the UI.
      if scheme == .dark {
        let settings = NSHostingView(rootView: OledCareDisplayPage(
          state: state, displays: [(key: key, name: name)], onSwitch: { _ in })
          .environment(model).environment(SettingsActions(model: model))
          .environment(\.settingsAccent, .display(isBuiltIn: false, ordinal: 0))
          .environment(\.colorScheme, scheme)
          .frame(width: SettingsTheme.pageWidth + 64, height: 1050)
          .background(background))
        settings.setFrameSize(settings.fittingSize)
        let settingsWindow = mount(settings, scheme: scheme)
        defer { settingsWindow.contentView = nil; settingsWindow.close() }
        try await Task.sleep(for: .milliseconds(350))
        settings.layoutSubtreeIfNeeded()
        try save(nativeImage(settings), to: directory.appendingPathComponent("native-oled-settings-\(suffix).png"))
      }

    }
  }

  /// Dark only: `EndTimePickerView` pins the dark scheme itself.
  /// `EndTimePickerAccessibilityTests` checks its labels in every run.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CANDELA_RENDER_PROBE_DIR"] != nil))
  func captureCustomEndTimeDialogs() async throws {
    let directory = URL(fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["CANDELA_RENDER_PROBE_DIR"]))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for invalid in [false, true] {
      let now = Date()
      let selection = EndTimeSelection(currentDeadline: nil, now: { now }) { _ in
        Issue.record("Capturing a dialog must not apply its action")
        return nil
      }
      if invalid { selection.deadline = now.addingTimeInterval(-60) }
      let host = NSHostingView(rootView: EndTimePickerView(
        selection: selection, detail: "OLED Display", actionTitle: "Pause Dimming",
        cancel: { selection.cancel() }, confirm: { _ = selection.confirm() }))
      host.setFrameSize(host.fittingSize)
      let window = mount(host, scheme: .dark)
      defer { window.contentView = nil; window.close() }
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
      try save(nativeImage(host), to: directory.appendingPathComponent(
        "end-time-dark-\(invalid ? "invalid" : "valid").png"))
      #expect(host.fittingSize.width == 420)
      #expect(host.fittingSize.height < 400)
    }
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["CANDELA_RENDER_PROBE_DIR"] != nil))
  func captureCustomCalendar() async throws {
    let directory = URL(fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["CANDELA_RENDER_PROBE_DIR"]))
    var day = Date()
    let host = NSHostingView(rootView: EndTimeCalendarView(
      day: Binding(get: { day }, set: { day = $0 }), calendar: .current, selected: {})
      .environment(\.settingsAccent, SettingsAccent.display(isBuiltIn: false, ordinal: 0))
      .environment(\.colorScheme, .dark))
    host.setFrameSize(host.fittingSize)
    let window = mount(host, scheme: .dark)
    defer { window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(100))
    try save(nativeImage(host), to: directory.appendingPathComponent("end-time-calendar.png"))
    #expect(host.fittingSize.width == 320)
    #expect(host.fittingSize.height < 400)
  }

  private func mount(_ host: NSView, scheme: ColorScheme) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: host.frame.size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    return window
  }

  private func nativeImage(_ host: NSView) throws -> CGImage {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return try #require(bitmap.cgImage)
  }

  private func accessibilityNodes(_ element: Any, depth: Int = 0) -> [AnyObject] {
    guard depth < 30 else { return [] }
    let object = element as AnyObject
    let children = (object.accessibilityChildren?() ?? nil) ?? []
    return [object] + children.flatMap { accessibilityNodes($0, depth: depth + 1) }
  }

  private func render(_ view: some View) throws -> CGImage {
    try #require(ImageRenderer(content: view).cgImage)
  }

  private func save(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(
      url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
  }

  private func comparison(
    _ a: [UInt8], _ b: [UInt8], width: Int, from: Int, to: Int
  ) -> [String: Any] {
    var maximum = 0
    var changedPixels = 0
    var bounds = [Int.max, Int.max, -1, -1]
    for pixel in 0 ..< a.count / 4 {
      var changed = false
      for channel in 0 ..< 4 {
        let difference = abs(Int(a[pixel * 4 + channel]) - Int(b[pixel * 4 + channel]))
        maximum = max(maximum, difference)
        changed = changed || difference > 0
      }
      if changed {
        changedPixels += 1
        let x = pixel % width
        let y = pixel / width
        bounds = [min(bounds[0], x), min(bounds[1], y), max(bounds[2], x), max(bounds[3], y)]
      }
    }
    return ["from": from, "to": to, "maximumChannelDifference": maximum,
            "changedPixels": changedPixels, "changedPixelBounds": changedPixels == 0 ? [] : bounds]
  }

  private func rgba(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try #require(CGContext(
        data: buffer.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }
}

/// The end-time dialog's spoken names, checked in every run: the probe above
/// asserts them too, but only when it is capturing.
@Suite("End-time picker accessibility") @MainActor
struct EndTimePickerAccessibilityTests {
  @Test func theDialogNamesItsDateAndTimeFields() async throws {
    EnhancedAccessibility.enable()
    defer { EnhancedAccessibility.disable() }
    let now = Date()
    let selection = EndTimeSelection(currentDeadline: nil, now: { now }) { _ in
      Issue.record("Reading the dialog must not apply its action")
      return nil
    }
    let host = NSHostingView(rootView: EndTimePickerView(
      selection: selection, detail: "OLED Display", actionTitle: "Pause Dimming",
      cancel: { selection.cancel() }, confirm: { _ = selection.confirm() }))
    host.setFrameSize(host.fittingSize)
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: host.frame.size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.contentView = nil; window.close() }
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    let labels = Set(Self.nodes(host).compactMap { $0.accessibilityLabel?() ?? nil })
    for label in ["End date", "End time hour", "End time minute", "Pause Dimming", "Cancel"] {
      #expect(labels.contains(label), "\(label) is missing from \(labels.sorted())")
    }
  }

  private static func nodes(_ element: Any, depth: Int = 0) -> [AnyObject] {
    guard depth < 30 else { return [] }
    let object = element as AnyObject
    let children = (object.accessibilityChildren?() ?? nil) ?? []
    return [object] + children.flatMap { nodes($0, depth: depth + 1) }
  }
}
