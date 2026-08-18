import CandelaKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

/// One-shot luminance sampling for the exposure map (OC16).
///
/// App-target island: ScreenCaptureKit is not on CandelaKit's allowed-import
/// list, so Kit only ever receives the resulting array of floats.
///
/// **One capture per call, never an `SCStream`** (OC16). Suspension is then the
/// natural state between captures — there is no stream lifecycle to pause,
/// resume or leak, and a display that stops qualifying simply stops being
/// asked. The capture is requested at grid scale, so **no full-resolution frame
/// exists in this process at any point**; that is the privacy story and the
/// performance story in one fact (S3 measured 69.6 ms avg at this size).
///
/// **Every failure returns `nil`, never a zero grid.** A zero would accumulate
/// as "this panel was black for 60 s", which is a lie that silently cools the
/// map. The caller's contract is "skip this sample".
@MainActor
final class LuminanceSampler {

  /// A delivered capture, reduced to mean luminance per cell.
  ///
  /// `grid` is row-major with a top-left origin, in **display** orientation —
  /// the caller maps it into panel-native space through `PanelSpaceTransform`.
  /// `cols`/`rows` are the size ScreenCaptureKit **actually delivered**, read
  /// off the image rather than carried over from the request.
  struct Sample: Sendable {
    let grid: [Double]
    let cols: Int
    let rows: Int
  }

  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "oledcare")

  /// Whether Screen Recording is already granted.
  ///
  /// Preflight only — **this type never calls `CGRequestScreenCaptureAccess()`**.
  /// Prompting is a user-facing decision that belongs to the settings pane; a
  /// background sampler that raises a TCC prompt on its own schedule is a
  /// permission dialog with no explanation attached to it.
  static func hasScreenRecordingPermission() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  /// Captures `displayID` once and reduces it to a mean-luminance grid.
  /// Nil on any failure: permission denied, display gone, capture error,
  /// empty result.
  func sample(displayID: CGDirectDisplayID) async -> Sample? {
    guard Self.hasScreenRecordingPermission() else { return nil }

    // Desktop windows are NOT excluded: wallpaper is emitted light and belongs
    // in the measurement. On-screen only — an offscreen window emits nothing.
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
    } catch {
      Self.log.debug("luminance sample: shareable content unavailable (\(error.localizedDescription, privacy: .public))")
      return nil
    }

    guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
      return nil
    }

    // OC16: our own overlays must not be sampled, or detection dimming feeds
    // back into the measurement it derives from — band dims region, region
    // reads cooler, band lifts, region reheats. `owningApplication` is nil for
    // some system windows, which are correctly kept.
    let ourPID = ProcessInfo.processInfo.processIdentifier
    let ownWindows = content.windows.filter { $0.owningApplication?.processID == ourPID }
    let filter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)

    let config = SCStreamConfiguration()
    let (requestedWidth, requestedHeight) = Self.requestedSize(
      displayWidth: scDisplay.width, displayHeight: scDisplay.height)
    config.width = requestedWidth
    config.height = requestedHeight
    config.showsCursor = false
    // Pin the source colour space so the transfer function below is a stated
    // assumption rather than whatever the panel's profile happens to be. On an
    // HDR display this clamps to the SDR range; `captureDynamicRange` is left
    // at its SDR default deliberately (macOS 15+ API, and an EDR sample would
    // need a luminance model this grid does not have).
    config.colorSpaceName = CGColorSpace.sRGB

    let image: CGImage
    do {
      image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
    } catch {
      Self.log.debug("luminance sample: capture failed (\(error.localizedDescription, privacy: .public))")
      return nil
    }

    // Read back what was DELIVERED. Today it matches the request on all three
    // panels (see `requestedSize`), but nothing documents that it must, and
    // treating a request as an achieved state is this project's most repeated
    // defect. `cols`/`rows` below are read off the image, never assumed.
    let cols = image.width
    let rows = image.height
    guard cols > 0, rows > 0 else { return nil }

    guard let grid = Self.meanLuminance(of: image, cols: cols, rows: rows) else { return nil }
    // `image` dies with this scope. Nothing retains a CGImage past here.
    return Sample(grid: grid, cols: cols, rows: rows)
  }

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
  /// - [MEASURED 2026-08-07] **SCK's downscale area-averages, it does not
  ///   point-sample.** A direct 24x10 capture and a 384x160 capture
  ///   box-filtered to 24x10 agreed to a mean |delta| of 0.003 to 0.016
  ///   luminance on all three panels. Oversampling buys no fidelity, so there
  ///   is nothing to trade against the extra data.
  ///
  /// The delivered size is still read back in `sample(displayID:)` rather than
  /// assumed here.
  // Internal, not private: the wallpaper source renders through the same
  // orientation rule and EOTF math, so both stay one implementation. It draws
  // through `meanLuminance`, which stretches to fill and never letterboxes, so
  // an aspect-matched request is correct on that path too.
  static func requestedSize(displayWidth: Int, displayHeight: Int) -> (Int, Int) {
    let long = max(PanelGrid.cols, PanelGrid.rows)
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

  // MARK: - Luminance

  /// sRGB EOTF, tabulated over the 256 encoded values.
  ///
  /// **Transfer function: sRGB, and it IS applied.** `config.colorSpaceName` is
  /// pinned to sRGB above, so the bytes arriving are gamma-encoded; the Rec. 709
  /// coefficients are only meaningful on linear values, and OLED pixel current
  /// tracks linear luminance rather than the encoded value. Skipping this step
  /// would overweight dark cells by roughly a factor of two at mid-grey.
  private static let linearFromSRGB: [Double] = (0..<256).map { step in
    let c = Double(step) / 255.0
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  /// Per-pixel relative luminance, row-major, top-left origin.
  ///
  /// Coefficients: **Rec. 709 / sRGB — `0.2126 R + 0.7152 G + 0.0722 B`**,
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
  static func meanLuminance(of image: CGImage, cols: Int, rows: Int) -> [Double]? {
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
