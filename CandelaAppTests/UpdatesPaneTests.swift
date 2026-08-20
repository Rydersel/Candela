import Foundation
import Testing

// The Updates pane's one derived sentence (AT10). The words are pinned
// verbatim: the never-checked line is the first thing a fresh install shows,
// and the relative line is asserted against a fixed clock so the formatter's
// locale fix (en_US, D25) is itself under test; a machine-locale run would
// fail here, not on a user's screen.
@Suite("Updates pane copy") @MainActor
struct UpdatesPaneTests {
  private let now = Date(timeIntervalSince1970: 1_755_600_000)

  @Test func neverCheckedSaysSoWithoutADate() {
    #expect(UpdatesPane.checkNowCaption(lastCheck: nil, now: now)
      == "Candela hasn't checked for updates yet.")
  }

  @Test func aRecentCheckReadsRelative() {
    let twoHoursAgo = now.addingTimeInterval(-7200)
    #expect(UpdatesPane.checkNowCaption(lastCheck: twoHoursAgo, now: now)
      == "Last checked 2 hours ago.")
  }

  @Test func anOldCheckStillReadsRelativeRatherThanABareDate() {
    let lastMonth = now.addingTimeInterval(-40 * 24 * 3600)
    #expect(UpdatesPane.checkNowCaption(lastCheck: lastMonth, now: now)
      == "Last checked 1 month ago.")
  }
}
