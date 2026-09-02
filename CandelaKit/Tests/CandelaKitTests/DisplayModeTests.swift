import Foundation
import Testing
@testable import CandelaKit

@Suite("Display mode model")
struct DisplayModeTests {
  private func mode(
    logical: (Int, Int), pixels: (Int, Int), hz: Double = 60,
    native: Bool = false
  ) -> DisplayMode {
    DisplayMode(
      ioModeID: 1, logicalWidth: logical.0, logicalHeight: logical.1,
      pixelWidth: pixels.0, pixelHeight: pixels.1, refreshHz: hz,
      isNative: native
    )
  }

  @Test func hiDPIIsAFramebufferAtLeastTwiceTheLogicalWidth() {
    #expect(mode(logical: (2560, 1440), pixels: (5120, 2880)).isHiDPI)
    #expect(!mode(logical: (2560, 1440), pixels: (2560, 1440)).isHiDPI)

    // Separates ">= 2x" from "any upscale at all": a 1.5x mode renders oversized
    // but is not HiDPI, and `pixelWidth > logicalWidth` would satisfy the other
    // two assertions on its own.
    #expect(!mode(logical: (1920, 1080), pixels: (2880, 1620)).isHiDPI)
  }

  /// isScaled must compare against the PANEL's native pixels, not the mode's
  /// own logical width. Using CGDisplayPixelsWide (the current mode's logical
  /// size) would make every mode report as native.
  @Test func scaledMeansTheFramebufferIsNotThePanelsNativePixelCount() {
    let native = mode(logical: (1080, 1920), pixels: (2160, 3840), native: true)
    #expect(!native.isScaled(nativePixelWidth: 2160, nativePixelHeight: 3840))

    let scaled = mode(logical: (1440, 2560), pixels: (2880, 5120))
    #expect(scaled.isScaled(nativePixelWidth: 2160, nativePixelHeight: 3840))
  }

  @Test func logicalAreaIsDerivedFromLogicalDimensions() {
    let m = mode(logical: (1280, 720), pixels: (2560, 1440))
    #expect(m.logicalArea == 1280 * 720)
  }

  /// The descriptor is what persists. It must NOT carry ioModeID, which is not
  /// stable across replug.
  @Test func theDescriptorCarriesGeometryAndRefreshButNotTheModeID() {
    let m = mode(logical: (2560, 1440), pixels: (5120, 2880), hz: 120)
    let d = m.descriptor
    #expect(d.logicalWidth == 2560)
    #expect(d.pixelWidth == 5120)
    #expect(d.refreshHz == 120)
    #expect(d == DisplayModeDescriptor(logicalWidth: 2560, logicalHeight: 1440,
                                       pixelWidth: 5120, pixelHeight: 2880, refreshHz: 120))
  }

  /// `smaller`'s framebuffer is deliberately NOT proportional to its logical
  /// size (5160x2400 is 2.15:1, against a 2580x1080 logical 2.389:1). That
  /// makes the assertion load-bearing: an `aspectRatio` derived from pixel
  /// rather than logical dimensions fails here.
  @Test func aspectRatioComparesEqualForTheSameShapeAtDifferentSizes() {
    let ultrawide = mode(logical: (3440, 1440), pixels: (3440, 1440))
    let smaller = mode(logical: (2580, 1080), pixels: (5160, 2400))
    #expect(abs(ultrawide.aspectRatio - smaller.aspectRatio) < 0.0001)
  }

  /// Refresh rates arrive with float noise; normalising at the boundary is what
  /// stops it recurring downstream.
  @Test func refreshRatesAreQuantizedAtTheBoundary() {
    #expect(DisplayMode.quantizedRefresh(59.9998) == 60.0)
    #expect(DisplayMode.quantizedRefresh(60.0) == 60.0)
    #expect(DisplayMode.quantizedRefresh(119.88) == 119.9)
    // 59.94 (NTSC) must NOT collapse into 60 — these are genuinely different.
    #expect(DisplayMode.quantizedRefresh(59.94) == 59.9)
    #expect(DisplayMode.quantizedRefresh(59.9) != DisplayMode.quantizedRefresh(60.0))
  }

  /// This type exists to be Codable into UserDefaults, so the on-disk key names are
  /// pinned too: a property rename breaks a test instead of orphaning stored prefs.
  @Test func theDescriptorSurvivesAJSONRoundTripWithStableKeys() throws {
    let original = DisplayModeDescriptor(
      logicalWidth: 2560, logicalHeight: 1440,
      pixelWidth: 5120, pixelHeight: 2880, refreshHz: 119.88
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(DisplayModeDescriptor.self, from: data)
    #expect(decoded == original)

    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == [
      "logicalWidth", "logicalHeight", "pixelWidth", "pixelHeight", "refreshHz",
    ])
  }
}
