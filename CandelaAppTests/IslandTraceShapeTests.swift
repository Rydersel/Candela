import CandelaKit
import CoreGraphics
import SwiftUI
import Testing

/// The preview's Island trace converts the Kit's y-up arcs into SwiftUI's
/// y-down space. A reversed turn draws the long way round, three quarters of a
/// circle instead of one, which compiles and still looks like a rounded corner
/// at miniature scale; the bounding box is what tells the two apart.
@Suite("Island trace shape")
struct IslandTraceShapeTests {
  /// One quarter arc, radius 10 about (10, 10) in a 20 pt tall Kit frame.
  private func bounds(start: CGPoint, from: CGFloat, to: CGFloat, clockwise: Bool) -> CGRect {
    IslandTraceShape(
      segments: [
        .move(start),
        .arc(center: CGPoint(x: 10, y: 10), radius: 10, startDegrees: from, endDegrees: to, clockwise: clockwise),
      ],
      kitHeight: 20, scale: 1
    )
    .path(in: .zero)
    .boundingRect
  }

  private func expectClose(_ rect: CGRect, _ expected: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
    let close = abs(rect.minX - expected.minX) < 0.01 && abs(rect.minY - expected.minY) < 0.01
      && abs(rect.width - expected.width) < 0.01 && abs(rect.height - expected.height) < 0.01
    #expect(close, "got \(rect), expected \(expected)", sourceLocation: sourceLocation)
  }

  /// The bottom-left corner as the outline's sides turn it: 180 to 270,
  /// counterclockwise y up. Bottom left in y down is x 0...10, y 10...20.
  @Test func aCounterclockwiseCornerStaysAQuarter() {
    expectClose(bounds(start: CGPoint(x: 0, y: 10), from: 180, to: 270, clockwise: false),
                CGRect(x: 0, y: 10, width: 10, height: 10))
  }

  /// The bottom-right corner as the tab path turns it: 0 to -90, clockwise y up.
  @Test func aClockwiseCornerStaysAQuarter() {
    expectClose(bounds(start: CGPoint(x: 20, y: 10), from: 0, to: -90, clockwise: true),
                CGRect(x: 10, y: 10, width: 10, height: 10))
  }

  /// Positive control: the same corner with the turn reversed runs the long
  /// way and fills the whole circle's box, so the two cases above can fail.
  @Test func aReversedTurnIsVisibleToTheBox() {
    expectClose(bounds(start: CGPoint(x: 0, y: 10), from: 180, to: 270, clockwise: true),
                CGRect(x: 0, y: 0, width: 20, height: 20))
  }
}
