@testable import CandelaKit
import CoreGraphics
import Testing

// The capture request's geometry, and the one property that keeps a band of the
// exposure map from going permanently cold.
//
// ScreenCaptureKit scales a capture to FIT the requested frame and pads the rest
// with black, so a request whose aspect does not match the panel comes back the
// right size with a black band inside it. Black is a luminance, so the band
// accumulated as "this strip was dark" in a store that never washes out. The
// Dell at 270 degrees lost 6 of its 24 panel columns, the built-in would have
// lost 8, and only the MAG escaped because 3440x1440 is a hair off the 24:10
// storage grid it was asked for.
//
// Nothing downstream can see it: the delivered size matches the request, and
// `panelNativeGrid` re-bins a padded grid as faithfully as a full one.
@Suite("Luminance capture geometry")
struct LuminanceReductionGeometryTests {

  // MARK: - The property that matters

  /// Blank space SCK would pad into a request, **in grid cells**, on whichever
  /// axis it falls. Zero when the request's aspect matches the display's.
  ///
  /// The model of SCK's behaviour the fix is built on, measured on all three
  /// panels rather than assumed.
  ///
  /// `pixelsPerCell` keeps the unit honest. The padding falls out in REQUEST
  /// PIXELS, and a request pixel stopped being a cell when `captureOversample`
  /// arrived: reading the raw number as cells would demand the padding stay under
  /// a sixteenth of a cell, far stricter than the property this file is about.
  private func padding(
    displayWidth: Int, displayHeight: Int, request: (Int, Int), pixelsPerCell: Int
  ) -> Double {
    let (w, h) = request
    let scale = min(Double(w) / Double(displayWidth), Double(h) / Double(displayHeight))
    let pixels = max(
      Double(w) - Double(displayWidth) * scale, Double(h) - Double(displayHeight) * scale)
    return pixels / Double(pixelsPerCell)
  }

  /// The rule this replaced: long edge to `PanelGrid.cols`, short to
  /// `PanelGrid.rows`, whatever the panel's aspect. Kept as the positive
  /// control below, so a test that cannot fail is not mistaken for a passing one.
  private func supersededRequest(displayWidth: Int, displayHeight: Int) -> (Int, Int) {
    let long = max(PanelGrid.cols, PanelGrid.rows)
    let short = min(PanelGrid.cols, PanelGrid.rows)
    return displayWidth >= displayHeight ? (long, short) : (short, long)
  }

  /// Every panel in the setup, plus shapes chosen to bracket them.
  private static let displays: [(name: String, width: Int, height: Int)] = [
    ("MAG 341C", 3440, 1440),
    ("Dell U2725QE at 270", 1440, 2560),
    ("Dell U2725QE upright", 3840, 2160),
    ("built-in", 1800, 1169),
    ("16:9", 1920, 1080),
    ("16:10", 1680, 1050),
    ("4:3", 1024, 768),
    ("square", 1000, 1000),
    ("portrait 9:16", 1080, 1920),
    ("very wide", 5120, 1440),
    ("very tall", 1440, 5120),
  ]

  @Test("No panel is padded by a whole cell, so no row or column can go blank")
  func theRequestNeverLeavesAFullCellOfPadding() {
    for display in Self.displays {
      let request = LuminanceReduction.requestedSize(
        displayWidth: display.width, displayHeight: display.height)
      let pad = padding(
        displayWidth: display.width, displayHeight: display.height, request: request,
        pixelsPerCell: LuminanceReduction.captureOversample)
      // Under a cell means the pad lands inside one row or column that still
      // carries real content, never as a fully black one.
      #expect(pad < 1.0, "\(display.name) padded by \(pad) cells with request \(request)")
    }
  }

