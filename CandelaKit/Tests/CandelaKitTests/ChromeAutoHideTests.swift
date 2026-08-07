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

/// Accepts every write and honours none — the platform behaviour #53 recorded,
/// where a configuration call reports success without achieving anything.
@MainActor
private final class StubbornChrome: ChromeWriting {
  var writes = 0
  func readMenuBarAutoHide() -> Bool { false }
  func writeMenuBarAutoHide(_ on: Bool) { writes += 1 }
  func readDockAutoHide() -> Bool { false }
  func writeDockAutoHide(_ on: Bool) { writes += 1 }
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

  /// Both legs, or deleting either re-read passes the suite.
  @Test func refreshFollowsExternalChangesWithoutWriting() {
    let fake = FakeChrome()
    let c = ChromeAutoHideController(writer: fake)
    fake.dock = true            // flipped in System Settings
    fake.menuBar = true
    c.refresh()
    #expect(c.dockAutoHide == true)
    #expect(c.menuBarAutoHide == true)
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

  /// A set records what the system reports afterwards, not what was asked for:
  /// a switch that sticks ON over a write that never landed is the pane lying
  /// about the machine.
  @Test func aFailedSetLeavesTheTrueSystemState() {
    let stubborn = StubbornChrome()
    let c = ChromeAutoHideController(writer: stubborn)
    c.setMenuBarAutoHide(true)
    c.setDockAutoHide(true)
    #expect(stubborn.writes == 2)   // it tried
    #expect(c.menuBarAutoHide == false)
    #expect(c.dockAutoHide == false)
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

  /// D29 rule 1 for chrome: turning auto-hiding OFF must reach the system even
  /// when nobody refreshed first. The cache moves only while the OLED Care pane
  /// is on screen, so a change made anywhere else leaves it stale, and a guard
  /// that trusted it swallowed the click that was supposed to bring the menu
  /// bar back. No `refresh()` here on purpose: that IS the case being pinned.
  @Test func disableReachesTheSystemOverAStaleCache() {
    let fake = FakeChrome()
    let c = ChromeAutoHideController(writer: fake)
    #expect(c.menuBarAutoHide == false)
    fake.menuBar = true            // hidden by something outside this app
    c.setMenuBarAutoHide(false)
    #expect(fake.menuBar == false) // the restore actually happened
    #expect(fake.writes == 1)
    #expect(c.menuBarAutoHide == false)
  }

  /// Both setters, or wiring only the menu bar one to a live read passes.
  @Test func dockDisableAlsoReachesTheSystemOverAStaleCache() {
    let fake = FakeChrome()
    let c = ChromeAutoHideController(writer: fake)
    fake.dock = true
    c.setDockAutoHide(false)
    #expect(fake.dock == false)
    #expect(fake.writes == 1)
  }

  /// The live read must also be allowed to SUPPRESS a write, or the fix would
  /// have traded a swallowed disable for a redundant write on every click.
  @Test func aSetMatchingLiveStateStillWritesNothing() {
    let fake = FakeChrome()
    let c = ChromeAutoHideController(writer: fake)
    fake.menuBar = true            // external change, cache still false
    c.setMenuBarAutoHide(true)
    #expect(fake.writes == 0)
    #expect(c.menuBarAutoHide == true)  // and the cache caught up regardless
  }
}
