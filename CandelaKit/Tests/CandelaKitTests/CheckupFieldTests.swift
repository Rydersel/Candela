import CoreGraphics
import Testing
@testable import CandelaKit

@Suite("Checkup field images")
struct CheckupFieldTests {
  @Test func aBlackFieldIsBlackEverywhereExceptThePlant() throws {
    let plant = CheckupPlant(x: 10, y: 12, size: 4)
    let image = try #require(CheckupField.image(kind: .black, pixelWidth: 64, pixelHeight: 32, plant: plant))
    #expect(try #require(CheckupField.pixel(in: image, x: 0, y: 0)) == (0, 0, 0))
    #expect(try #require(CheckupField.pixel(in: image, x: 63, y: 31)) == (0, 0, 0))
    #expect(try #require(CheckupField.pixel(in: image, x: 10, y: 12)) == (255, 255, 255))
    #expect(try #require(CheckupField.pixel(in: image, x: 13, y: 15)) == (255, 255, 255))
    #expect(try #require(CheckupField.pixel(in: image, x: 14, y: 16)) == (0, 0, 0))
  }

  @Test func plantsAreTheContrastingColourPerField() {
    #expect(CheckupField.plantColor(for: .black) == (255, 255, 255))
    #expect(CheckupField.plantColor(for: .white) == (0, 0, 0))
    #expect(CheckupField.plantColor(for: .red) == (0, 0, 0))
  }

  @Test func theGraysAreEncodedNotLinear() throws {
    let g7 = try #require(CheckupField.image(kind: .gray7, pixelWidth: 8, pixelHeight: 8, plant: nil))
    let g50 = try #require(CheckupField.image(kind: .gray50, pixelWidth: 8, pixelHeight: 8, plant: nil))
    #expect(try #require(CheckupField.pixel(in: g7, x: 3, y: 3)).r == 18)
    #expect(try #require(CheckupField.pixel(in: g50, x: 3, y: 3)).r == 128)
  }

  @Test func theRedAndBlueFieldsKeepChannelOrder() throws {
    let red = try #require(CheckupField.image(kind: .red, pixelWidth: 8, pixelHeight: 8, plant: nil))
    let blue = try #require(CheckupField.image(kind: .blue, pixelWidth: 8, pixelHeight: 8, plant: nil))
    #expect(try #require(CheckupField.pixel(in: red, x: 3, y: 3)) == (255, 0, 0))
    #expect(try #require(CheckupField.pixel(in: blue, x: 3, y: 3)) == (0, 0, 255))
  }

  @Test func theRampRunsBlackToWhiteLeftToRight() throws {
    let ramp = try #require(CheckupField.image(kind: .ramp, pixelWidth: 256, pixelHeight: 4, plant: nil))
    #expect(try #require(CheckupField.pixel(in: ramp, x: 0, y: 1)).r == 0)
    #expect(try #require(CheckupField.pixel(in: ramp, x: 255, y: 1)).r == 255)
    #expect(try #require(CheckupField.pixel(in: ramp, x: 128, y: 1)).r == 128)
  }

  @Test func theWitnessCardHasACircleAndASquareOnBlack() throws {
    let card = try #require(CheckupField.image(kind: .witness, pixelWidth: 400, pixelHeight: 200, plant: nil))
    #expect(try #require(CheckupField.pixel(in: card, x: 2, y: 2)) == (0, 0, 0))
    #expect(try #require(CheckupField.pixel(in: card, x: 100, y: 100)) == (255, 255, 255))
    #expect(try #require(CheckupField.pixel(in: card, x: 300, y: 100)) == (255, 255, 255))
    #expect(try #require(CheckupField.pixel(in: card, x: 100 + 60, y: 100 + 60)) == (0, 0, 0))
    #expect(try #require(CheckupField.pixel(in: card, x: 300 + 60, y: 100 + 60)) == (255, 255, 255))
  }

  @Test func fieldsThatDoNotCarryAPlantIgnoreOne() throws {
    // gray7 is flat, so any drawn plant would read as plantColor's black
    // instead of the field's own (18, 18, 18) at the plant's coordinates.
    let plant = CheckupPlant(x: 3, y: 3, size: 2)
    let gray7 = try #require(CheckupField.image(kind: .gray7, pixelWidth: 8, pixelHeight: 8, plant: plant))
    #expect(try #require(CheckupField.pixel(in: gray7, x: 3, y: 3)) == (18, 18, 18))

    // Placed inside the witness card's square: a drawn plant would show
    // plantColor's black there instead of the square's white.
    let witnessPlant = CheckupPlant(x: 5, y: 3, size: 2)
    let witness = try #require(CheckupField.image(kind: .witness, pixelWidth: 8, pixelHeight: 8, plant: witnessPlant))
    #expect(try #require(CheckupField.pixel(in: witness, x: 5, y: 3)) == (255, 255, 255))
  }