  /// The fixtures above all pass by a wide margin, so on their own they would not
  /// notice a rule that fails only on a shape nobody owns yet, a virtual display
  /// or an ultra-tall portrait.
  ///
  /// The 16:1 aspect bound is not a fudge. The padding is the short edge's
  /// rounding error scaled back up by the aspect, so it approaches
  /// `aspect / (2 * captureOversample)` cells and crosses a whole cell only past
  /// 32:1, a display 32 times wider than it is tall. Worst case over the sweep:
  /// 0.469 of a cell at 512x8032.
  @Test("A swept range of display shapes is padded by well under a cell")
  func noRealisticDisplayShapeIsPaddedByAWholeCell() {
    var worst = 0.0
    var worstShape = (0, 0)
    var swept = 0
    for width in stride(from: 320, through: 8192, by: 32) {
      for height in stride(from: 320, through: 8192, by: 32) {
        let aspect = Double(width) / Double(height)
        guard aspect <= 16, aspect >= 1.0 / 16 else { continue }
        swept += 1
        let pad = padding(
          displayWidth: width, displayHeight: height,
          request: LuminanceReduction.requestedSize(displayWidth: width, displayHeight: height),
          pixelsPerCell: LuminanceReduction.captureOversample)
        if pad > worst {
          worst = pad
          worstShape = (width, height)
        }
      }
    }
    // Two controls on the sweep itself, because a sweep that covers nothing
    // and a sweep whose metric is stuck at zero both pass silently.
    #expect(swept > 50_000, "the sweep has to be non-trivial, got \(swept) shapes")
    #expect(worst > 0, "the sweep has to reach shapes that pad at all, worst was \(worst)")
    #expect(worst < 1.0, "\(worstShape.0)x\(worstShape.1) padded by \(worst) cells")
  }

  @Test("Positive control: the superseded rule pads whole cells on real panels")
  func theSupersededRuleFailsTheSameProperty() {
    // One request pixel per cell, which is exactly what the superseded rule
    // asked for and what made the raw number readable as cells.
    let dell = supersededRequest(displayWidth: 1440, displayHeight: 2560)
    let dellPad = padding(
      displayWidth: 1440, displayHeight: 2560, request: dell, pixelsPerCell: 1)
    #expect(dell == (10, 24))
    #expect(dellPad >= 6, "expected the measured 6 blank rows, got \(dellPad)")

    let builtIn = supersededRequest(displayWidth: 1800, displayHeight: 1169)
    let builtInPad = padding(
      displayWidth: 1800, displayHeight: 1169, request: builtIn, pixelsPerCell: 1)
    #expect(builtIn == (24, 10))
    #expect(builtInPad >= 8, "expected the measured 8 blank columns, got \(builtInPad)")

    // And the one panel that escaped, which is why this went unnoticed.
    let mag = supersededRequest(displayWidth: 3440, displayHeight: 1440)
    #expect(padding(displayWidth: 3440, displayHeight: 1440, request: mag, pixelsPerCell: 1) < 1.0)
  }

  // MARK: - The measured requests

  @Test("The rig's panels request the sizes measured on the hardware")
  func theRequestsMatchWhatWasMeasured() {
    // Oversampled by `captureOversample` because ScreenCaptureKit's own downscale
    // to a panel-grid request samples rather than area-averages [MEASURED
    // 2026-08-18]. The aspects are unchanged, which is what letterboxing cares about.
    #expect(LuminanceReduction.requestedSize(displayWidth: 3440, displayHeight: 1440) == (384, 161))
    #expect(LuminanceReduction.requestedSize(displayWidth: 1440, displayHeight: 2560) == (216, 384))
    #expect(LuminanceReduction.requestedSize(displayWidth: 1800, displayHeight: 1169) == (384, 249))
  }

  /// 384 is written out rather than recomputed from `PanelGrid.cols` times
  /// `captureOversample`: a test that restates the implementation agrees with any
  /// implementation. What is worth pinning is which AXIS receives it, which a
  /// transposed rule gets wrong on the portrait shapes and nowhere else.
  @Test("The display's own long axis gets the 384-pixel edge, never the other one")
  func theLongEdgeLandsOnTheDisplaysLongAxis() {
    for display in Self.displays {
      let (w, h) = LuminanceReduction.requestedSize(
        displayWidth: display.width, displayHeight: display.height)
      if display.width >= display.height {
        #expect(w == 384 && h <= w, "\(display.name) requested \(w)x\(h)")
      } else {
        #expect(h == 384 && w <= h, "\(display.name) requested \(w)x\(h)")
      }
    }
  }

