import Foundation
import Testing
@testable import CandelaKit

@Suite("Display mode model")
struct DisplayModeTests {
  private func mode(
    logical: (Int, Int), pixels: (Int, Int), hz: Double = 60,
    native: Bool = false, surfaced: Bool = true
  ) -> DisplayMode {
    DisplayMode(
      ioModeID: 1, logicalWidth: logical.0, logicalHeight: logical.1,
      pixelWidth: pixels.0, pixelHeight: pixels.1, refreshHz: hz,
      isNative: native, surfacedByMacOS: surfaced
    )
  }

  @Test func hiDPIIsAFramebufferAtLeastTwiceTheLogicalWidth() {
    #expect(mode(logical: (2560, 1440), pixels: (5120, 2880)).isHiDPI)
    #expect(!mode(logical: (2560, 1440), pixels: (2560, 1440)).isHiDPI)
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

  @Test func scaleFactorAndAreaAreDerivedFromLogicalDimensions() {
    let m = mode(logical: (1280, 720), pixels: (2560, 1440))
    #expect(m.scaleFactor == 2.0)
    #expect(m.logicalArea == 1280 * 720)
  }

  /// The descriptor is what persists. It must NOT carry ioModeID, which is not
  /// stable across replug (spec DM6).
  @Test func theDescriptorCarriesGeometryAndRefreshButNotTheModeID() {
    let m = mode(logical: (2560, 1440), pixels: (5120, 2880), hz: 120)
    let d = m.descriptor
    #expect(d.logicalWidth == 2560)
    #expect(d.pixelWidth == 5120)
    #expect(d.refreshHz == 120)
    #expect(d == DisplayModeDescriptor(logicalWidth: 2560, logicalHeight: 1440,
                                       pixelWidth: 5120, pixelHeight: 2880, refreshHz: 120))
  }

  @Test func aspectRatioComparesEqualForTheSameShapeAtDifferentSizes() {
    let ultrawide = mode(logical: (3440, 1440), pixels: (3440, 1440))
    let smaller = mode(logical: (2580, 1080), pixels: (5160, 2160))
    #expect(abs(ultrawide.aspectRatio - smaller.aspectRatio) < 0.0001)
  }
}
