import CoreGraphics
import Foundation
import Testing

@testable import CandelaKit

@Suite("Overlay mask")
struct OverlayMaskTests {

  private func cells(_ value: Double = 0) -> [Double] {
    [Double](repeating: value, count: PanelGrid.cellCount)
  }

  // MARK: - Quantization, and why it exists

  /// **The load-bearing property.** `OledOverlay` skips the window-server round
  /// trip when the applied state is unchanged. A mask derived from live
  /// luminance differs in the twelfth decimal every tick, so without this every
  /// apply is a memo miss and the overlay re-orders ~10 times a second per
  /// display, each time re-stacking above whatever else is at shielding level.
  @Test func masksDifferingBelowTheQuantumAreEqual() {
    var a = cells(0.5)
    var b = a
    b[7] = 0.5 + 1e-9
    a[0] = 0.5
    #expect(OverlayMask(cells: a) == OverlayMask(cells: b))
  }

  @Test func masksDifferingAboveTheQuantumAreNot() {
    var a = cells(0.5)
    var b = a
    b[7] = 0.5 + (2.0 / 255.0)
    a[0] = 0.5
    #expect(OverlayMask(cells: a) != OverlayMask(cells: b))
  }

  /// The quantum is 1/255 because the rendered mask is an 8-bit image. A finer
  /// grid would be a distinction that never reaches the screen but does reach
  /// the memo, which is the worst of both.
  @Test func theQuantumMatchesTheRenderPrecision() {
    #expect(OverlayMask.quantize(0.5) == 128.0 / 255.0)
    #expect(OverlayMask.quantize(0) == 0)
    #expect(OverlayMask.quantize(1) == 1)
  }

  @Test func valuesAreClampedIntoRange() {
    let mask = OverlayMask(cells: [1.5, -0.5] + cells().dropFirst(2))
    #expect(mask.cells[0] == 1.0)
    #expect(mask.cells[1] == 0.0)
  }

  /// Both non-finite cases go to TRANSPARENT, including `+infinity`, which
  /// clamping alone would have sent to fully opaque. An infinite alpha is not a
  /// request to black the cell out, it is evidence that the arithmetic upstream
  /// broke, and the safe reading of a broken number is to cover nothing.
  @Test func aNonFiniteCellBecomesTransparentRatherThanOpaque() {
    var poisoned = cells(0.5)
    poisoned[3] = .nan
    poisoned[4] = .infinity
    poisoned[5] = -.infinity
    let mask = OverlayMask(cells: poisoned)
    #expect(mask.cells[3] == 0)
    #expect(mask.cells[4] == 0)
    #expect(mask.cells[5] == 0)
    #expect(mask.cells.allSatisfy { $0.isFinite })
  }

  /// A partially-applied mask is a visible artifact on the user's screen, so a
  /// malformed one covers nothing rather than covering something wrong.
  @Test func aWrongLengthMaskCoversNothing() {
    let mask = OverlayMask(cells: [0.9, 0.9, 0.9])
    #expect(mask.cells.count == PanelGrid.cellCount)
    #expect(mask.cells.allSatisfy { $0 == 0 })
  }

  // MARK: - Uniformity

  @Test func aUniformMaskKnowsItIsUniform() {
    #expect(OverlayMask.uniform(0.4).isUniform)
    var bumpy = cells(0.4)
    bumpy[100] = 0.9
    #expect(!OverlayMask(cells: bumpy).isUniform)
  }

  @Test func uniformFillsEveryCell() {
    let mask = OverlayMask.uniform(0.3)
    #expect(mask.cells.count == PanelGrid.cellCount)
    #expect(mask.peak == OverlayMask.quantize(0.3))
  }

  // MARK: - Composition

  /// Detection dimming layers on top of the uniform dim already in force and
  /// may only take a region FURTHER down. Averaging would let a nominated
  /// region come out lighter than the level the user chose, which reads as the
  /// feature undoing the setting.
  @Test func composingTakesTheDarkerOfEachCell() {
    var regions = cells(0)
    regions[10] = 0.8
    let composed = OverlayMask.uniform(0.5).darkened(by: OverlayMask(cells: regions))

    #expect(composed.cells[10] == OverlayMask.quantize(0.8))
    #expect(composed.cells[11] == OverlayMask.quantize(0.5))
  }

