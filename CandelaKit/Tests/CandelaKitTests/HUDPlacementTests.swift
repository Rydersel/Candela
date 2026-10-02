import CoreGraphics
import Testing
@testable import CandelaKit

@Suite("HUD pill placement")
struct HUDPlacementTests {
  /// Pill size and margins as the island ships them. Round values, so a wrong
  /// term in the formula shows up as a wrong number and not as rounding noise.
  private let pill = CGSize(width: 314, height: 62)
  private let margin: CGFloat = 20
  private let topInset: CGFloat = 47
  private let landscape = CGRect(x: 0, y: 0, width: 3440, height: 1440)

  private func origin(_ position: HUDPosition, frame: CGRect, visible: CGRect? = nil) -> CGPoint {
    HUDPlacement.origin(
      position, size: pill, frame: frame, visibleFrame: visible ?? frame,
      topInset: topInset, margin: margin
    )
  }

  // MARK: - The shipped position must not move

  /// Raw 0 is what every existing install has stored, so this case has to
  /// reproduce the formula the island carried before the pref existed.
  @Test func topRightReproducesTheFormulaTheIslandShipped() {
    let point = origin(.topRight, frame: landscape)
    #expect(point.x == landscape.maxX - pill.width - margin)
    #expect(point.y == landscape.maxY - topInset - pill.height - margin)
    #expect(HUDPosition(rawValue: 0) == .topRight)
  }

  @Test func absentAndUnknownStoredValuesResolveToTheShippedPosition() {
    // The downgrade story: a value written by a later build decodes to
    // the position every earlier build used.
    #expect(HUDPosition(rawValue: 99) == nil)
    #expect(HUDPosition.allCases.count == 3)
  }

  /// The raw values are shipped schema and 0 is the RIGHT-hand position, so raw
  /// order is not UI order.
  @Test func thePickerOrderReadsLeftToRightAndCoversEveryCase() {
    #expect(HUDPlacement.pickerOrder == [.topLeft, .topCenter, .topRight])
    #expect(Set(HUDPlacement.pickerOrder) == Set(HUDPosition.allCases))
  }

  // MARK: - The three anchors

  @Test func theThreeAnchorsShareOneHeightAndDifferOnlyHorizontally() {
    let y = landscape.maxY - topInset - pill.height - margin
    for position in HUDPosition.allCases {
      #expect(origin(position, frame: landscape).y == y, "\(position)")
    }
    #expect(origin(.topLeft, frame: landscape).x == margin)
    #expect(origin(.topCenter, frame: landscape).x == 1563) // (3440 - 314) / 2
    #expect(origin(.topRight, frame: landscape).x == 3106)
  }

