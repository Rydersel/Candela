@testable import CandelaKit
import CoreGraphics
import Testing

// The capture request's geometry, and the one property that keeps a band of
// the exposure map from going permanently cold.
//
// The defect these exist to catch ran for four days on the rig without anyone
// seeing it. ScreenCaptureKit scales a capture to FIT the requested frame and
// pads the remainder with black, so a request whose aspect does not match the
// panel comes back the right size with a black band inside it. Black is a
// luminance, so the band accumulated as "this strip was dark" in a store that
// never washes out. The Dell at 270 degrees lost 6 of its 24 panel columns and
// the built-in would have lost 8; only the MAG escaped, because 3440x1440 is a
// hair off the 24:10 storage grid it was being asked for.
//
// Nothing downstream can see this: the delivered size matches the request, and
// `panelNativeGrid` re-bins a padded grid as faithfully as a full one.
@Suite("Luminance capture geometry")
struct LuminanceReductionGeometryTests {

  // MARK: - The property that matters

  /// Blank space SCK would pad into a request, in cells, on whichever axis it
  /// falls. Zero when the request's aspect matches the display's.
  ///
  /// This is the model of SCK's behaviour that the fix is built on; it was
  /// measured on all three panels rather than assumed.
  private func padding(displayWidth: Int, displayHeight: Int, request: (Int, Int)) -> Double {
    let (w, h) = request
    let scale = min(Double(w) / Double(displayWidth), Double(h) / Double(displayHeight))
    return max(Double(w) - Double(displayWidth) * scale, Double(h) - Double(displayHeight) * scale)
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
        displayWidth: display.width, displayHeight: display.height, request: request)
      // Under a cell means the pad lands inside one row or column that still
      // carries real content, never as a fully black one.
      #expect(pad < 1.0, "\(display.name) padded by \(pad) cells with request \(request)")
    }
  }

  @Test("Positive control: the superseded rule pads whole cells on real panels")
  func theSupersededRuleFailsTheSameProperty() {
    let dell = supersededRequest(displayWidth: 1440, displayHeight: 2560)
    let dellPad = padding(displayWidth: 1440, displayHeight: 2560, request: dell)
    #expect(dell == (10, 24))
    #expect(dellPad >= 6, "expected the measured 6 blank rows, got \(dellPad)")

    let builtIn = supersededRequest(displayWidth: 1800, displayHeight: 1169)
    let builtInPad = padding(displayWidth: 1800, displayHeight: 1169, request: builtIn)
    #expect(builtIn == (24, 10))
    #expect(builtInPad >= 8, "expected the measured 8 blank columns, got \(builtInPad)")

    // And the one panel that escaped, which is why this went unnoticed.
    let mag = supersededRequest(displayWidth: 3440, displayHeight: 1440)
    #expect(padding(displayWidth: 3440, displayHeight: 1440, request: mag) < 1.0)
  }

  // MARK: - The measured requests

  @Test("The rig's panels request the sizes measured on the hardware")
  func theRequestsMatchWhatWasMeasured() {
    #expect(LuminanceReduction.requestedSize(displayWidth: 3440, displayHeight: 1440) == (24, 10))
    #expect(LuminanceReduction.requestedSize(displayWidth: 1440, displayHeight: 2560) == (14, 24))
    #expect(LuminanceReduction.requestedSize(displayWidth: 1800, displayHeight: 1169) == (24, 16))
  }

  @Test("The long edge stays at grid resolution, so the sample size does not grow")
  func theLongEdgeIsAlwaysTwentyFour() {
    for display in Self.displays {
      let (w, h) = LuminanceReduction.requestedSize(
        displayWidth: display.width, displayHeight: display.height)
      #expect(max(w, h) == max(PanelGrid.cols, PanelGrid.rows), "\(display.name) requested \(w)x\(h)")
    }
  }

  // MARK: - Degenerate inputs

  @Test("A zero-sized reading falls back to a square request rather than an uncapturable one")
  func aZeroSizedDisplayFallsBackToASquare() {
    let long = max(PanelGrid.cols, PanelGrid.rows)
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