  @Test func plantPositionsStayInsideTheMarginAndAreSeedDeterministic() {
    var a = SystemRandomNumberGenerator()
    for _ in 0..<50 {
      let p = CheckupField.plantPosition(width: 3840, height: 2160, size: 8, using: &a)
      #expect(p.x >= 192 && p.x + 8 <= 3840 - 192)
      #expect(p.y >= 108 && p.y + 8 <= 2160 - 108)
    }
    var s1 = SeededGenerator(seed: 7), s2 = SeededGenerator(seed: 7)
    #expect(CheckupField.plantPosition(width: 100, height: 100, size: 4, using: &s1)
      == CheckupField.plantPosition(width: 100, height: 100, size: 4, using: &s2))
  }

  @Test func aPlantLargerThanTheUsableAreaLandsAtTheMarginInsteadOfTrapping() {
    var rng = SeededGenerator(seed: 1)
    let p = CheckupField.plantPosition(width: 20, height: 20, size: 100, using: &rng)
    #expect(p.x == 1)
    #expect(p.y == 1)
  }

  /// 3024x1964 in a 982 pt view is the built-in, the panel a one-display run
  /// actually happens on; the 104 pt strip covers its bottom edge.
  @Test func aBottomExclusionKeepsEveryPlantOutOfTheStripBand() {
    let height = 1964
    let band = Int(104.0 * Double(height) / 982.0)
    #expect(band == 208)
    for seed in 0..<500 {
      var rng = SeededGenerator(seed: UInt64(seed))
      let p = CheckupField.plantPosition(
        width: 3024, height: height, size: 8, bottomExclusion: band, using: &rng)
      #expect(p.y + p.size <= height - band, "seed \(seed) planted at y=\(p.y)")
      #expect(p.y >= height / 20, "seed \(seed) planted at y=\(p.y)")
    }
  }

  /// The positive control for the test above: without the band the same seeds do
  /// reach into it, so the assertion is one that can fail.
  @Test func withoutTheExclusionSomeSeedsLandInTheStripBand() {
    let height = 1964, band = 208
    var reached = 0
    for seed in 0..<500 {
      var rng = SeededGenerator(seed: UInt64(seed))
      let p = CheckupField.plantPosition(width: 3024, height: height, size: 8, using: &rng)
      if p.y + p.size > height - band { reached += 1 }
    }
    #expect(reached > 0)
  }

  /// A zero size makes the witness card's coverage NaN, and the exposure
  /// booking's clamp passes NaN through as full white.
  @Test func luminanceIsZeroRatherThanNaNOnAZeroSizedSurface() {
    for kind in CheckupFieldKind.allCases {
      #expect(CheckupField.luminance(of: kind, pixelWidth: 0, pixelHeight: 0) == 0, "\(kind)")
      #expect(CheckupField.luminance(of: kind, pixelWidth: 100, pixelHeight: 0) == 0, "\(kind)")
      #expect(CheckupField.luminance(of: kind, pixelWidth: 0, pixelHeight: 100) == 0, "\(kind)")
    }
  }

  /// Out of bounds must be nil and not a read past the buffer, and never a
  /// plausible black pixel.
  @Test func pixelRefusesCoordinatesTheImageDoesNotHave() throws {
    let image = try #require(
      CheckupField.image(kind: .white, pixelWidth: 8, pixelHeight: 4, plant: nil))
    #expect(CheckupField.pixel(in: image, x: 8, y: 0) == nil)
    #expect(CheckupField.pixel(in: image, x: 0, y: 4) == nil)
    #expect(CheckupField.pixel(in: image, x: -1, y: 0) == nil)
    #expect(CheckupField.pixel(in: image, x: 0, y: -1) == nil)
    #expect(CheckupField.pixel(in: image, x: 7, y: 3) != nil)
  }

  @Test func luminanceTableMatchesTheFields() {
    #expect(CheckupField.luminance(of: .black, pixelWidth: 3840, pixelHeight: 2160) == 0)
    #expect(CheckupField.luminance(of: .white, pixelWidth: 3840, pixelHeight: 2160) == 1)
    #expect(abs(CheckupField.luminance(of: .red, pixelWidth: 3840, pixelHeight: 2160) - 0.2126) < 0.001)
    #expect(abs(CheckupField.luminance(of: .gray50, pixelWidth: 3840, pixelHeight: 2160) - 0.2159) < 0.0005)
    #expect(abs(CheckupField.luminance(of: .witness, pixelWidth: 3840, pixelHeight: 2160) - 0.446) < 0.005)
    #expect(abs(CheckupField.luminance(of: .ramp, pixelWidth: 3840, pixelHeight: 2160) - 0.3106) < 0.002)
  }
}