  /// Horizontal anchors come from the VISIBLE frame so a side Dock never ends up
  /// under the pill. The height comes from the full frame, because an auto-hidden
  /// menu bar leaves the visible frame reaching the top and the pill would sit
  /// where the bar reveals itself.
  @Test func horizontalAnchorsFollowTheVisibleFrameAndTheHeightFollowsTheFullFrame() {
    // A Dock 90 points wide on the left, and the menu bar off the top.
    let dockLeft = CGRect(x: 90, y: 0, width: 3350, height: 1415)
    #expect(origin(.topLeft, frame: landscape, visible: dockLeft).x == 110)
    #expect(origin(.topCenter, frame: landscape, visible: dockLeft).x == 1608)
    // The same Dock on the right instead.
    let dockRight = CGRect(x: 0, y: 0, width: 3350, height: 1415)
    #expect(origin(.topRight, frame: landscape, visible: dockRight).x == 3016)
    for visible in [dockLeft, dockRight] {
      #expect(
        origin(.topRight, frame: landscape, visible: visible).y
          == landscape.maxY - topInset - pill.height - margin
      )
    }
  }

  @Test func aCentredPillLandsOnAWholePointOnAnOddWidth() {
    let odd = CGRect(x: 0, y: 0, width: 1001, height: 800)
    // 500.5 - 157 = 343.5, which would put the pill's text on a half point.
    #expect(origin(.topCenter, frame: odd).x == 344)
  }

  // MARK: - Rotation and non-zero origins

  /// The Dell is mounted at 270°, so macOS reports it as 2160x3840 and the pill
  /// goes against THAT, never the manufactured 3840x2160. Against the landscape
  /// frame, top-right lands 1680 points past the right edge of the screen.
  @Test func rotatedBoundsPlaceThePillInsideTheDisplayTheUserIsLookingAt() {
    let portrait = CGRect(x: 3440, y: -1200, width: 2160, height: 3840)
    let manufactured = CGRect(x: 3440, y: -1200, width: 3840, height: 2160)
    for position in HUDPosition.allCases {
      let rect = CGRect(origin: origin(position, frame: portrait), size: pill)
      #expect(portrait.contains(rect), "\(position)")
      #expect(rect.maxY <= portrait.maxY - topInset, "\(position)")
      #expect(origin(position, frame: portrait) != origin(position, frame: manufactured), "\(position)")
    }
    // Spelled as CGFloat: `#expect` type-checks each side separately, so a bare
    // arithmetic literal infers as `Int` and the comparison is not the one it reads as.
    let right: CGFloat = 3440 + 2160 - 314 - 20
    let centre: CGFloat = 3440 + 923
    let top: CGFloat = -1200 + 3840 - 47 - 62 - 20
    #expect(origin(.topRight, frame: portrait).x == right)
    #expect(origin(.topCenter, frame: portrait).x == centre)
    #expect(origin(.topLeft, frame: portrait).x == 3460)
    #expect(origin(.topLeft, frame: portrait).y == top)
  }

  /// A display arranged left of the main one has a negative origin. Nothing in
  /// the math may assume the screen starts at zero.
  @Test func displaysAtNegativeAndOffsetOriginsAreAnchoredToTheirOwnFrame() {
    let left = CGRect(x: -3440, y: -300, width: 3440, height: 1440)
    #expect(origin(.topLeft, frame: left).x == -3420)
    #expect(origin(.topRight, frame: left).x == -334)
    let top: CGFloat = -300 + 1440 - 47 - 62 - 20
    #expect(origin(.topCenter, frame: left).y == top)
  }

  // MARK: - Degenerate screens

  /// A pill wider than the space starts at the left edge rather than off it. The
  /// clamp's inner `max` keeps the upper bound from falling below the lower one.
  @Test func aPillWiderThanTheScreenStartsAtItsLeftEdge() {
    let tiny = CGRect(x: 100, y: 100, width: 200, height: 120)
    for position in HUDPosition.allCases {
      #expect(origin(position, frame: tiny).x == 100, "\(position)")
      #expect(origin(position, frame: tiny).y == 100, "\(position)")
    }
  }

  // MARK: - Fixed anchors

  private func origin(_ anchor: HUDAnchor, size: CGSize, frame: CGRect, visible: CGRect? = nil) -> CGPoint {
    HUDPlacement.origin(
      anchor, size: size, frame: frame, visibleFrame: visible ?? frame,
      topInset: topInset, margin: margin
    )
  }

  /// The Classic box: centred, 140 above the bottom edge of the FULL frame,
  /// which is where macOS draws its own.
  @Test func bottomCenterSitsAtTheMeasuredInsetAboveTheFullFrame() {
    let box = CGSize(width: 200, height: 200)
    let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    let point = origin(.bottomCenter(inset: 140), size: box, frame: screen)
    #expect(point == CGPoint(x: 800, y: 140))
    // A Dock along the bottom shortens the visible frame; the box ignores it.
    let docked = CGRect(x: 0, y: 70, width: 1800, height: 1099)
    #expect(origin(.bottomCenter(inset: 140), size: box, frame: screen, visible: docked).y == 140)
  }

  @Test func centerIsTheFrameCentreRoundedToWholePoints() {
    let box = CGSize(width: 200, height: 200)
    let odd = CGRect(x: 0, y: 0, width: 1001, height: 801)
    let point = origin(.center, size: box, frame: odd)
    #expect(point == CGPoint(x: 401, y: 301))
  }

  /// The notch is centred on the glass, so the top edge uses the full frame even
  /// when a side Dock narrows the visible one.
  @Test func topEdgeIsFlushWithTheTopOnTheFullFrame() {
    let island = CGSize(width: 660, height: 98)
    let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    let dockLeft = CGRect(x: 90, y: 0, width: 1710, height: 1169)
    let point = origin(.topEdge, size: island, frame: screen, visible: dockLeft)
    #expect(point == CGPoint(x: 570, y: 1071))
  }

  /// The Dell at 270 degrees: the box lands inside the rotated frame, 140 above
  /// ITS bottom, never against the manufactured landscape.
  @Test func fixedAnchorsFollowARotatedFrame() {
    let portrait = CGRect(x: 3440, y: -1200, width: 2160, height: 3840)
    let box = CGSize(width: 200, height: 200)
    let bottom = origin(.bottomCenter(inset: 140), size: box, frame: portrait)
    #expect(bottom == CGPoint(x: 3440 + 980, y: -1200 + 140))
    #expect(portrait.contains(CGRect(origin: bottom, size: box)))
    let top = origin(.topEdge, size: CGSize(width: 660, height: 98), frame: portrait)
    #expect(top.y == CGFloat(-1200 + 3840 - 98))
    #expect(top.x == CGFloat(3440 + 750))
  }

  /// The Vertical bar at either side of a laptop screen: 20 in from the edge,
  /// centred on the height. 584.5 - 90 is 494.5, which rounds away from zero.
  @Test func sideCenterSitsAtTheMiddleOfEitherEdge() {
    let bar = CGSize(width: 56, height: 180)
    let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    #expect(origin(.sideCenter(leading: true, margin: 20), size: bar, frame: screen) == CGPoint(x: 20, y: 495))
    #expect(origin(.sideCenter(leading: false, margin: 20), size: bar, frame: screen) == CGPoint(x: 1724, y: 495))
  }

  /// The edge comes from the visible frame, so a pinned left Dock pushes the bar
  /// clear of it; the height still comes from the full frame.
  @Test func sideCenterTakesItsEdgeFromTheVisibleFrame() {
    let bar = CGSize(width: 56, height: 180)
    let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    let dockLeft = CGRect(x: 90, y: 0, width: 1710, height: 1100)
    #expect(origin(.sideCenter(leading: true, margin: 20), size: bar, frame: screen, visible: dockLeft)
      == CGPoint(x: 110, y: 495))
  }

  /// The Dell at 270 degrees: both sides land inside the rotated frame, at the
  /// middle of ITS height.
  @Test func sideCenterFollowsARotatedFrame() {
    let portrait = CGRect(x: 3440, y: -1200, width: 2160, height: 3840)
    let bar = CGSize(width: 56, height: 180)
    let left = origin(.sideCenter(leading: true, margin: 20), size: bar, frame: portrait)
    let right = origin(.sideCenter(leading: false, margin: 20), size: bar, frame: portrait)
    #expect(left == CGPoint(x: 3460, y: 630))
    #expect(right == CGPoint(x: 5524, y: 630))
    #expect(portrait.contains(CGRect(origin: left, size: bar)))
    #expect(portrait.contains(CGRect(origin: right, size: bar)))
  }
}
