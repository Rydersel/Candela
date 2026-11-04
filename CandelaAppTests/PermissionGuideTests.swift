import AppKit
import CandelaKit
import Testing

// Every seam is faked: no test reads the real window list, and no test reaches a
// visible state, so no panel is ever ordered onto the screen.
@Suite("Permission guide") @MainActor
struct PermissionGuideTests {
  private final class Calls {
    var opened: [URL] = []
    var prompted: [PermissionPane] = []
  }

  private static let settingsBundleID = "com.apple.systempreferences"
  private static let settingsWindow: [String: Any] = [
    kCGWindowOwnerPID as String: 42,
    kCGWindowLayer as String: 0,
    kCGWindowBounds as String: ["X": -1362, "Y": 25, "Width": 757, "Height": 1032],
  ]

  private func makeGuide(
    calls: Calls,
    pid: pid_t? = 42,
    frontmost: String? = settingsBundleID,
    granted: Bool = false
  ) -> PermissionGuide {
    let guide = PermissionGuide()
    guide.openURL = { calls.opened.append($0) }
    guide.windowList = { [Self.settingsWindow] }
    guide.settingsPID = { pid }
    guide.frontmostBundleID = { frontmost }
    guide.isGranted = { _ in granted }
    guide.requestSystemPrompt = { calls.prompted.append($0) }
    return guide
  }

  @Test func showOpensThePanesDeepLink() {
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    defer { guide.close() }
    guide.show(.accessibility)
    #expect(calls.opened == [PermissionPane.accessibility.deepLink])
    #expect(guide.showing == .accessibility)
    #expect(calls.prompted.isEmpty)
    #expect(guide.isRowShown)
  }

  @Test func secondShowRetargetsOneGuide() {
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    defer { guide.close() }
    guide.show(.accessibility)
    let first = guide.panel
    guide.show(.screenRecording)
    #expect(guide.showing == .screenRecording)
    #expect(calls.opened == [PermissionPane.accessibility.deepLink, PermissionPane.screenRecording.deepLink])
    #expect(first != nil)
    #expect(guide.panel === first)
  }

  @Test func grantClosesEvenWhenSettingsIsBehind() {
    let calls = Calls()
    let guide = makeGuide(calls: calls, frontmost: "com.apple.finder", granted: true)
    defer { guide.close() }
    guide.show(.accessibility)
    guide.tick()
    #expect(guide.showing == nil)
    #expect(!guide.isTracking)
  }

  @Test func hiddenWithoutAVisibleSettingsWindow() {
    let calls = Calls()
    let guide = makeGuide(calls: calls, pid: nil)
    defer { guide.close() }
    guide.show(.accessibility)
    guide.tick()
    #expect(!guide.isPanelShown)
    #expect(guide.panel?.isVisible != true)
    #expect(guide.showing == .accessibility)
    #expect(guide.isTracking)
  }

  @Test func hiddenWhenSettingsIsNotFrontmost() {
    let calls = Calls()
    let guide = makeGuide(calls: calls, frontmost: "com.apple.finder")
    defer { guide.close() }
    guide.show(.accessibility)
    guide.tick()
    #expect(!guide.isPanelShown)
    #expect(guide.panel?.isVisible != true)
    #expect(guide.showing == .accessibility)
  }

  @Test func requestFirstCallsTheSystemPromptOnce() {
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    defer { guide.close() }
    guide.show(.screenRecording, requestFirst: true)
    #expect(calls.prompted == [.screenRecording])
    #expect(!guide.isRowShown)
    #expect(calls.opened == [PermissionPane.screenRecording.deepLink])
  }

  @Test func closeStopsTracking() {
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    guide.show(.accessibility)
    #expect(guide.isTracking)
    guide.close()
    #expect(!guide.isTracking)
    #expect(guide.showing == nil)
  }

  /// Without this the guide ticks at 30 Hz for the rest of the session once the
  /// person quits System Settings without granting and never presses Done.
  @Test func quittingSettingsClosesTheGuide() {
    var pid: pid_t? = 42
    let calls = Calls()
    let guide = makeGuide(calls: calls, frontmost: "com.apple.finder")
    guide.settingsPID = { pid }
    defer { guide.close() }
    guide.show(.accessibility)
    guide.tick()
    #expect(guide.showing == .accessibility)
    pid = nil
    guide.tick()
    #expect(guide.showing == nil)
    #expect(!guide.isTracking)
  }

  @Test func doneClosesTheGuide() throws {
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    defer { guide.close() }
    guide.show(.accessibility)
    let done = try #require(guide.doneControl)
    #expect(done.accessibilityPerformPress())
    #expect(guide.showing == nil)
  }

  /// The reason Done is drawn by hand: a borderless panel never becomes key, so
  /// an `NSButton` in it renders in its inactive, dimmed state.
  @Test func thePanelNeverTakesFocusOrHidesOnDeactivate() throws {
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    defer { guide.close() }
    guide.show(.accessibility)
    let panel = try #require(guide.panel)
    #expect(!panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(!panel.hidesOnDeactivate)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary])
  }
}
