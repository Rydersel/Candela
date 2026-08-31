import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// macOS adjusts a requested layout silently, so an apply reads the outcome back.
/// The hard part is telling adjustment apart from the renormalisation that always follows.
@Suite("Arrangement outcome policy")
struct ArrangementOutcomePolicyTests {
  private var requested: DisplayArrangement {
    // 2 stacked above 1, 1 main. A valid layout: full shared horizontal edge.
    DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
      ArrangementFixtures.tile(2, DisplayRect(x: 0, y: -1080, width: 1920, height: 1080)),
    ])
  }

  /// The global space re-anchors on whichever display ends up at (0,0), so the origins
  /// that come back are routinely shifted for a layout in which nothing moved.
  @Test func aPurelyTranslatedResultIsNotReportedAsAdjusted() {
    let translated = requested.translated(dx: -1920, dy: 4321)
    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: translated, requestedMain: 1
    ) == [.mainDisplayUnchanged(1)])

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

  /// The notice carries what is on screen, not what was asked for: the caller already
  /// has the request and needs the layout it must reconcile against.
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
  /// geometry comparison: the two facts are independent.
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

  /// A layout with no tile at the origin asked for no main display, so the main notice
  /// is skipped rather than guessed. The layout comparison still runs; short-circuiting
  /// both would lose that half.
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

  /// A display that vanished between apply and read-back is a different layout, not a
  /// translation of one, so the caller must not be told its request stands.
  @Test func aResultMissingADisplayIsReportedAsAdjusted() {
    let resulting = DisplayArrangement(tiles: requested.tiles.filter { $0.id == 1 })
    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: resulting, requestedMain: 1
    ) == [.adjusted(resulting)])
  }

  /// A display can arrive between the commit and the read-back, and the newcomer moves
  /// the achieved bounding box. An unfiltered normalisation then shifts every requested
  /// tile and reports a layout nothing touched as adjusted: that is what made the
  /// confirmation card claim macOS had rearranged the displays mid-decision.
  @Test func aResultCarryingAnExtraDisplayIsNotReportedAsAdjusted() {
    // Left of and above everything requested, so the newcomer owns the achieved
    // bounding box's minimum corner, which is what an unfiltered normalisation gets wrong.
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

  /// The main-display half stays unfiltered on purpose: a newcomer at the origin means
  /// the menu bar really is not on the display that was asked for.
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
