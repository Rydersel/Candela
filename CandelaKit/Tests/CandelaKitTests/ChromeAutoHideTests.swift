import Testing
@testable import CandelaKit

/// Never the real system chrome: a Kit test must not toggle the dev machine's
/// menu bar or restart its Dock. `writes` counts both setters — every claim in
/// this suite is "did anything get written", never "which value was stored".
@MainActor
private final class FakeChrome: ChromeWriting {
  var menuBar = false
  var dock = false
  var writes = 0
  func readMenuBarAutoHide() -> Bool { menuBar }
  func writeMenuBarAutoHide(_ on: Bool) { menuBar = on; writes += 1 }
  func readDockAutoHide() -> Bool { dock }
  func writeDockAutoHide(_ on: Bool) { dock = on; writes += 1 }
}

@MainActor
@Suite("Chrome auto-hide controller")
struct ChromeAutoHideTests {
  @Test func reflectsLiveStateAtInit() {
    let fake = FakeChrome(); fake.menuBar = true
    let c = ChromeAutoHideController(writer: fake)
    #expect(c.menuBarAutoHide == true)
    #expect(c.dockAutoHide == false)
    #expect(fake.writes == 0)   // OC10: reading never writes
  }

  @Test func refreshFollowsExternalChangesWithoutWriting() {
    let fake = FakeChrome()
    let c = ChromeAutoHideController(writer: fake)
    fake.dock = true            // flipped in System Settings
    c.refresh()
    #expect(c.dockAutoHide == true)
    #expect(fake.writes == 0)
  }

  @Test func setWritesAndUpdatesState() {
    let fake = FakeChrome()
    let c = ChromeAutoHideController(writer: fake)
    c.setMenuBarAutoHide(true)
    #expect(fake.menuBar == true)
    #expect(c.menuBarAutoHide == true)
    #expect(fake.writes == 1)
  }

  @Test func settingTheSameValueStillWritesNothingExtra() {
    let fake = FakeChrome(); fake.menuBar = true
    let c = ChromeAutoHideController(writer: fake)
    c.setMenuBarAutoHide(true)
    #expect(fake.writes == 0)   // no-op set: nothing to change, nothing written
  }

  /// The two setters are separate code paths, and every test above drives only
  /// the menu bar one — a dock setter wired to the menu bar write would pass
  /// all of them.
  @Test func dockSetterWritesOnlyTheDock() {
    let fake = FakeChrome()
    let c = ChromeAutoHideController(writer: fake)
    c.setDockAutoHide(true)
    #expect(fake.dock == true)
    #expect(fake.menuBar == false)
    #expect(c.dockAutoHide == true)
    #expect(c.menuBarAutoHide == false)
    #expect(fake.writes == 1)
  }

  /// The no-op guard compares against the controller's cached value, so a
  /// refresh has to move that cache — otherwise the first toggle after an
  /// external change is swallowed.
  @Test func refreshMovesTheValueTheNoOpGuardReads() {
    let fake = FakeChrome()
    let c = ChromeAutoHideController(writer: fake)
    fake.dock = true
    c.refresh()
    c.setDockAutoHide(true)
    #expect(fake.writes == 0)
    c.setDockAutoHide(false)
    #expect(fake.dock == false)
    #expect(fake.writes == 1)
  }
}
