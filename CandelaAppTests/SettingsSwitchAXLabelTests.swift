import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

/// Reads the accessibility tree a settings page publishes, not its source.
///
/// `themedSwitch` stands a real `Toggle` in through
/// `accessibilityRepresentation`, and the representation is handed
/// `configuration.label` as a VIEW. Measured 2026-09-03 against the deployed
/// app: that view does not become a description, so a switch row announces as a
/// bare checkbox unless the call site adds `.accessibilityLabel`. This suite is
/// what keeps the two rows it names from losing theirs again.
@MainActor
@Suite("Settings switch accessibility labels")
struct SettingsSwitchAXLabelTests {

  /// SwiftUI builds no accessibility nodes until an assistive client attaches,
  /// and a test process is not one.
  private func attachAnAssistiveClient() {
    _ = NSApplication.shared
    (NSApp as NSObject).accessibilitySetValue(
      true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
  }

  private func collect(
    _ element: Any, role: NSAccessibility.Role, depth: Int, into found: inout [AnyObject]
  ) {
    guard depth < 32 else { return }
    let object = element as AnyObject
    if (object.accessibilityRole?() ?? nil) == role { found.append(object) }
    for child in (object.accessibilityChildren?() ?? nil) ?? [] {
      collect(child, role: role, depth: depth + 1, into: &found)
    }
  }

  /// Tall enough that a scrolling page lays its whole content out: a row the
  /// layout never reached would look like a row with no label.
  private func labels(
    _ view: some View, role: NSAccessibility.Role, height: CGFloat = 1600
  ) -> [String] {
    attachAnAssistiveClient()
    let host = NSHostingView(rootView: view.frame(width: 720, height: height))
    host.frame = NSRect(x: 0, y: 0, width: 720, height: height)
    host.layoutSubtreeIfNeeded()
    var found: [AnyObject] = []
    collect(host, role: role, depth: 0, into: &found)
    return found.map { ($0.accessibilityLabel?() ?? nil) ?? "" }
  }

  private func switchLabels(_ view: some View, height: CGFloat = 1600) -> [String] {
    labels(view, role: .checkBox, height: height)
  }

  /// Proves the walk can fail, and pins the defect this sweep fixed: the same
  /// row without the explicit label publishes nothing to read.
  @Test func aThemedSwitchSpeaksOnlyWhenTheCallSiteLabelsIt() {
    let bare = SettingsCardSection(title: "Probe") {
      SettingRow("What this switch changes.") {
        Toggle("Probe switch", isOn: .constant(true)).themedSwitch()
      }
    }
    #expect(switchLabels(bare, height: 200) == [""])

    let labelled = SettingsCardSection(title: "Probe") {
      SettingRow("What this switch changes.") {
        Toggle("Probe switch", isOn: .constant(true))
          .themedSwitch()
          .accessibilityLabel("Probe switch")
      }
    }
    #expect(switchLabels(labelled, height: 200) == ["Probe switch"])
  }

  @MainActor private func advancedPage() -> some View {
    let model = TestFixtures.appModel()
    let state = TestFixtures.displayState(name: "AX Panel", persistenceKey: "ax-panel")
    return AdvancedPage(
      state: state, displays: [("ax-panel", "AX Panel")], onSwitch: { _ in }
    )
    .environment(model)
    .environment(SettingsActions(model: model))
    .environment(\.settingsAccent, .display(isBuiltIn: false, ordinal: 0))
  }

  @Test func theAdvancedPageSwitchesSpeakTheirOwnCopy() {
    let spoken = switchLabels(advancedPage())
    #expect(spoken.contains("Dim with a screen overlay"))
    #expect(spoken.contains("Show the volume indicator"))
    // The hardware-control row takes its label from `SettingRow`'s safety form,
    // so it is the check that this page has no unlabelled switch at all.
    #expect(!spoken.contains(""))
  }

  /// A text field publishes no description of its own either, and the
  /// `LabeledContent` around one draws its label without publishing it. The
  /// control-code fields are the page's only fields.
  @Test func theAdvancedPageFieldsSpeakTheirOwnCopy() {
    let spoken = labels(advancedPage(), role: .textField)
    #expect(!spoken.isEmpty)
    #expect(!spoken.contains(""))
  }
}
