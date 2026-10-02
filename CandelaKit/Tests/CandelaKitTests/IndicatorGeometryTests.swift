import CoreGraphics
import Testing
@testable import CandelaKit

@Suite("Indicator geometry")
struct IndicatorGeometryTests {
  /// A half step lights the nearer chiclet, the rule the segmented pill shipped with.
  @Test func filledStepsRound() {
    #expect(IndicatorSteps.filled(0, of: 16) == 0)
    #expect(IndicatorSteps.filled(9.0 / 16, of: 16) == 9)
    #expect(IndicatorSteps.filled(0.53, of: 16) == 8)
    #expect(IndicatorSteps.filled(1, of: 16) == 16)
    #expect(IndicatorSteps.filled(1.4, of: 16) == 16)
    #expect(IndicatorSteps.filled(-0.2, of: 16) == 0)
  }

  /// Measured from the system's own box: 200 square, a 161 by 8 track 20 up,
  /// sixteen 9 by 6 chiclets on a 10 pt pitch from x 21.
  @Test func classicBoxMatchesTheMeasuredSystemBox() {
    #expect(ClassicBox.size == CGSize(width: 200, height: 200))
    #expect(ClassicBox.cornerRadius == 16)
    #expect(ClassicBox.trackRect == CGRect(x: 20, y: 20, width: 161, height: 8))
    #expect(ClassicBox.chicletRect(0) == CGRect(x: 21, y: 21, width: 9, height: 6))
    #expect(ClassicBox.chicletRect(15).maxX == 180)
    #expect(ClassicBox.glyphRect == CGRect(x: 15, y: 15, width: 170, height: 170))
  }

  @Test func sequoiaBarFillsFromTheLeft() {
    #expect(SequoiaBox.size == CGSize(width: 92, height: 92))
    #expect(SequoiaBox.barRect == CGRect(x: 20, y: 16, width: 52, height: 3))
    #expect(SequoiaBox.fillRect(value: 0.5).width == 26)
    #expect(SequoiaBox.fillRect(value: 0).width == 3)
  }

  @Test func verticalFillRisesFromTheBottom() {
    #expect(VerticalPill.size == CGSize(width: 56, height: 180))
    #expect(VerticalPill.fillHeight(value: 0.5) == 90)
    #expect(VerticalPill.fillHeight(value: 0) == 0)
    #expect(VerticalPill.fillHeight(value: 2) == 180)
  }

  /// Twelve o'clock is 90 degrees in AppKit's y-up frame; the arc sweeps clockwise.
  @Test func ringSweepsClockwiseFromTwelve() {
    #expect(RingDial.size == CGSize(width: 120, height: 120))
    #expect(RingDial.radius == 40)
    #expect(RingDial.sweepEndDegrees(value: 0.25) == 0)
    #expect(RingDial.sweepEndDegrees(value: 1) == -270)
    let top = RingDial.dotCenter(0)
    #expect(abs(top.x - 60) < 0.001 && abs(top.y - 109) < 0.001)
    let right = RingDial.dotCenter(4)
    #expect(abs(right.x - 109) < 0.001 && abs(right.y - 60) < 0.001)
  }
}
