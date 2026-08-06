import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// macOS adjusts a requested layout silently, so the outcome of an apply is
/// read back rather than assumed (§6.3). The pair of tests below is the whole
/// point of this type: it has to tell the ADJUSTMENT apart from the
/// renormalisation that follows every successful apply.
@Suite("Arrangement outcome policy")
struct ArrangementOutcomePolicyTests {
  private var requested: DisplayArrangement {
    // 2 stacked above 1, 1 main. A valid layout: full shared horizontal edge.
    DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
      ArrangementFixtures.tile(2, DisplayRect(x: 0, y: -1080, width: 1920, height: 1080)),
    ])
  }

  /// The one that would cry wolf on every apply if it were wrong. The global
  /// space re-anchors on whichever display ends up at (0,0) (§2.2), so the
  /// origins that come back are routinely shifted for a layout in which nothing
  /// physically moved.
  @Test func aPurelyTranslatedResultIsNotReportedAsAdjusted() {
    let translated = requested.translated(dx: -1920, dy: 4321)
    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: translated, requestedMain: 1
    ) == [.mainDisplayUnchanged(1)])

    // …and with the anchor intact, nothing at all is reported.
    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: requested, requestedMain: 1
    ).isEmpty)
  }

  @Test func aGenuinelyDifferentLayoutIsReportedAsAdjusted() {
    // Side by side rather than stacked: no translation maps one onto the other.
    let resulting = DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
      ArrangementFixtures.tile(2, DisplayRect(x: 1920, y: 0, width: 1920, height: 1080)),
    ])
    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: resulting, requestedMain: 1
    ) == [.adjusted(resulting)])
  }

  /// The notice carries what is ON SCREEN, not what was asked for — the caller
  /// needs the layout it must now reconcile against, and it has the request
  /// already.
  @Test func theAdjustedNoticeCarriesTheResultingLayout() throws {
    let resulting = requested.moving(2, to: DisplayPoint(x: 1920, y: 0))
    let notices = ArrangementOutcomePolicy.notices(
      requested: requested, resulting: resulting, requestedMain: 1
    )
    guard case let .adjusted(carried) = try #require(notices.first) else {
      Issue.record("expected an .adjusted notice, got \(notices)")
      return
    }
    #expect(carried == resulting)
    #expect(carried != requested)
  }

  /// The main display is compared on its own identity, never inferred from the
  /// geometry comparison — the two facts are independent, and §2.3 says so
  /// directly.
  @Test func aMainDisplayTheSystemDidNotHonourIsReportedOnItsOwn() {
    // Same relative layout, but 2 ended up at the origin instead of 1.
    let resulting = requested.makingMain(2)
    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: resulting, requestedMain: 1
    ) == [.mainDisplayUnchanged(1)])
  }

  /// Both at once, in a fixed order: the layout first, so a caller that shows
  /// only the first notice shows the bigger fact.
  @Test func anAdjustedLayoutThatAlsoMissedTheMainDisplayReportsBothLayoutFirst() {
    let resulting = DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: 1920, y: 0, width: 1920, height: 1080)),
      ArrangementFixtures.tile(2, DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
    ])
    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: resulting, requestedMain: 1
    ) == [.adjusted(resulting), .mainDisplayUnchanged(1)])
  }

  /// A layout that puts no tile at the origin asked for no main display, so
  /// there is nothing for `.mainDisplayUnchanged` to name — `ArrangementPlan`'s
  /// `requestedMain` is optional for exactly that reason. Skipped rather than
  /// answered against a guess, and the LAYOUT comparison still runs: that is the
  /// half that would be lost if "no main requested" short-circuited both.
  @Test func noRequestedMainSkipsTheMainNoticeAndStillReportsAnAdjustment() {
    let offOrigin = requested.translated(dx: 100, dy: 100)
    #expect(offOrigin.mainDisplayID == nil)
    #expect(ArrangementOutcomePolicy.notices(
      requested: offOrigin, resulting: offOrigin, requestedMain: nil
    ).isEmpty)

    let elsewhere = DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
      ArrangementFixtures.tile(2, DisplayRect(x: 1920, y: 0, width: 1920, height: 1080)),
    ])
    #expect(ArrangementOutcomePolicy.notices(
      requested: offOrigin, resulting: elsewhere, requestedMain: nil
    ) == [.adjusted(elsewhere)])
  }

  /// A display that vanished between the apply and the read-back is a different
  /// layout, not a translation of one — the caller must not be told its request
  /// stands.
  @Test func aResultMissingADisplayIsReportedAsAdjusted() {
    let resulting = DisplayArrangement(tiles: requested.tiles.filter { $0.id == 1 })
    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: resulting, requestedMain: 1
    ) == [.adjusted(resulting)])
  }

  /// The reciprocal of the test above, and the one this suite was missing: a
  /// result carrying an EXTRA display.
  ///
  /// A display can arrive between the commit and the read-back — or one whose
  /// `CGDisplayBounds` was unreadable at `begin` can become readable — and the
  /// newcomer moves the achieved bounding box, so an unfiltered normalisation
  /// shifts every requested tile and reports a layout nothing touched as
  /// adjusted. `ArrangementVerification.unhonoured` already restricts to the
  /// planned displays for this reason; this comparison did not, so the two
  /// disagreed and the confirmation card told the user macOS had rearranged
  /// their displays while they were deciding whether to keep the change.
  @Test func aResultCarryingAnExtraDisplayIsNotReportedAsAdjusted() {
    // Placed left of and above everything requested, so it is the newcomer that
    // owns the achieved bounding box's minimum corner — the case an unfiltered
    // normalisation gets wrong.
    let arrived = ArrangementFixtures.tile(3, DisplayRect(x: -3440, y: -2520, width: 3440, height: 1440))
    let resulting = DisplayArrangement(tiles: requested.tiles + [arrived])

    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: resulting, requestedMain: 1
    ).isEmpty)
  }

  /// The filter must not become a blindfold: with the newcomer present, a
  /// requested display that genuinely moved is still reported.
  @Test func anExtraDisplayDoesNotHideAGenuineAdjustmentOfThePlannedOnes() {
    let arrived = ArrangementFixtures.tile(3, DisplayRect(x: -3440, y: -2520, width: 3440, height: 1440))
    let resulting = DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
      ArrangementFixtures.tile(2, DisplayRect(x: 1920, y: 0, width: 1920, height: 1080)),
      arrived,
    ])
    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: resulting, requestedMain: 1
    ) == [.adjusted(resulting)])
  }

  /// …and the main-display half stays UNfiltered on purpose. A newcomer that
  /// landed at the origin means the menu bar really is not on the display that
  /// was asked for, which is a fact about the machine rather than about the
  /// planned displays' relative positions.
  @Test func anExtraDisplayAtTheOriginStillReportsTheMainDisplayUnchanged() {
    let arrived = ArrangementFixtures.tile(3, DisplayRect(x: 0, y: 0, width: 3440, height: 1440))
    // The requested pair, translated so 3 owns the origin and the pair's own
    // relative geometry is untouched.
    let resulting = DisplayArrangement(tiles: requested.translated(dx: 3440, dy: 0).tiles + [arrived])

    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: resulting, requestedMain: 1
    ) == [.mainDisplayUnchanged(1)])
  }
}
