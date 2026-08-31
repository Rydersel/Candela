import CoreGraphics
import Foundation
import Testing
@testable import CandelaKit

/// SplitMix64. The property tests sample tens of thousands of points, so a failure
/// has to reproduce; `SystemRandomNumberGenerator` makes every run a different test.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

@Suite("Arrangement geometry")
struct ArrangementGeometryTests {
  @Test func aSharedEdgeIsNotOverlap() {
    let a = DisplayRect(x: 0, y: 0, width: 100, height: 100)
    let b = DisplayRect(x: 100, y: 0, width: 100, height: 100)
    #expect(!a.overlaps(b)) // a shared edge is the only legal way to meet
    #expect(a.touches(b))
  }

  @Test func rectsSharingInteriorOverlap() {
    // Every other overlap expectation here is `false`, so a constant-`false`
    // `overlaps` used to pass the suite, and `ArrangementRules` is built on it.
    let a = DisplayRect(x: 0, y: 0, width: 100, height: 100)
    let b = DisplayRect(x: 99, y: -50, width: 100, height: 100) // one point of interior
    #expect(a.overlaps(b))
    #expect(b.overlaps(a)) // symmetric
    #expect(!a.touches(b)) // an overlap is not adjacency

    let contained = DisplayRect(x: 10, y: 10, width: 10, height: 10)
    #expect(a.overlaps(contained))
    #expect(contained.overlaps(a))
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

@Suite("Canvas transform")
struct CanvasTransformTests {
  // MAG, built-in and Dell in an L.
  private static let canvas = CanvasSize(width: 560, height: 320)
  private static let margin: Double = 14
  private static let headroom: Double = 0.18

  private static let rects = [
    DisplayRect(x: 0, y: 0, width: 3440, height: 1440),
    DisplayRect(x: -1470, y: 200, width: 1470, height: 956),
    DisplayRect(x: 3440, y: -300, width: 1200, height: 1920),
  ]

  private var arrangement: DisplayArrangement {
    DisplayArrangement(
      tiles: Self.rects.enumerated().map { ArrangementFixtures.tile(CGDirectDisplayID($0.offset + 1), $0.element) }
    )
  }

  private var transform: CanvasTransform {
    CanvasTransform.fitting(arrangement.bounds, in: Self.canvas, margin: Self.margin, headroom: Self.headroom)
  }

  /// A spread of fits, so R1/R2 are not pinned to one lucky scale: a real L, a small
  /// panel, a bounds far larger than any desktop (worst float error), a scale above 1.
  private var transforms: [CanvasTransform] {
    [
      transform,
      CanvasTransform.fitting(DisplayRect(x: 0, y: 0, width: 640, height: 480), in: Self.canvas),
      CanvasTransform.fitting(DisplayRect(x: -30_000, y: -20_000, width: 90_000, height: 60_000), in: Self.canvas),
      CanvasTransform.fitting(DisplayRect(x: -1, y: -1, width: 3, height: 3), in: Self.canvas, margin: 0, headroom: 0),
      CanvasTransform.fitting(DisplayRect(x: 17, y: -4093, width: 3441, height: 1439), in: CanvasSize(width: 933, height: 401), margin: 7, headroom: 0.31),
    ]
  }

  @Test func r1_displayToCanvasToDisplayIsExact() {
    var rng = SeededGenerator(seed: 0xCA4D_E1A0_0013)
    var failure: String?

    for t in transforms {
      for _ in 0 ..< 20_000 {
        let p = DisplayPoint(x: Int.random(in: -20_000 ... 20_000, using: &rng),
                             y: Int.random(in: -20_000 ... 20_000, using: &rng))
        let back = t.displayPoint(t.canvasPoint(p))
        if back != p {
          failure = "scale=\(t.scale) offset=(\(t.offsetX), \(t.offsetY)) p=(\(p.x), \(p.y)) -> (\(back.x), \(back.y))"
          break
        }
      }
      if failure != nil { break }
    }

    // Exact equality, no tolerance: everything else builds on this mapping.
    #expect(failure == nil, "\(failure ?? "")")
  }

  @Test func r2_canvasToDisplayToCanvasIsWithinHalfAQuantum() {
    var rng = SeededGenerator(seed: 0xCA4D_E1A0_0027)
    var failure: String?

    for t in transforms {
      // scale/2 is the quantum: display space is integral, so a canvas point lands
      // within half a display point of a grid line. The 1e-9 absorbs float error, not slack.
      let bound = t.scale / 2 + 1e-9
      for _ in 0 ..< 5_000 {
        let c = CanvasPoint(x: Double.random(in: -2_000 ... 2_000, using: &rng),
                            y: Double.random(in: -2_000 ... 2_000, using: &rng))
        let back = t.canvasPoint(t.displayPoint(c))
        if abs(back.x - c.x) > bound || abs(back.y - c.y) > bound {
          failure = "scale=\(t.scale) c=(\(c.x), \(c.y)) -> (\(back.x), \(back.y))"
          break
        }
      }
      if failure != nil { break }
    }

    #expect(failure == nil, "\(failure ?? "")")
  }

  @Test func f_everyTileFitsInsideTheCanvas() {
    let t = transform
    for tile in arrangement.tiles {
      let r = t.canvasRect(tile.rect)
      #expect(r.x >= 0)
      #expect(r.y >= 0)
      #expect(r.maxX <= Self.canvas.width)
      #expect(r.maxY <= Self.canvas.height)
      // Headroom reserves slack, so the resting layout also clears the margin.
      #expect(r.x >= Self.margin - 1e-9)
      #expect(r.y >= Self.margin - 1e-9)
      #expect(r.maxX <= Self.canvas.width - Self.margin + 1e-9)
      #expect(r.maxY <= Self.canvas.height - Self.margin + 1e-9)
    }
  }

  @Test func c_theArrangementIsCentred() {
    let r = transform.canvasRect(arrangement.bounds)
    #expect(abs(r.midX - Self.canvas.width / 2) < 1e-9)
    #expect(abs(r.midY - Self.canvas.height / 2) < 1e-9)
  }

  @Test func t_translationInvariance() {
    // This only constrains that the offset tracks the bounds: an offset ignoring
    // them (`offsetX = canvas.width / 2`) moves the picture when the arrangement
    // translates. It does not pin WHICH point lands at the canvas centre, so
    // substituting `cx = bounds.x` stays green here; `c_theArrangementIsCentred`
    // is the test that catches that.
    let base = arrangement
    let baseTransform = CanvasTransform.fitting(base.bounds, in: Self.canvas, margin: Self.margin, headroom: Self.headroom)

    for (dx, dy) in [(1_000, -500), (-7_777, 12_345), (0, 3), (-100_000, -100_000)] {
      let moved = base.translated(dx: dx, dy: dy)
      let movedTransform = CanvasTransform.fitting(moved.bounds, in: Self.canvas, margin: Self.margin, headroom: Self.headroom)

      for tile in base.tiles {
        guard let movedTile = moved.tile(tile.id) else { Issue.record("tile disappeared"); return }
        let before = baseTransform.canvasRect(tile.rect)
        let after = movedTransform.canvasRect(movedTile.rect)
        // Not bitwise identical: s·(x+dx) − s·(cx+dx) and s·x − s·cx round
        // differently. Identical to well under a millionth of a canvas point.
        #expect(abs(after.x - before.x) < 1e-9)
        #expect(abs(after.y - before.y) < 1e-9)
        #expect(after.width == before.width)
        #expect(after.height == before.height)
      }
    }
  }

  @Test func aSingleDisplayCentres() {
    let solo = DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: -1470, y: 733, width: 1470, height: 956)),
    ])
    let t = CanvasTransform.fitting(solo.bounds, in: Self.canvas, margin: Self.margin, headroom: Self.headroom)
    let r = t.canvasRect(solo.bounds)
    #expect(abs(r.midX - Self.canvas.width / 2) < 1e-9)
    #expect(abs(r.midY - Self.canvas.height / 2) < 1e-9)
    #expect(r.x >= Self.margin - 1e-9)
    #expect(r.maxX <= Self.canvas.width - Self.margin + 1e-9)
  }

  /// A `min(fit, 1.0)` clamp in `fitting` left the rest of the suite green: a shrunken
  /// arrangement still fits and is still centred. What it breaks is filling the canvas.
  @Test func f_aSmallArrangementIsScaledUpToFillTheCanvas() {
    let small = DisplayArrangement(tiles: [
      ArrangementFixtures.tile(1, DisplayRect(x: -40, y: 12, width: 100, height: 100)),
    ])
    let t = CanvasTransform.fitting(small.bounds, in: Self.canvas, margin: Self.margin, headroom: Self.headroom)
    #expect(t.scale > 1)

    // Height is the constraining axis for a square in a 560×320 canvas, so the
    // rendered bounds must span exactly what margin and headroom leave there.
    let usable = (Self.canvas.height - 2 * Self.margin) / (1 + 2 * Self.headroom)
    let r = t.canvasRect(small.bounds)
    #expect(abs(r.height - usable) < 1e-9)

    // C and F, on a small-bounds transform.
    #expect(abs(r.midX - Self.canvas.width / 2) < 1e-9)
    #expect(abs(r.midY - Self.canvas.height / 2) < 1e-9)
    #expect(r.x >= Self.margin - 1e-9)
    #expect(r.maxY <= Self.canvas.height - Self.margin + 1e-9)
  }

  /// Exit tests, because a precondition failure kills the process. The paired
  /// `.success` case proves the mechanism can tell the two apart.
  @Test func aNonPositiveOrNonFiniteScaleTrapsAtConstruction() async {
    await #expect(processExitsWith: .failure) { _ = CanvasTransform(scale: 0, offsetX: 0, offsetY: 0) }
    await #expect(processExitsWith: .failure) { _ = CanvasTransform(scale: -1, offsetX: 0, offsetY: 0) }
    await #expect(processExitsWith: .failure) { _ = CanvasTransform(scale: .nan, offsetX: 0, offsetY: 0) }
    await #expect(processExitsWith: .failure) { _ = CanvasTransform(scale: .infinity, offsetX: 0, offsetY: 0) }
    await #expect(processExitsWith: .success) { _ = CanvasTransform(scale: 1, offsetX: 0, offsetY: 0) }
  }

  @Test func aZeroSizeArrangementDoesNotCrash() {
    let t = CanvasTransform.fitting(DisplayArrangement(tiles: []).bounds, in: Self.canvas)
    #expect(t.scale > 0)
    #expect(t.scale.isFinite)
    #expect(t.offsetX.isFinite)
    #expect(t.offsetY.isFinite)
    #expect(t.displayPoint(t.canvasPoint(DisplayPoint(x: 42, y: -7))) == DisplayPoint(x: 42, y: -7))

    // A degenerate rect with one zero side still fits on the other axis.
    let flat = CanvasTransform.fitting(DisplayRect(x: 0, y: 0, width: 3440, height: 0), in: Self.canvas)
    #expect(flat.scale > 0)
    #expect(flat.scale.isFinite)
  }

  @Test func scaleIsInvariantUnderTranslation() {
    let base = CanvasTransform.fitting(arrangement.bounds, in: Self.canvas, margin: Self.margin, headroom: Self.headroom)
    for (dx, dy) in [(1_000, -500), (-7_777, 12_345), (0, 0)] {
      let moved = CanvasTransform.fitting(arrangement.translated(dx: dx, dy: dy).bounds,
                                          in: Self.canvas, margin: Self.margin, headroom: Self.headroom)
      #expect(moved.scale == base.scale) // derived from width/height only
    }
  }

  @Test func distancesConvertWithoutTheOffset() {
    let t = transform
    // A length must not pick up the centring offset — only a point does.
    #expect(t.displayDistance(0) == 0)
    // The snap threshold's own conversion.
    #expect(t.displayDistance(8) == Int((8 / t.scale).rounded()))
  }

  @Test func theInverseRoundsAwayFromZeroRatherThanTruncating() {
    // Truncation biases every negative coordinate one point toward the origin,
    // and negative coordinates are where half of every real setup lives.
    let t = CanvasTransform(scale: 1, offsetX: 0, offsetY: 0)
    #expect(t.displayPoint(CanvasPoint(x: -1.5, y: 1.5)) == DisplayPoint(x: -2, y: 2))
    #expect(t.displayPoint(CanvasPoint(x: -0.6, y: 0.6)) == DisplayPoint(x: -1, y: 1))
    #expect(t.displayDistance(-1.5) == -2)
  }
}
