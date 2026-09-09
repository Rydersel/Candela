import AppKit
import CandelaKit
import SwiftUI
import Testing

@Suite("Directed Settings navigation", .serialized)
@MainActor
struct SettingsOpenNavigationTests {
  @Test func aRequestReachesTheMountedRootWithoutAnotherAppearance() async throws {
    SettingsOpener.pendingSelection = nil
    defer { SettingsOpener.pendingSelection = nil }
    let fixture = Fixture()
    defer { fixture.detach() }
    try await fixture.expectTitle("General")

    // Publish through the same destination slot as open(at:), without
    // activating the test process or sending an application menu action.
    SettingsOpener.pendingSelection = .pane(.keyboard)
    try await fixture.expectTitle("Keyboard")
    #expect(SettingsOpener.pendingSelection == nil)
  }

  @Test func anEarlyRequestIsConsumedOnceAndOrdinaryReappearanceKeepsSelection() async throws {
    SettingsOpener.pendingSelection = .pane(.keyboard)
    defer { SettingsOpener.pendingSelection = nil }
    let fixture = Fixture()
    defer { fixture.detach() }
    try await fixture.expectTitle("Keyboard")
    #expect(SettingsOpener.pendingSelection == nil)

    fixture.actions.reveal(.pane(.general))
    try await fixture.expectTitle("General")
    fixture.reattach()
    try await fixture.expectTitle("General")
    #expect(SettingsOpener.pendingSelection == nil)

    SettingsOpener.pendingSelection = .pane(.keyboard)
    try await fixture.expectTitle("Keyboard")
    #expect(SettingsOpener.pendingSelection == nil)
    fixture.actions.reveal(.pane(.general))
    try await fixture.expectTitle("General")
    SettingsOpener.pendingSelection = .pane(.keyboard)
    try await fixture.expectTitle("Keyboard")
    #expect(SettingsOpener.pendingSelection == nil)
  }

  @MainActor private final class Fixture {
    let actions: SettingsActions
    let window: NSWindow
    let host: NSView

    init() {
      let model = TestFixtures.appModel()
      actions = SettingsActions(model: model)
      host = NSHostingView(rootView: SettingsRootView()
        .environment(model)
        .environment(actions)
        .transaction { $0.disablesAnimations = true })
      window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
        styleMask: [.titled], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      host.layoutSubtreeIfNeeded()
    }

    func expectTitle(_ title: String) async throws {
      for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if window.title == title { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(window.title == title)
    }

    func reattach() {
      window.contentView = nil
      window.contentView = host
      host.layoutSubtreeIfNeeded()
    }

    func detach() {
      window.contentView = nil
      window.close()
    }
  }
}
