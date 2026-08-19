import CoreGraphics
import Foundation

/// Capture geometry and pixel-to-luminance reduction, shared by every producer
/// of an exposure sample.
///
/// **One implementation, deliberately.** The app's ScreenCaptureKit island, the
/// wallpaper source and the offline capture tool all reduce pixels through this
/// type. A producer that requested a different shape would letterbox
/// differently, and one that linearized differently would fit or accumulate
/// against a subtly different measurement; either turns a comparison between
/// them into a comparison of their implementations.
///
/// Kit-side rather than app-side because it is pure CoreGraphics with no capture
/// in it: the ScreenCaptureKit call stays an app-target island.
public enum LuminanceReduction {

  /// The capture is requested at the **display's own aspect**, with its long
  /// edge at `PanelGrid` resolution. `panelNativeGrid` then re-bins whatever
  /// shape arrives into the fixed 24x10 storage grid, so the request never has
  /// to match the storage shape.
  ///
  /// **This asks for the display's aspect rather than the grid's because SCK
  /// letterboxes.** [MEASURED 2026-08-17, macOS 26] A capture whose requested
  /// frame aspect differs from the source is scaled to fit and the remainder is
  /// padded with **black**, inside a frame that still comes back at exactly the
  /// requested size. Black is a luminance the accumulator cannot tell from a
  /// dark panel, so the padding books as real exposure and a band of the map
  /// stays cold forever.
  ///
  /// The earlier rule here gave the long edge `PanelGrid.cols` and the short
  /// edge `PanelGrid.rows` regardless of the panel, which measured as:
  ///
  /// | panel | aspect | requested | dead band |
  /// |---|---|---|---|
  /// | Dell 1440x2560 at 270 deg | 0.5625 | 10x24 (0.4167) | 6 blank rows |
  /// | built-in 1800x1169 | 1.5398 | 24x10 (2.4000) | 8 blank columns |
  /// | MAG 3440x1440 | 2.3889 | 24x10 (2.4000) | none |
  ///
  /// Only the MAG escaped, and only because 2.3889 is a hair off 2.4. On the
  /// Dell the blank rows are display rows; at 270 deg `panelPoint` turns them
  /// into blank *panel columns*, which is why a rotation-shaped defect had a
  /// capture-shaped cause.
  ///
  /// **`preservesAspectRatio = false` does not help.** [MEASURED 2026-08-17]
  /// `SCScreenshotManager.captureImage` letterboxes identically with the flag
  /// cleared; the same Dell request came back with the same six blank rows.
  /// Do not reach for it again.
  ///
  /// Still true from the earlier pass, and still not a contract:
  ///
  /// - [MEASURED 2026-08-07, macOS 26.4] **SCK delivers exactly the size
  ///   requested.** That is about the frame's dimensions, not about the content
  ///   filling it: the delivered size matched on every panel while the Dell's
  ///   content occupied 18 of its 24 rows. Reading back the delivered size was
  ///   never going to catch this, so nothing here should be read as evidence
  ///   that the frame is fully covered.
  /// - **SCK's downscale does NOT area-average at an extreme ratio, and the
  ///   note that used to stand here was wrong** [MEASURED 2026-08-18, macOS 26].
  ///   The earlier pass compared a direct 24x10 capture against a 384x160
  ///   capture box-filtered to 24x10, found a mean |delta| of 0.003 to 0.016,
  ///   and concluded oversampling bought nothing. Repeated on a deliberately
  ///   structured, STATIC target (a 40 px stripe on a 143 px cell pitch, placed
  ///   mid-cell so a box filter must report a partial value and a point sample
  ///   can only report all or nothing), the same comparison against a
  ///   full-resolution grab gives:
  ///
  ///   | request | r | mean \|d\| | max \|d\| |
  ///   |---|---|---|---|
  ///   | 24x10 | 0.8233 | 0.0467 | 0.2837 |
  ///   | 96x40 | 0.9574 | 0.0241 | 0.1241 |
  ///   | 384x161 | 0.9839 | 0.0137 | 0.0757 |
  ///   | 768x321 | 0.9891 | 0.0110 | 0.0598 |
  ///
  ///   The old measurement was taken on an ordinary desktop, where large flat
  ///   regions hide the difference: any sampling of a constant field returns
  ///   the constant, so only structure exposes it. Two independent checks
  ///   confirm the fault is the downscale and not the capture API: a 24x10 SCK
  ///   capture disagrees with a 1920x804 SCK capture box-filtered (r = 0.8858),
  ///   which is SCK against itself, while a large SCK capture and a
  ///   `screencapture` grab, both box-filtered, agree at r = 0.9993.
  ///
  ///   Exposure needs an area average, because every pixel of a cell emits. So
  ///   the request is oversampled and the area-weighted reduction to the panel
  ///   grid is done by `PanelSpaceTransform.panelNativeGrid`, which callers
  ///   already run.
  ///
  /// Callers still read the DELIVERED size back off the image rather than
  /// assuming this one was honoured.
  ///
  /// The wallpaper source renders through this same rule, and correctly: it
  /// draws through `meanLuminance`, which stretches to fill and never
  /// letterboxes, so an aspect-matched request is right on that path too.
  /// How many capture pixels per panel-grid cell edge.
  ///
  /// 16 from the table above: it takes r from 0.8233 to 0.9839 against a
  /// full-resolution reference, and 32 buys only 0.005 more for four times the
  /// pixels. At this factor the largest panel here requests 384x161, about 62k
  /// pixels, so no full-resolution frame exists in the process and the privacy
  /// story is unchanged.
  public static let captureOversample = 16

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
  /// **A capture needs no crop; a wallpaper does** [MEASURED 2026-08-18]. A
  /// ScreenCaptureKit frame already has the display's aspect, so drawing it
  /// into a grid of that aspect is the identity. A wallpaper is an arbitrary
  /// image that macOS scales to FILL and crops the overflow of, while
  /// `meanLuminance` stretches whatever it is handed. On the Dell, a 3840x2160
  /// wallpaper stretched into the rotated 14x24 request correlated 0.186 with
  /// the panel's own capture; cropped to fill first, 0.584. The panel was
  /// showing nothing but wallpaper at the time, so that capture IS the
  /// wallpaper and the comparison is direct.
  ///
  /// Returns the image unchanged when it cannot crop, which keeps a failure
  /// here degrading to the old behaviour rather than to nothing.
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
  /// **Transfer function: sRGB, and it IS applied.** Capture pins its colour
  /// space to sRGB, so the bytes arriving are gamma-encoded; the Rec. 709
  /// coefficients are only meaningful on linear values, and OLED pixel current
  /// tracks linear luminance rather than the encoded value. Skipping this step
  /// would overweight dark cells by roughly a factor of two at mid-grey.
  static let linearFromSRGB: [Double] = (0..<256).map { step in
    let c = Double(step) / 255.0
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  /// Per-pixel relative luminance, row-major, top-left origin.
  ///
  /// Coefficients: **Rec. 709 / sRGB, `0.2126 R + 0.7152 G + 0.0722 B`**,
  /// applied to linearized values (see `linearFromSRGB`). Result is `0...1`.
  ///
  /// The image is redrawn into a context of known layout rather than read
  /// through `dataProvider`: a ScreenCaptureKit `CGImage` is IOSurface-backed
  /// and its channel order, row padding and alpha handling are not contractual.
  /// At this size the redraw is a few thousand pixels.
  ///
  /// A bitmap context's first memory row is the image's TOP row even though its
  /// user space has a bottom-left origin, so no flip is needed to land in the
  /// top-left-origin convention `PanelSpaceTransform` expects.
  public static func meanLuminance(of image: CGImage, cols: Int, rows: Int) -> [Double]? {
    guard cols > 0, rows > 0 else { return nil }
    let bytesPerRow = cols * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * rows)
    // sRGB, not DeviceRGB: the destination encoding has to be the one the
    // transfer function above names, or CoreGraphics colour-matches underneath
    // us and the comment stops being true.
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