  /// `LuminanceReduction.captureOversample` makes a resource and privacy claim:
  /// the frame never approaches full resolution, worst case the square fallback.
  /// Nothing asserted it, so raising the factor moved the bound silently.
  @Test("No request exceeds the square fallback, which is the documented ceiling")
  func theRequestStaysUnderItsDocumentedPixelCeiling() {
    let ceiling = 384 * 384
    #expect(LuminanceReduction.requestedSize(displayWidth: 0, displayHeight: 0) == (384, 384))
    for display in Self.displays {
      let (w, h) = LuminanceReduction.requestedSize(
        displayWidth: display.width, displayHeight: display.height)
      #expect(w * h <= ceiling, "\(display.name) requested \(w)x\(h) = \(w * h) pixels")
      // Still strictly more than the grid it reduces to, or the reduction is
      // ScreenCaptureKit's rather than ours.
      #expect(w * h > PanelGrid.cellCount, "\(display.name) requested \(w)x\(h)")
    }
    // The counts the file's own privacy paragraph quotes, pinned rather than only
    // the bound they sit under. The MAG is the largest panel here and asks for
    // the fewest pixels.
    func pixels(_ w: Int, _ h: Int) -> Int {
      let (rw, rh) = LuminanceReduction.requestedSize(displayWidth: w, displayHeight: h)
      return rw * rh
    }
    #expect(pixels(3440, 1440) == 61_824)
    #expect(pixels(1440, 2560) == 82_944)
    #expect(pixels(1800, 1169) == 95_616)
  }

  // MARK: - Degenerate inputs

  @Test("A zero-sized reading falls back to a square request rather than an uncapturable one")
  func aZeroSizedDisplayFallsBackToASquare() {
    let long = max(PanelGrid.cols, PanelGrid.rows) * LuminanceReduction.captureOversample
    #expect(LuminanceReduction.requestedSize(displayWidth: 0, displayHeight: 1440) == (long, long))
    #expect(LuminanceReduction.requestedSize(displayWidth: 3440, displayHeight: 0) == (long, long))
    #expect(LuminanceReduction.requestedSize(displayWidth: -1, displayHeight: -1) == (long, long))
  }

  @Test("An extreme aspect never rounds an edge to zero")
  func neitherEdgeCanRoundToZero() {
    for (w, h) in [(10_000, 1), (1, 10_000), (100_000, 3), (3, 100_000)] {
      let (rw, rh) = LuminanceReduction.requestedSize(displayWidth: w, displayHeight: h)
      #expect(rw >= 1 && rh >= 1, "\(w)x\(h) requested \(rw)x\(rh)")
    }
  }

  // MARK: - What the oversample is for

