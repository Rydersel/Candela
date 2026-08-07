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

/// The support range is macOS 14, 15 and 26. There is no 16 through 25: Apple
/// renumbered after Sequoia, so "every version we run on" is three majors.
private let supportedMajorVersions = [14, 15, 26]

private let everyRecord: [ControlCenterMenuBarRecord] =
  [.absent, .unreadable, .option(0), .option(1), .option(2), .option(3)]

@Suite("Menu bar auto-hide policy")
struct MenuBarAutoHidePolicyTests {
  /// Feature detection comes FIRST, on every version. A key that is really
  /// there is the strongest evidence available that this macOS uses it, and it
  /// beats any guess made from the version number.
  @Test func aPresentRecordParticipatesOnEveryVersion() {
    for major in supportedMajorVersions {
      #expect(MenuBarAutoHidePolicy.controlCenterRecordParticipates(.option(0), osMajorVersion: major))
      #expect(MenuBarAutoHidePolicy.controlCenterRecordParticipates(.option(3), osMajorVersion: major))
    }
  }

  /// Sonoma and Sequoia are sourced as backing the picker with the global keys
  /// alone, so an absent record there is not a gap to fill: it is a domain this
  /// macOS does not use, and inventing a value in it would be a write into
  /// undocumented schema on a version nobody has ever measured.
  @Test func anAbsentRecordIsSkippedBeforeTahoe() {
    #expect(!MenuBarAutoHidePolicy.controlCenterRecordParticipates(.absent, osMajorVersion: 14))
    #expect(!MenuBarAutoHidePolicy.controlCenterRecordParticipates(.absent, osMajorVersion: 15))
  }

  /// On the version sourced to own the key, absence means "never set", not
  /// "unsupported": a machine whose owner never opened that pane has no value
  /// yet, and skipping it would leave System Settings disagreeing exactly the
  /// way #104 describes. Write it defensively.
  @Test func anAbsentRecordIsStillWrittenOnTahoeAndLater() {
    #expect(MenuBarAutoHidePolicy.controlCenterRecordParticipates(.absent, osMajorVersion: 26))
    #expect(MenuBarAutoHidePolicy.controlCenterRecordParticipates(.absent, osMajorVersion: 27))
  }

  /// A value that is present but not an integer is schema we do not recognise.
  /// It gets the same treatment as absence: replaced on the version that owns
  /// the key, left completely alone on versions that do not.
  @Test func anUnreadableRecordFollowsTheSameVersionRuleAsAbsence() {
    #expect(!MenuBarAutoHidePolicy.controlCenterRecordParticipates(.unreadable, osMajorVersion: 14))
    #expect(!MenuBarAutoHidePolicy.controlCenterRecordParticipates(.unreadable, osMajorVersion: 15))
    #expect(MenuBarAutoHidePolicy.controlCenterRecordParticipates(.unreadable, osMajorVersion: 26))
  }

  /// THE strand invariant, and the reason one predicate serves both legs.
  ///
  /// A pessimistic read (hidden if EITHER half says hidden) plus a write that
  /// skips the record is an unrecoverable switch: the read reports ON from a
  /// record the write refuses to clear, so the OFF click writes the legacy key,
  /// changes nothing the read looks at, and the switch snaps straight back. The
  /// user cannot get their menu bar back from inside the app, which is exactly
  /// what D29 rule 3 forbids. Whatever the read consults, the write must be
  /// willing to write.
  @Test func theReadNeverConsultsARecordTheWriteWouldSkip() {
    for major in supportedMajorVersions {
      for record in everyRecord {
        guard !MenuBarAutoHidePolicy.controlCenterRecordParticipates(record, osMajorVersion: major)
        else { continue }
        for effective in [true, false] {
          #expect(MenuBarAutoHidePolicy.isMenuBarHidden(
            effectiveBit: effective, record: record, osMajorVersion: major) == effective)
        }
      }
    }
  }

  /// The pessimistic read itself, on the version that does consult the record:
  /// the switch must read ON whenever ANYTHING is hiding the bar.
  @Test func aParticipatingRecordCanReportHiddenOverAClearEffectiveBit() {
    #expect(MenuBarAutoHidePolicy.isMenuBarHidden(effectiveBit: false, record: .option(0), osMajorVersion: 26))
    #expect(MenuBarAutoHidePolicy.isMenuBarHidden(effectiveBit: false, record: .option(1), osMajorVersion: 26))
    #expect(!MenuBarAutoHidePolicy.isMenuBarHidden(effectiveBit: false, record: .option(2), osMajorVersion: 26))
    #expect(!MenuBarAutoHidePolicy.isMenuBarHidden(effectiveBit: false, record: .option(3), osMajorVersion: 26))
  }

  /// And the effective bit alone is always enough, whatever the record says.
  @Test func theEffectiveBitAloneStillReportsHidden() {
    for major in supportedMajorVersions {
      for record in everyRecord {
        #expect(MenuBarAutoHidePolicy.isMenuBarHidden(
          effectiveBit: true, record: record, osMajorVersion: major))
      }
    }
  }

  /// The four values as MEASURED on macOS 26 (2026-08-07). Public sources
  /// disagree about this mapping, one of them reversing it end for end, so the
  /// numbers are pinned here against the machine they were read from rather
  /// than against anybody's README.
  @Test func theOptionEncodesBothHalvesOfTheChoice() {
    #expect(MenuBarAutoHidePolicy.option(desktopHides: true, fullScreenHides: true) == 0)
    #expect(MenuBarAutoHidePolicy.option(desktopHides: true, fullScreenHides: false) == 1)
    #expect(MenuBarAutoHidePolicy.option(desktopHides: false, fullScreenHides: true) == 2)
    #expect(MenuBarAutoHidePolicy.option(desktopHides: false, fullScreenHides: false) == 3)
  }

  /// Encode then read back: the desktop half survives whatever the user's
  /// full-screen preference is, which is the half Candela must never choose.
  @Test func theDesktopHalfRoundTripsThroughTheOption() {
    for desktopHides in [true, false] {
      for fullScreenHides in [true, false] {
        let option = MenuBarAutoHidePolicy.option(
          desktopHides: desktopHides, fullScreenHides: fullScreenHides)
        #expect(MenuBarAutoHidePolicy.isMenuBarHidden(
          effectiveBit: false, record: .option(option), osMajorVersion: 26) == desktopHides)
      }
    }
  }

  /// A record we cannot decode must not be allowed to answer the read even
  /// where it participates, or an unrecognised value would silently mean
  /// "hidden" and pin the switch ON.
  @Test func anUndecodableRecordContributesNothingToTheRead() {
    #expect(!MenuBarAutoHidePolicy.isMenuBarHidden(
      effectiveBit: false, record: .unreadable, osMajorVersion: 26))
    #expect(!MenuBarAutoHidePolicy.isMenuBarHidden(
      effectiveBit: false, record: .absent, osMajorVersion: 26))
    // An int outside the measured 0...3 is schema we do not know either.
    #expect(!MenuBarAutoHidePolicy.isMenuBarHidden(
      effectiveBit: false, record: .option(99), osMajorVersion: 26))
  }
}
