import CoreGraphics
import Testing
@testable import CandelaKit

@Suite("Screen clamp")
struct ScreenClampTests {
  @Test func aSpanThatFitsIsHeldInsideBothEnds() {
    #expect(ScreenClamp.clamped(50, length: 100, lower: 0, upper: 400) == 50)
    #expect(ScreenClamp.clamped(-20, length: 100, lower: 0, upper: 400) == 0)
    #expect(ScreenClamp.clamped(350, length: 100, lower: 0, upper: 400) == 300)
  }

  /// Guards the inner `max`: a plain `min(max(...))` lands the span off the near edge.
  @Test func aSpanLongerThanItsScreenIsPinnedToTheNearEdge() {
    #expect(ScreenClamp.clamped(-300, length: 500, lower: 100, upper: 300) == 100)
    #expect(ScreenClamp.clamped(250, length: 500, lower: 100, upper: 300) == 100)
    #expect(ScreenClamp.clamped(900, length: 500, lower: 100, upper: 300) == 100)
  }
}
