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
/// natural state between captures: no stream lifecycle to pause, resume or leak,
/// and a display that stops qualifying simply stops being asked.
///
/// The request is `LuminanceReduction.captureOversample` pixels per grid-cell
/// edge, not one.
///
/// - Privacy. ScreenCaptureKit scales out of process, so no full-resolution
///   frame exists here at any size. A 384x249 greyscale frame is 95,616
///   luminance values and reads as a legible screenshot, with window layout,
///   large text and app identity recoverable from it, where the reduced grid is
///   not. It stays transient by the shape of the call graph: the `CGImage` dies
///   with `sample(displayID:)`, the caller reduces `Sample` to its cells and
///   stores only those. A consumer that started holding a `Sample` is the thing
///   to look at.
/// - Performance. [MEASURED 2026-08-18, 20 captures per leg on this rig] Median
///   capture latency at 16x is 49.5 ms on the MAG (384x161), 49.0 ms on the
///   built-in (384x249) and 42.2 ms on the rotated Dell (216x384). A grid-scale
///   request is the control and is no faster: 52.8, 48.7 and 39.3 ms. The cost
///   is the round trip to the compositor, not the pixel count.
///
/// **Every failure returns `nil`, never a zero grid.** A zero would accumulate
/// as "this panel was black for 60 s", which silently cools the map. The
/// caller's contract is "skip this sample".
@MainActor
final class LuminanceSampler {

  /// A delivered capture, reduced to mean luminance per cell.
  ///
  /// `grid` is row-major with a top-left origin, in DISPLAY orientation; the
  /// caller maps it into panel-native space through `PanelSpaceTransform`.
  /// `cols`/`rows` are the size ScreenCaptureKit actually delivered, read off
  /// the image rather than carried over from the request.
  struct Sample: Sendable {
    let grid: [Double]
    let cols: Int
    let rows: Int
  }

  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "oledcare")

  /// Whether Screen Recording is already granted. Preflight only: this type
  /// never calls `CGRequestScreenCaptureAccess()`, because a background sampler
  /// that raises a TCC prompt on its own schedule is a permission dialog with no
  /// explanation attached. Prompting belongs to the settings pane.
  static func hasScreenRecordingPermission() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  /// Captures `displayID` once and reduces it to a mean-luminance grid.
  /// Nil on any failure: permission denied, display gone, capture error,
  /// empty result.
  func sample(displayID: CGDirectDisplayID) async -> Sample? {
    guard Self.hasScreenRecordingPermission() else { return nil }

    // Desktop windows are NOT excluded: wallpaper is emitted light and belongs
    // in the measurement. On-screen only, since an offscreen window emits nothing.
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
    // back into the measurement it derives from: band dims region, region reads
    // cooler, band lifts, region reheats. `owningApplication` is nil for some
    // system windows, which are correctly kept.
    let ourPID = ProcessInfo.processInfo.processIdentifier
    let ownWindows = content.windows.filter { $0.owningApplication?.processID == ourPID }
    let filter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)

    let config = SCStreamConfiguration()
    let (requestedWidth, requestedHeight) = LuminanceReduction.requestedSize(
      displayWidth: scDisplay.width, displayHeight: scDisplay.height)
    config.width = requestedWidth
    config.height = requestedHeight
    config.showsCursor = false
    // Pin the source colour space so the transfer function below is a stated
    // assumption rather than whatever the panel's profile happens to be. On an
    // HDR display this clamps to SDR; `captureDynamicRange` stays at its SDR
    // default, since an EDR sample needs a luminance model this grid lacks.
    config.colorSpaceName = CGColorSpace.sRGB

    let image: CGImage
    do {
      image = try await SCScreenshotManager.captureImage(
        contentFilter: filter, configuration: config)
    } catch {
      Self.log.debug("luminance sample: capture failed (\(error.localizedDescription, privacy: .public))")
      return nil
    }

    // Read back what was DELIVERED. It matches the request on every panel in
    // this setup, but nothing documents that it must, and treating a request as
    // an achieved state is this project's most repeated defect.
    let cols = image.width
    let rows = image.height
    guard cols > 0, rows > 0 else { return nil }

    guard let grid = LuminanceReduction.meanLuminance(of: image, cols: cols, rows: rows) else { return nil }
    // `image` dies with this scope. Nothing retains a CGImage past here.
    return Sample(grid: grid, cols: cols, rows: rows)
  }
}
