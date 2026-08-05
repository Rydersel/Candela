import Foundation
import Testing
@testable import CandelaKit

@Suite("Arrangement geometry")
struct ArrangementGeometryTests {
  @Test func aSharedEdgeIsNotOverlap() {
    let a = DisplayRect(x: 0, y: 0, width: 100, height: 100)
    let b = DisplayRect(x: 100, y: 0, width: 100, height: 100)
    #expect(!a.overlaps(b)) // a shared edge is the only legal way to meet
    #expect(a.touches(b))
  }

  @Test func cornerOnlyContactIsNotAdjacency() {
    let a = DisplayRect(x: 0, y: 0, width: 100, height: 100)
    let b = DisplayRect(x: 100, y: 100, width: 100, height: 100)
    #expect(!a.touches(b))
    #expect(!a.overlaps(b))
  }

  @Test func aZeroLengthSharedEdgeIsNotAdjacency() {
    let a = DisplayRect(x: 0, y: 0, width: 100, height: 100)
    let b = DisplayRect(x: 100, y: -50, width: 100, height: 50)
    #expect(!a.touches(b)) // edges meet at exactly one point
  }

  @Test func negativeWidthIsClampedToZero() {
    #expect(DisplayRect(x: 0, y: 0, width: -10, height: 5).width == 0)
  }

  @Test func unionOfNoRectsIsNil() { #expect(DisplayRect.union([]) == nil) }

  @Test func unionSpansEveryRect() {
    let u = DisplayRect.union([
      DisplayRect(x: -100, y: 0, width: 100, height: 100),
      DisplayRect(x: 0, y: -50, width: 200, height: 100),
    ])
    #expect(u == DisplayRect(x: -100, y: -50, width: 300, height: 150))
  }

  @Test func offsetAndMovedAgreeOnTheResultingOrigin() {
    let r = DisplayRect(x: 10, y: 20, width: 30, height: 40)
    #expect(r.offset(dx: 5, dy: -5).origin == DisplayPoint(x: 15, y: 15))
    #expect(r.moved(to: DisplayPoint(x: 15, y: 15)) == r.offset(dx: 5, dy: -5))
  }
}
