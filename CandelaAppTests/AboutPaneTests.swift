import Foundation
import Testing

// The About page's one derived sentence (AT10). Pinned verbatim because the
// never-checked line is the first thing a fresh install shows, and asserted
// against a fixed clock so the formatter's en_US pin (D25) is under test: a
// machine-locale run fails here rather than on a user's screen.
@Suite("About pane copy") @MainActor
struct AboutPaneTests {
  private let now = Date(timeIntervalSince1970: 1_755_600_000)

  @Test func neverCheckedSaysSoWithoutADate() {
    #expect(AboutPane.checkNowCaption(lastCheck: nil, now: now)
      == "Candela hasn't checked for updates yet.")
  }

  @Test func aRecentCheckReadsRelative() {
    let twoHoursAgo = now.addingTimeInterval(-7200)
    #expect(AboutPane.checkNowCaption(lastCheck: twoHoursAgo, now: now)
      == "Last checked 2 hours ago.")
  }

  @Test func anOldCheckStillReadsRelativeRatherThanABareDate() {
    let lastMonth = now.addingTimeInterval(-40 * 24 * 3600)
    #expect(AboutPane.checkNowCaption(lastCheck: lastMonth, now: now)
      == "Last checked 1 month ago.")
  }
}
