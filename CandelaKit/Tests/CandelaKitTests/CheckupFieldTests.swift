import CoreGraphics
import Testing
@testable import CandelaKit

@Suite("Checkup field images")
struct CheckupFieldTests {
  @Test func aBlackFieldIsBlackEverywhereExceptThePlant() throws {
    let plant = CheckupPlant(x: 10, y: 12, size: 4)
    let image = try #require(CheckupField.image(kind: .black, pixelWidth: 64, pixelHeight: 32, plant: plant))
    #expect(CheckupField.pixel(in: image, x: 0, y: 0) == (0, 0, 0))
    #expect(CheckupField.pixel(in: image, x: 63, y: 31) == (0, 0, 0))
    #expect(CheckupField.pixel(in: image, x: 10, y: 12) == (255, 255, 255))
    #expect(CheckupField.pixel(in: image, x: 13, y: 15) == (255, 255, 255))
    #expect(CheckupField.pixel(in: image, x: 14, y: 16) == (0, 0, 0))
  }

  @Test func plantsAreTheContrastingColourPerField() {
    #expect(CheckupField.plantColor(for: .black) == (255, 255, 255))
    #expect(CheckupField.plantColor(for: .white) == (0, 0, 0))
    #expect(CheckupField.plantColor(for: .red) == (0, 0, 0))
  }

  @Test func theGraysAreEncodedNotLinear() throws {
    let g7 = try #require(CheckupField.image(kind: .gray7, pixelWidth: 8, pixelHeight: 8, plant: nil))
    let g50 = try #require(CheckupField.image(kind: .gray50, pixelWidth: 8, pixelHeight: 8, plant: nil))
    #expect(CheckupField.pixel(in: g7, x: 3, y: 3).r == 18)
    #expect(CheckupField.pixel(in: g50, x: 3, y: 3).r == 128)
  }

  @Test func theRampRunsBlackToWhiteLeftToRight() throws {
    let ramp = try #require(CheckupField.image(kind: .ramp, pixelWidth: 256, pixelHeight: 4, plant: nil))
    #expect(CheckupField.pixel(in: ramp, x: 0, y: 1).r == 0)
    #expect(CheckupField.pixel(in: ramp, x: 255, y: 1).r == 255)
    #expect(CheckupField.pixel(in: ramp, x: 128, y: 1).r == 128)
  }

  @Test func theWitnessCardHasACircleAndASquareOnBlack() throws {
    let card = try #require(CheckupField.image(kind: .witness, pixelWidth: 400, pixelHeight: 200, plant: nil))
    #expect(CheckupField.pixel(in: card, x: 2, y: 2) == (0, 0, 0))
    #expect(CheckupField.pixel(in: card, x: 100, y: 100) == (255, 255, 255))
    #expect(CheckupField.pixel(in: card, x: 300, y: 100) == (255, 255, 255))
    #expect(CheckupField.pixel(in: card, x: 100 + 60, y: 100 + 60) == (0, 0, 0))
    #expect(CheckupField.pixel(in: card, x: 300 + 60, y: 100 + 60) == (255, 255, 255))
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

  @Test func luminanceTableMatchesTheFields() {
    #expect(CheckupField.luminance(of: .black) == 0)
    #expect(CheckupField.luminance(of: .white) == 1)
    #expect(abs(CheckupField.luminance(of: .red) - 0.2126) < 0.001)
    #expect(abs(CheckupField.luminance(of: .gray50) - 0.2140) < 0.002)
  }
}
