import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// `apply` is never called here on purpose: it reconfigures the machine the tests run
/// on, and no scope makes a real `CGCompleteDisplayConfiguration` safe unattended. What
/// is testable is what it delegates to: reading the layout with `ArrangementSnapshot` and
/// judging the result with `ArrangementVerification`.
@Suite("CoreGraphics arrangement configurator")
struct CoreGraphicsArrangementConfiguratorTests {
  private func bounds(_ rects: [CGDirectDisplayID: CGRect]) -> (CGDirectDisplayID) -> CGRect {
    { rects[$0] ?? .null }
  }

  // MARK: - Reading the layout

  @Test func everyOnlineDisplayBecomesATileAtItsBounds() {
    let arrangement = ArrangementSnapshot.arrangement(
      of: [MirrorFixtures.display(1, builtIn: true), MirrorFixtures.display(2)],
      bounds: bounds([
        1: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        2: CGRect(x: 1800, y: -271, width: 3440, height: 1440),
      ])
    )
    #expect(arrangement.tiles.map(\.id) == [1, 2])
    #expect(arrangement.tile(2)?.rect == DisplayRect(x: 1800, y: -271, width: 3440, height: 1440))
    #expect(arrangement.tile(1)?.name == "Built-in Display")
    // The origin-derives-main rule: main is derived from the geometry, so reading it back must find the
    // display CoreGraphics puts at the origin.
    #expect(arrangement.mainDisplayID == 1)
  }

  /// The mirror-slave rule. The slave has no independent position — its pixels come from the
  /// master — and setting its origin would silently break the mirror set.
  @Test func aMirrorSlaveGetsNoTileAndIsRecordedOnItsMaster() {
    let arrangement = ArrangementSnapshot.arrangement(
      of: [
        MirrorFixtures.display(1, mirrors: 2, builtIn: true),
        MirrorFixtures.display(2, inSet: true),
        MirrorFixtures.display(3, mirrors: 2),
      ],
      bounds: bounds([
        1: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        2: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        3: CGRect(x: 0, y: 0, width: 1800, height: 1169),
      ])
    )
    #expect(arrangement.tiles.map(\.id) == [2])
    #expect(arrangement.tile(2)?.mirroredIDs == [1, 3])
  }

  /// Sorted, so the value is a function of the topology rather than the enumeration
  /// order: a preview session decides "unchanged" by comparing whole arrangements.
  @Test func mirroredIDsDoNotDependOnEnumerationOrder() {
    let rects = bounds([2: CGRect(x: 0, y: 0, width: 100, height: 100)])
    let displays = [
      MirrorFixtures.display(3, mirrors: 2),
      MirrorFixtures.display(2, inSet: true),
      MirrorFixtures.display(1, mirrors: 2, builtIn: true),
    ]
    #expect(
      ArrangementSnapshot.arrangement(of: displays, bounds: rects)
        == ArrangementSnapshot.arrangement(of: displays.reversed(), bounds: rects)
    )
    #expect(ArrangementSnapshot.arrangement(of: displays, bounds: rects).tile(2)?.mirroredIDs == [1, 3])
  }

  /// `CGDisplayBounds` returns `CGRectNull` for an ID it does not know, an origin of
  /// infinity, and `Int(infinity)` traps. That is why the conversion is fallible.
  @Test func aDisplayWithUnreadableBoundsIsSkippedRatherThanTrappedOn() {
    let arrangement = ArrangementSnapshot.arrangement(
      of: [MirrorFixtures.display(1), MirrorFixtures.display(2)],
      bounds: bounds([1: CGRect(x: 0, y: 0, width: 1920, height: 1080)])
    )
    #expect(arrangement.tiles.map(\.id) == [1])
  }

  /// A zero-size rect is the other shape an unusable display reports: a tile of no area
  /// touches nothing, so `ArrangementRules` reads it as permanently disconnected.
  @Test func aDisplayWithEmptyBoundsIsSkipped() {
    let arrangement = ArrangementSnapshot.arrangement(
      of: [MirrorFixtures.display(1)],
      bounds: bounds([1: CGRect(x: 0, y: 0, width: 0, height: 0)])
    )
    #expect(arrangement.isEmpty)
  }

  // MARK: - Through the real type

  /// The null-bounds guard end to end: the fake's display IDs are unknown to CoreGraphics,
  /// so every `CGDisplayBounds` call returns `CGRectNull`, which used to trap.
  @Test func theRealConfiguratorSurvivesDisplayIDsCoreGraphicsDoesNotKnow() {
    let fake = FakeConfigurator()
    fake.configuredDisplays = [MirrorFixtures.display(0xDEAD_BEEF), MirrorFixtures.display(0xFEED)]
    #expect(CoreGraphicsArrangementConfigurator(displays: fake).currentArrangement().isEmpty)
  }

  /// The one hardware assertion in the file, and it only reads: the display at the origin
  /// is definitionally the main display, so a layout read from this machine must agree with
  /// `CGMainDisplayID`. A conversion that flipped an axis or lost the origin fails here.
  @Test func aLayoutReadFromThisMachineAgreesWithCGMainDisplayID() throws {
    let arrangement = CoreGraphicsArrangementConfigurator().currentArrangement()
    // Only true of a machine with an attached display; a headless CI runner has
    // no layout to read and nothing to assert about one.
    try #require(!arrangement.isEmpty)
    #expect(arrangement.mainDisplayID == CGMainDisplayID())
    #expect(arrangement.tiles.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })
  }
}
