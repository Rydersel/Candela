import CoreGraphics
import Foundation

/// Capture geometry and pixel-to-luminance reduction, shared by every producer
/// of an exposure sample.
///
/// **One implementation, deliberately.** A producer that requested a different
/// shape would letterbox differently, and one that linearized differently would
/// accumulate against a subtly different measurement; either turns a comparison
/// between producers into a comparison of their implementations.
///
/// Kit-side because it is pure CoreGraphics: the ScreenCaptureKit call stays an
/// app-target island.
public enum LuminanceReduction {

  /// How many capture pixels per panel-grid cell edge.
  ///
  /// 16, from the sweep tabulated on `requestedSize`: it takes r from 0.8233 to
  /// 0.9839 against a full-resolution reference, and 32 buys only 0.005 more
  /// for four times the pixels.
  ///
  /// **The bound this places on a captured frame is the square fallback**,
  /// 384x384, not any real panel's request: the pixel count grows as the aspect
  /// moves AWAY from the grid's 2.4:1, so the MAG asks for the fewest at
  /// 384x161. No full-resolution frame exists in the process either way, so the
  /// privacy story is unchanged.
  public static let captureOversample = 16

  /// The capture is requested at the **display's own aspect**, with its long
  /// edge at `captureOversample` pixels per grid cell. `panelNativeGrid` re-bins
  /// whatever shape arrives into the fixed 24x10 storage grid.
  ///
  /// **The display's aspect rather than the grid's, because SCK letterboxes**
  /// [MEASURED 2026-08-17, macOS 26]. A request whose aspect differs from the
  /// source is scaled to fit and the remainder padded with **black**, inside a
  /// frame that still comes back at exactly the requested size. The accumulator
  /// cannot tell black padding from a dark panel, so it books as real exposure
  /// and a band of the map stays cold forever. The earlier fixed 24x10 request
  /// left six blank rows on the rotated Dell and eight blank columns on the
  /// built-in; only the MAG escaped, because 2.3889 is a hair off 2.4.
  ///
  /// **`preservesAspectRatio = false` does not help** [MEASURED 2026-08-17].
  /// `SCScreenshotManager.captureImage` letterboxes identically with the flag
  /// cleared. Do not reach for it again.
  ///
  /// **SCK delivers exactly the size requested** [MEASURED 2026-08-07,
  /// macOS 26.4], which is about the frame's dimensions and not about content
  /// filling it: the delivered size matched on every panel while the Dell's
  /// content occupied 18 of its 24 rows. Reading the delivered size back cannot
  /// catch that.
  ///
  /// **SCK's downscale does NOT area-average at an extreme ratio**
  /// [MEASURED 2026-08-18, macOS 26]. Against a structured static target, a
  /// direct 24x10 capture correlates 0.8233 with a full-resolution reference
  /// while a 384x161 capture box-filtered here reaches 0.9839. An earlier pass
  /// measured on an ordinary desktop and concluded oversampling bought nothing:
  /// flat regions hide the difference, since any sampling of a constant field
  /// returns the constant. Exposure needs an area average because every pixel of
  /// a cell emits, so the request is oversampled and
  /// `PanelSpaceTransform.panelNativeGrid` does the area-weighted reduction.
  /// The end-to-end numbers above were measured on the shipped path, 2026-08-18.
  ///
  /// Callers still read the DELIVERED size back off the image rather than
  /// assuming this one was honoured.
  ///
  /// The wallpaper source draws through `meanLuminance`, which stretches to fill
  /// and never letterboxes, so an aspect-matched request is right there too.
  public static func requestedSize(displayWidth: Int, displayHeight: Int) -> (Int, Int) {
    let long = max(PanelGrid.cols, PanelGrid.rows) * captureOversample
    // A zero-sized display reading only happens mid-reconfiguration; the square
    // fallback keeps the request valid and the next sample corrects it.
    guard displayWidth > 0, displayHeight > 0 else { return (long, long) }
    let aspect = Double(displayWidth) / Double(displayHeight)
    guard aspect.isFinite, aspect > 0 else { return (long, long) }
    // The short edge is rounded, never floored: a floor can reach 0 on an
    // extreme aspect and a zero-sized request is not capturable.
    return aspect >= 1
      ? (long, max(1, Int((Double(long) / aspect).rounded())))
      : (max(1, Int((Double(long) * aspect).rounded())), long)
  }

