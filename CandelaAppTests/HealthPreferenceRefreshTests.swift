import AppKit
import CandelaKit
import Foundation
import SwiftUI
import Testing

@Suite("Health preference refresh") @MainActor
struct HealthPreferenceRefreshTests {
  enum Control: CaseIterable {
    case telemetry, observation, hours

    var name: PrefName {
      switch self {
      case .telemetry: .oledTelemetry
      case .observation: .oledWindowObservation
      case .hours: .oledHoursTracking
      }
    }

    var label: String {
      switch self {
      case .telemetry: "Measure how bright each part of this display is"
      case .observation: "Note which apps are on this display"
      case .hours: "Count hours of use"
      }
    }

    func set(_ value: Bool, in prefs: DisplayPrefs) {
      switch self {
      case .telemetry: prefs.oledTelemetry = value
      case .observation: prefs.oledWindowObservation = value
      case .hours: prefs.oledHoursTracking = value
      }
    }
  }

  @Test(arguments: Control.allCases)
  func aRetainedPaneUpdatesItsSwitchAfterPreferenceWrites(_ control: Control) async throws {
    let key = "health-refresh-\(UUID().uuidString)"
    let prefs = DisplayPrefs(persistenceKey: key)
    control.set(false, in: prefs)
    defer {
      for name in UserDefaults.standard.dictionaryRepresentation().keys where name.hasSuffix(".\(key)") {
        UserDefaults.standard.removeObject(forKey: name)
      }
    }
    // Real model and propagation, with fake discovery and hardware. The OLED
    // coordinator is never started, and this fixture ID is not a real panel.
    let model = TestFixtures.appModel(discovery: ScriptedDiscovery([
      (id: 424242, key: key, name: "Health Refresh Fixture"),
    ]))
    await model.refresh()
    try #require(model.displays.count == 1)
    let actions = SettingsActions(model: model)
    let writer = DisplayPrefWriter(persistenceKey: key, actions: actions)

    _ = NSApplication.shared
    (NSApp as NSObject).accessibilitySetValue(
      true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    let host = NSHostingView(rootView: HealthPane()
      .environment(model)
      .environment(actions)
      .environment(\.settingsAccent, SettingsRegistry.descriptor(for: .health).accent)
      .transaction { $0.disablesAnimations = true }
      .frame(width: 720, height: 2000))
    host.frame = NSRect(x: 0, y: 0, width: 720, height: 2000)

    // Keep this exact host/root alive. Replacing it or switching panes would
    // refresh plain UserDefaults by accident and hide the missed observation.
    try await expectSwitch(in: host, label: control.label, value: 0)
    for value in [true, false] {
      // The production writer exercises preference propagation without clicking
      // telemetry's permission-requesting setter in a test process.
      writer.write(control.name) { control.set(value, in: $0) }
      try await expectSwitch(in: host, label: control.label, value: value ? 1 : 0)
    }
  }

  private func expectSwitch(in host: NSView, label: String, value: Int) async throws {
    var actual: Int?
    for _ in 0..<100 {
      host.layoutSubtreeIfNeeded()
      actual = switchValue(in: host, label: label)
      if actual == value { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(actual == value, "The retained \(label) switch must display the current preference")
  }

  private func switchValue(in element: Any, label: String, depth: Int = 0) -> Int? {
    guard depth < 40 else { return nil }
    let object = element as AnyObject
    if (object.accessibilityRole?() ?? nil) == .checkBox,
       (object.accessibilityLabel?() ?? nil) == label {
      return ((object as? any NSAccessibilityProtocol)?.accessibilityValue() as? NSNumber)?.intValue
    }
    for child in (object.accessibilityChildren?() ?? nil) ?? [] {
      if let value = switchValue(in: child, label: label, depth: depth + 1) { return value }
    }
    return nil
  }
}
