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

  /// The grant read that closes the guide is reported, so the app can recheck
  /// even when its own poll has stood down.
  @Test func aGrantCloseReportsThePane() {
    let calls = Calls()
    let guide = makeGuide(calls: calls, granted: true)
    defer { guide.close() }
    var reported: [PermissionPane] = []
    guide.onGranted = { reported.append($0) }
    guide.show(.accessibility)
    guide.tick()
    #expect(reported == [.accessibility])
  }

  /// The control: Done closes the guide without a grant and reports nothing.
  @Test func aCloseWithoutTheGrantReportsNothing() {
    let calls = Calls()
    let guide = makeGuide(calls: calls, granted: false)
    defer { guide.close() }
    var reported: [PermissionPane] = []
    guide.onGranted = { reported.append($0) }
    guide.show(.accessibility)
    guide.tick()
    guide.close()
    #expect(reported.isEmpty)
  }

  @Test func hiddenWithoutAVisibleSettingsWindow() {
    let calls = Calls()
    let guide = makeGuide(calls: calls, pid: nil)
    defer { guide.close() }
    guide.show(.accessibility)
    guide.tick()
    #expect(!guide.isPanelShown)
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

  /// While following, only every sixth tick asks the privacy database.
  @Test func followingTicksOneToFiveSkipTheGrantRead() {
    var reads = 0
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    // No window, so nothing is ordered on screen; Settings frontmost keeps it following.
    guide.windowList = { [] }
    guide.isGranted = { _ in
      reads += 1
      return false
    }
    defer { guide.close() }
    guide.show(.accessibility)
    #expect(guide.cadence == .following)
    guide.tick()
    #expect(reads == 1)
    for _ in 1...5 { guide.tick() }
    #expect(reads == 1)
    guide.tick()
    #expect(reads == 2)
  }

  /// Settings left open behind another app must not cost thirty wakeups a second.
  @Test func cadenceDropsWhileSettingsIsBehindAndReturnsWhenItIsFront() {
    var reads = 0
    var frontmost = "com.apple.finder"
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    guide.windowList = { [] }
    guide.frontmostBundleID = { frontmost }
    guide.isGranted = { _ in
      reads += 1
      return false
    }
    defer { guide.close() }
    guide.show(.accessibility)
    #expect(guide.cadence == .idle)
    for _ in 1...3 { guide.tick() }
    // Idle ticks are rare, so each one reads the grant.
    #expect(reads == 3)
    #expect(guide.cadence == .idle)
    frontmost = "com.apple.systempreferences"
    guide.tick()
    #expect(guide.cadence == .following)
    frontmost = "com.apple.finder"
    guide.tick()
    #expect(guide.cadence == .idle)
    #expect(PermissionGuide.Cadence.idle.interval >= 0.2)
  }

  /// The notification names the app that came forward; a frontmost read that
  /// has not caught up yet must not leave the guide idle.
  @Test func activationOfSettingsFollowsEvenBeforeTheFrontmostReadAgrees() {
    let calls = Calls()
    let guide = makeGuide(calls: calls, frontmost: "com.apple.finder")
    guide.windowList = { [] }
    defer { guide.close() }
    guide.show(.accessibility)
    #expect(guide.cadence == .idle)
    guide.tick(activatedBundleID: "com.apple.systempreferences")
    #expect(guide.cadence == .following)
  }

  @Test func closeClearsTheCadence() {
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    guide.show(.accessibility)
    #expect(guide.cadence != nil)
    guide.close()
    #expect(guide.cadence == nil)
  }

  @Test func eachPaneHasItsOwnLine() throws {
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    defer { guide.close() }
    guide.show(.accessibility)
    #expect(try #require(guide.lineField).stringValue == "Drag this row into the list above.")
    guide.show(.screenRecording)
    #expect(
      try #require(guide.lineField).stringValue
        == "Drag this row into the list above, then choose Quit & Reopen when macOS asks.")
    guide.show(.screenRecording, requestFirst: true)
    #expect(try #require(guide.lineField).stringValue == "Switch Candela on in the list above.")
  }

  /// The guide is laid out for the 757 pt Settings window before it has seen
  /// the real one; the Screen Recording line is longer than one line there and
  /// must wrap, not truncate.
  @Test(arguments: [PermissionPane.accessibility, .screenRecording])
  func theLineFitsAtTheNarrowestSettingsWindow(pane: PermissionPane) throws {
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    defer { guide.close() }
    guide.show(pane)
    let panel = try #require(guide.panel)
    let field = try #require(guide.lineField)
    // The narrowest panel: 757 - 269 - 21 + 16.
    #expect(abs(panel.frame.width - 483) < 1)
    let needed = try #require(field.cell?.cellSize(
      forBounds: NSRect(x: 0, y: 0, width: field.frame.width, height: .greatestFiniteMagnitude)))
    #expect(needed.height <= field.frame.height)
    let done = try #require(guide.doneControl)
    #expect(field.frame.maxX <= done.frame.minX + PermissionGuideDoneControl.hitPadding)
    #expect(field.frame.maxY <= panel.frame.height)
    if pane == .accessibility {
      #expect(panel.frame.height == PermissionGuideGeometry.panelHeight)
    } else {
      #expect(panel.frame.height > PermissionGuideGeometry.panelHeight)
    }
  }

  /// VoiceOver hears the line, the row once by name, and Done; the arrow and
  /// the row's grip, icon and label are not separate stops.
  @Test func accessibilityTreeIsTheLineTheRowAndDone() throws {
    let calls = Calls()
    let guide = makeGuide(calls: calls)
    defer { guide.close() }
    guide.show(.accessibility)
    let content = try #require(guide.panel?.contentView)
    var elements: [any NSAccessibilityProtocol] = []
    func walk(_ node: Any) {
      guard let node = node as? any NSAccessibilityProtocol else { return }
      if node.isAccessibilityElement() { elements.append(node) }
      for child in node.accessibilityChildren() ?? [] { walk(child) }
    }
    for child in content.accessibilityChildren() ?? [] { walk(child) }
    let roles = elements.compactMap { $0.accessibilityRole() }
    #expect(roles.filter { $0 == .image }.count == 1)
    #expect(roles.filter { $0 == .button }.count == 1)
    #expect(roles.filter { $0 == .staticText }.count == 1)
    #expect(elements.count == 3)
    let row = try #require(elements.first { $0.accessibilityRole() == .image })
    #expect(row.accessibilityLabel()?.hasSuffix(".app") == true)
    #expect(row.accessibilityHelp() == "Drag this row into the list above.")
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