  /// The centre crop macOS shows when it fills a display with an image whose
  /// aspect does not match.
  ///
  /// **A capture needs no crop; a wallpaper does** [MEASURED 2026-08-18]. An
  /// SCK frame already has the display's aspect, but a wallpaper is an arbitrary
  /// image macOS scales to FILL and crops, while `meanLuminance` stretches
  /// whatever it is handed. On the Dell, showing nothing but wallpaper, a
  /// 3840x2160 wallpaper stretched into the rotated request correlated 0.186
  /// with the panel's own capture; cropped to fill first, 0.584.
  ///
  /// Returns the image unchanged when it cannot crop, so a failure here degrades
  /// to the old behaviour rather than to nothing.
  public static func cropToFill(_ image: CGImage, aspect: Double) -> CGImage {
    let width = Double(image.width)
    let height = Double(image.height)
    guard width > 0, height > 0, aspect.isFinite, aspect > 0 else { return image }
    let rect: CGRect =
      width / height > aspect
      ? CGRect(x: (width - height * aspect) / 2, y: 0, width: height * aspect, height: height)
      : CGRect(x: 0, y: (height - width / aspect) / 2, width: width, height: width / aspect)
    return image.cropping(to: rect.integral) ?? image
  }

  /// sRGB EOTF, tabulated over the 256 encoded values.
  ///
  /// **The transfer function IS applied.** Capture pins its colour space to
  /// sRGB, so the arriving bytes are gamma-encoded; the Rec. 709 coefficients
  /// are only meaningful on linear values, and OLED pixel current tracks linear
  /// luminance. Skipping it overweights dark cells about 2x at mid-grey.
  static let linearFromSRGB: [Double] = (0..<256).map { step in
    let c = Double(step) / 255.0
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  /// Per-pixel relative luminance in `0...1`, row-major, top-left origin.
  ///
  /// Coefficients: **Rec. 709 / sRGB, `0.2126 R + 0.7152 G + 0.0722 B`**,
  /// applied to linearized values (see `linearFromSRGB`).
  ///
  /// The image is redrawn into a context of known layout rather than read
  /// through `dataProvider`: an SCK `CGImage` is IOSurface-backed and its
  /// channel order, row padding and alpha handling are not contractual. The
  /// redraw is under 150k pixels.
  ///
  /// A bitmap context's first memory row is the image's TOP row even though its
  /// user space has a bottom-left origin, so no flip is needed for the
  /// top-left-origin convention `PanelSpaceTransform` expects.
  public static func meanLuminance(of image: CGImage, cols: Int, rows: Int) -> [Double]? {
    guard cols > 0, rows > 0 else { return nil }
    let bytesPerRow = cols * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * rows)
    // sRGB, not DeviceRGB: the destination encoding must be the one the
    // transfer function above names, or CoreGraphics colour-matches under us.
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

    let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let base = buffer.baseAddress,
        let context = CGContext(
          data: base, width: cols, height: rows, bitsPerComponent: 8,
          bytesPerRow: bytesPerRow, space: space,
          // noneSkipLast: straight R,G,B in memory order, no premultiplication
          // to undo.
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
      return true
    }
    guard drew else { return nil }

    var grid = [Double](repeating: 0, count: cols * rows)
    for y in 0..<rows {
      let rowStart = y * bytesPerRow
      for x in 0..<cols {
        let offset = rowStart + x * 4
        let r = linearFromSRGB[Int(pixels[offset])]
        let g = linearFromSRGB[Int(pixels[offset + 1])]
        let b = linearFromSRGB[Int(pixels[offset + 2])]
        grid[y * cols + x] = 0.2126 * r + 0.7152 * g + 0.0722 * b
      }
    }
    return grid
  }
}
