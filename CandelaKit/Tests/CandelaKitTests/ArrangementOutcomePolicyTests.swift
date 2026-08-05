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
  private func tile(_ id: CGDirectDisplayID, _ rect: DisplayRect) -> ArrangementTile {
    ArrangementFixtures.tile(id, rect)
  }

  private var requested: DisplayArrangement {
    // 2 stacked above 1, 1 main. A valid layout: full shared horizontal edge.
    DisplayArrangement(tiles: [
      tile(1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
      tile(2, DisplayRect(x: 0, y: -1080, width: 1920, height: 1080)),
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
      tile(1, DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
      tile(2, DisplayRect(x: 1920, y: 0, width: 1920, height: 1080)),
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
      tile(1, DisplayRect(x: 1920, y: 0, width: 1920, height: 1080)),
      tile(2, DisplayRect(x: 0, y: 0, width: 1920, height: 1080)),
    ])
    #expect(ArrangementOutcomePolicy.notices(
      requested: requested, resulting: resulting, requestedMain: 1
    ) == [.adjusted(resulting), .mainDisplayUnchanged(1)])
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
}
