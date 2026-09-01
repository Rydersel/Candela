import CoreGraphics
import Testing
@testable import CandelaKit

@Suite("Confirmation window placement")
struct ConfirmationPlacementTests {
  /// A 1440p-ish visible frame, and a window about the size the confirmation
  /// panels fit to.
  static let screen = CGRect(x: 0, y: 0, width: 3440, height: 1400)
  static let size = CGSize(width: 420, height: 220)

  static func centred(_ size: CGSize = size, in frame: CGRect = screen) -> CGPoint {
    CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
  }

  @Test func theOnlyWindowIsCentred() {
    #expect(
      ConfirmationPlacement.origin(size: Self.size, in: Self.screen, avoiding: [])
        == Self.centred()
    )
  }

  /// An empty rect is not a window: `NSWindow.frame` reports one for a panel that has
  /// never been sized, and treating it as an obstacle pushes a lone confirmation off centre.
  @Test func anEmptyRectIsNotAnObstacle() {
    #expect(
      ConfirmationPlacement.origin(size: Self.size, in: Self.screen, avoiding: [.zero])
        == Self.centred()
    )
  }

  /// The defect. Before this, both windows took the centre and neither moved.
  @Test func aSecondWindowDoesNotLandOnTheFirst() {
    let incumbent = CGRect(origin: Self.centred(), size: Self.size)
    let origin = ConfirmationPlacement.origin(
      size: Self.size, in: Self.screen, avoiding: [incumbent]
    )
    #expect(origin != Self.centred())
    #expect(!CGRect(origin: origin, size: Self.size).intersects(incumbent))
    #expect(Self.screen.contains(CGRect(origin: origin, size: Self.size)))
  }

  /// Below first, so the pairing is stable rather than decided by whichever
  /// equal-distance candidate happened to sort first.
  @Test func theSecondWindowGoesBelowTheFirst() {
    let incumbent = CGRect(origin: Self.centred(), size: Self.size)
    let origin = ConfirmationPlacement.origin(
      size: Self.size, in: Self.screen, avoiding: [incumbent]
    )
    #expect(origin.x == Self.centred().x)
    #expect(origin.y == incumbent.minY - ConfirmationPlacement.gap - Self.size.height)
  }

  /// A third window clears BOTH. Avoiding each rect separately would let it
  /// land on the one it was not measured against.
  @Test func aThirdWindowClearsEveryWindowAlreadyUp() {
    let first = CGRect(origin: Self.centred(), size: Self.size)
    let second = CGRect(
      origin: ConfirmationPlacement.origin(size: Self.size, in: Self.screen, avoiding: [first]),
      size: Self.size
    )
    let third = CGRect(
      origin: ConfirmationPlacement.origin(
        size: Self.size, in: Self.screen, avoiding: [first, second]
      ),
      size: Self.size
    )
    #expect(!third.intersects(first))
    #expect(!third.intersects(second))
    #expect(Self.screen.contains(third))
  }

  /// No room below, so it goes above rather than off the bottom of the screen.
  @Test func aWindowWithNoRoomBelowGoesAbove() {
    let short = CGRect(x: 0, y: 0, width: 1200, height: 500)
    let size = CGSize(width: 420, height: 220)
    let incumbent = CGRect(
      origin: CGPoint(x: 390, y: 20), size: size
    )
    let origin = ConfirmationPlacement.origin(size: size, in: short, avoiding: [incumbent])
    let placed = CGRect(origin: origin, size: size)
    #expect(!placed.intersects(incumbent))
    #expect(short.contains(placed))
    #expect(origin.y > incumbent.minY)
  }

  /// Vertically there is no room at all, so it steps sideways instead.
  @Test func aWindowWithNoVerticalRoomGoesBeside() {
    let strip = CGRect(x: 0, y: 0, width: 2000, height: 240)
    let size = CGSize(width: 420, height: 220)
    let incumbent = CGRect(origin: Self.centred(size, in: strip), size: size)
    let origin = ConfirmationPlacement.origin(size: size, in: strip, avoiding: [incumbent])
    let placed = CGRect(origin: origin, size: size)
    #expect(!placed.intersects(incumbent))
    #expect(strip.contains(placed))
  }

  /// Stated so a later reader does not mistake it for a promise: a screen with room for
  /// one window gets an overlap, but never the stack that hid the countdown.
  @Test func aScreenWithRoomForOneWindowStillOffsetsTheSecond() {
    let tight = CGRect(x: 0, y: 0, width: 500, height: 300)
    let size = CGSize(width: 420, height: 220)
    let incumbent = CGRect(origin: Self.centred(size, in: tight), size: size)
    let origin = ConfirmationPlacement.origin(size: size, in: tight, avoiding: [incumbent])
    #expect(origin != incumbent.origin)
    #expect(tight.contains(CGRect(origin: origin, size: size)))
  }

  /// A window bigger than the space it is going into still gets an on-screen
  /// origin rather than one computed off the top left by an inverted clamp.
  @Test func aWindowLargerThanTheScreenIsPinnedToItsCorner() {
    let tiny = CGRect(x: 100, y: 50, width: 200, height: 120)
    let size = CGSize(width: 420, height: 220)
    let incumbent = CGRect(origin: CGPoint(x: 100, y: 50), size: size)
    let origin = ConfirmationPlacement.origin(size: size, in: tiny, avoiding: [incumbent])
    #expect(origin.x == tiny.minX)
    #expect(origin.y == tiny.minY)
  }

  /// Placement is measured against the VISIBLE frame, so a menu bar or a Dock
  /// moves the whole arrangement rather than being drawn over.
  @Test func placementFollowsTheVisibleFrameNotTheScreenOrigin() {
    let inset = CGRect(x: 0, y: 80, width: 3440, height: 1280)
    let origin = ConfirmationPlacement.origin(size: Self.size, in: inset, avoiding: [])
    #expect(origin == Self.centred(Self.size, in: inset))
  }
}