  /// A full-height white stripe on black. A pixel is white when its CENTRE falls
  /// inside `stripe`, in normalized display coordinates: point sampling on
  /// purpose, because that is what ScreenCaptureKit was measured doing at the
  /// grid size, and the arithmetic keeps the fixture exact at any size.
  private func stripeImage(cols: Int, rows: Int, stripe: Range<Double>) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
      data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let base = context.data!.assumingMemoryBound(to: UInt8.self)
    for x in 0..<cols where stripe.contains((Double(x) + 0.5) / Double(cols)) {
      for y in 0..<rows {
        let offset = y * context.bytesPerRow + x * 4
        base[offset] = 255
        base[offset + 1] = 255
        base[offset + 2] = 255
      }
    }
    return context.makeImage()!
  }

  /// Reduce a stripe through the shipped pair, `meanLuminance` then
  /// `panelNativeGrid`, at whatever request size it was drawn for.
  private func reducedStripe(cols: Int, rows: Int, stripe: Range<Double>) -> [Double] {
    let image = stripeImage(cols: cols, rows: rows, stripe: stripe)
    let luminance = LuminanceReduction.meanLuminance(of: image, cols: cols, rows: rows)!
    let transform = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    return transform.panelNativeGrid(fromDisplayGrid: luminance, cols: cols, rows: rows)
  }

  /// The property the oversample exists to obtain: a feature narrower than a cell
  /// reduces to a PARTIAL value, not to all or nothing. Everything else here
  /// would pass at an oversample of 2.
  ///
  /// The MAG's request is 384x161, so a panel cell is exactly 16 request columns
  /// wide and a 6-column stripe is 0.375 of one. Both stripes sit wholly inside
  /// panel cell 5 (request columns 80 up to 96), so both must read 0.375 wherever
  /// they are placed within it.
  @Test("A stripe narrower than a cell reduces to its area fraction")
  func aSubCellStripeReducesToItsAreaFraction() {
    let (cols, rows) = LuminanceReduction.requestedSize(displayWidth: 3440, displayHeight: 1440)
    #expect((cols, rows) == (384, 161))

    for start in [85, 80] {
      let stripe = Double(start) / 384.0..<Double(start + 6) / 384.0
      let grid = reducedStripe(cols: cols, rows: rows, stripe: stripe)
      for row in 0..<PanelGrid.rows {
        let value = grid[row * PanelGrid.cols + 5]
        #expect(abs(value - 0.375) < 1e-9, "stripe at \(start) read \(value) in row \(row)")
        // The neighbours stay dark, or the stripe leaked and 0.375 could be an
        // average of the wrong thing.
        #expect(grid[row * PanelGrid.cols + 4] == 0)
        #expect(grid[row * PanelGrid.cols + 6] == 0)
      }
    }
  }

  /// Positive control for the test above, and the reason `captureOversample` is
  /// not 1. At one sample per cell a sub-cell stripe can only land on that sample
  /// or miss it: the same two stripes, both truly 0.375 of cell 5, read 1.0 and 0.0.
  @Test("Positive control: at the grid size the same stripe reads all or nothing")
  func theUnOversampledRequestCannotExpressAFraction() {
    let readings = [85, 80].map { start -> Double in
      let stripe = Double(start) / 384.0..<Double(start + 6) / 384.0
      return reducedStripe(cols: PanelGrid.cols, rows: PanelGrid.rows, stripe: stripe)[5]
    }
    #expect(abs(readings[0] - 1.0) < 1e-9, "expected the sample to be inside the stripe")
    #expect(readings[1] == 0, "expected the sample to miss the stripe")
  }

  // MARK: - The consequence downstream

  @Test("An aspect-matched grid fills every panel cell, a padded one does not")
  func theDeadBandReachesTheStoredMapOnlyWhenThePaddingDoes() {
    // The Dell's real configuration: a portrait framebuffer at 270 degrees,
    // where blank display ROWS become blank PANEL COLUMNS.
    let transform = PanelSpaceTransform(
      displaySize: CGSize(width: 1440, height: 2560), rotation: .twoSeventy)

    let (fixedCols, fixedRows) = LuminanceReduction.requestedSize(
      displayWidth: 1440, displayHeight: 2560)
    let lit = [Double](repeating: 1.0, count: fixedCols * fixedRows)
    let fixed = transform.panelNativeGrid(
      fromDisplayGrid: lit, cols: fixedCols, rows: fixedRows)
    #expect(fixed.allSatisfy { $0 > 0 }, "the fix must leave no cell unlit")

    // The same panel under the superseded request, with SCK's 6 rows of black
    // padding at the bottom of the frame.
    var padded = [Double](repeating: 1.0, count: 10 * 24)
    for row in 18..<24 { for col in 0..<10 { padded[row * 10 + col] = 0 } }
    let damaged = transform.panelNativeGrid(fromDisplayGrid: padded, cols: 10, rows: 24)
    let deadColumns = (0..<PanelGrid.cols).filter { col in
      (0..<PanelGrid.rows).allSatisfy { damaged[$0 * PanelGrid.cols + col] == 0 }
    }
    #expect(deadColumns == [0, 1, 2, 3, 4, 5], "the stored signature was 6 dead panel columns")
  }
}

// The wallpaper is scaled to FILL a display and its overflow cropped; the
// reduction stretches whatever it is handed. On the rotated Dell that difference
// measured 0.186 against 0.584 correlation with the panel's own capture.
@Suite("Wallpaper crop to fill")
struct WallpaperCropTests {

  private func image(width: Int, height: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return context.makeImage()!
  }

  @Test("a wide image loses width, not height")
  func landscapeIntoPortrait() {
    let cropped = LuminanceReduction.cropToFill(image(width: 3840, height: 2160), aspect: 14.0 / 24)
    #expect(cropped.height == 2160)
    // `CGRect.integral` expands outward, so a pixel either way is expected.
    #expect(abs(cropped.width - Int((2160.0 * 14 / 24).rounded())) <= 1)
  }

  @Test("a tall image loses height, not width")
  func portraitIntoLandscape() {
    let cropped = LuminanceReduction.cropToFill(image(width: 1000, height: 4000), aspect: 24.0 / 10)
    #expect(cropped.width == 1000)
    #expect(abs(cropped.height - Int((1000.0 / 2.4).rounded())) <= 1)
  }

  @Test("a matching aspect is left alone")
  func matchingAspectIsUntouched() {
    let source = image(width: 2400, height: 1000)
    let cropped = LuminanceReduction.cropToFill(source, aspect: 2.4)
    #expect(cropped.width == 2400)
    #expect(cropped.height == 1000)
  }

  @Test("a nonsense aspect degrades to the original rather than to nothing")
  func degenerateAspectIsSafe() {
    let source = image(width: 100, height: 100)
    for aspect in [0.0, -1.0, Double.nan, Double.infinity] {
      let cropped = LuminanceReduction.cropToFill(source, aspect: aspect)
      #expect(cropped.width == 100 && cropped.height == 100)
    }
  }
}