  @Test func composingNeverLightensAnyCell() {
    var patchy = cells(0.1)
    patchy[5] = 0.95
    let base = OverlayMask.uniform(0.6)
    let composed = base.darkened(by: OverlayMask(cells: patchy))
    for index in composed.cells.indices {
      #expect(composed.cells[index] >= base.cells[index])
    }
  }

  // MARK: - Orientation

  @Test func anUprightMaskIsUnchanged() {
    var seeded = cells(0)
    seeded[0] = 1.0
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 3440, height: 1440), rotation: .standard)
    let out = OverlayMask(cells: seeded).displayOriented(through: t)

    #expect(out.cols == PanelGrid.cols)
    #expect(out.rows == PanelGrid.rows)
    #expect(out.cells[0] == 1.0)
    #expect(out.cells[1] == 0.0)
  }

  /// The Dell case, and the mirror image of `PanelSpaceTransformTests`'
  /// `rotatedDisplayTopLeftMapsToPanelTopRight`. A mask hot at the panel's
  /// top-right must come back hot at the DISPLAY's top-left, or a nominated
  /// region dims the wrong corner of a rotated monitor.
  @Test func aRotatedMaskComesBackInDisplayOrientation() {
    var seeded = cells(0)
    seeded[PanelGrid.cols - 1] = 1.0  // panel top-right
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .twoSeventy)
    let out = OverlayMask(cells: seeded).displayOriented(through: t)

    // Axes swap: the display grid is 10 wide by 24 tall.
    #expect(out.cols == PanelGrid.rows)
    #expect(out.rows == PanelGrid.cols)
    #expect(out.cells[0] == 1.0, "the panel's top-right must land at the display's top-left")
  }

  @Test func everyDisplayCellIsWrittenInEveryRotation() {
    let seeded = OverlayMask.uniform(0.7)
    for rotation in DisplayRotation.allCases {
      let size =
        rotation.swapsAxes
        ? CGSize(width: 2160, height: 3840) : CGSize(width: 3840, height: 2160)
      let t = PanelSpaceTransform(displaySize: size, rotation: rotation)
      let out = seeded.displayOriented(through: t)
      #expect(out.cells.count == out.cols * out.rows)
      // A reverse walk would leave holes wherever the mapping is not onto; a
      // uniform mask makes any hole show up as a zero.
      #expect(
        out.cells.allSatisfy { $0 == OverlayMask.quantize(0.7) },
        "\(rotation) left an unwritten display cell")
    }
  }

  /// **The memo guard, end to end.** `OledOverlay` compares `Oriented` values,
  /// not `OverlayMask` values, so quantizing the mask is only useful if the
  /// property survives orientation. This simulates what actually happens: two
  /// consecutive luminance samples that differ by less than the render can show
  /// must produce an EQUAL oriented mask, or every apply is a memo miss and the
  /// overlay re-orders ten times a second per display.
  ///
  /// There is no app test target, so this is the only place the property is
  /// checkable at all.
  @Test func sensorNoiseBelowTheQuantumDoesNotChangeTheOrientedMask() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .twoSeventy)
    var reading = (0..<PanelGrid.cellCount).map { Double($0) / Double(PanelGrid.cellCount) }
    let first = OverlayMask(cells: reading).displayOriented(through: t)

    // A second sample, jittered by far less than 1/255 in every cell.
    reading = reading.enumerated().map { index, value in
      value + (index % 2 == 0 ? 1e-7 : -1e-7)
    }
    let second = OverlayMask(cells: reading).displayOriented(through: t)

    #expect(first == second)
  }

  /// The other half: a change the screen CAN show must not be memoized away.
  @Test func aVisibleChangeDoesChangeTheOrientedMask() {
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .twoSeventy)
    var reading = cells(0.5)
    let first = OverlayMask(cells: reading).displayOriented(through: t)
    reading[100] = 0.5 + (3.0 / 255.0)
    #expect(first != OverlayMask(cells: reading).displayOriented(through: t))
  }

  @Test func orientingIsStableAcrossRepeatedCalls() {
    var seeded = cells(0.2)
    seeded[42] = 0.9
    let t = PanelSpaceTransform(
      displaySize: CGSize(width: 2160, height: 3840), rotation: .ninety)
    let mask = OverlayMask(cells: seeded)
    #expect(mask.displayOriented(through: t).cells == mask.displayOriented(through: t).cells)
  }
}
