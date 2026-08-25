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
/// natural state between captures: there is no stream lifecycle to pause,
/// resume or leak, and a display that stops qualifying simply stops being
/// asked.
///
/// **The request is `LuminanceReduction.captureOversample` pixels per grid-cell
/// edge, not one.** It was grid scale until the oversample landed, and the
/// sentence that stood here read the privacy story and the performance story
/// off that one fact. Both still hold, for reasons that are no longer that one.
///
/// - Privacy. ScreenCaptureKit scales out of process, so no full-resolution
///   frame exists here at either size. What changed is what the small frame is:
///   384x249 on the built-in is 95,616 luminance values, and a greyscale image
///   that size is a legible screenshot, with window layout, large text and app
///   identity recoverable from it, where a 24x10 grid is not. It stays
///   transient, and that is a property of the call graph rather than of the
///   frame: the `CGImage` dies with `sample(displayID:)`, the caller reduces
///   `Sample` to 240 cells and stores only those, and nothing retains or logs
///   the delivered grid. A consumer that started holding a `Sample` is the
///   thing to look at.
/// - Performance. Unchanged, and measured rather than carried over. [MEASURED
///   2026-08-18, 20 captures per leg on this rig] Median capture latency at 16x
///   is 49.5 ms on the MAG (384x161), 49.0 ms on the built-in (384x249) and
///   42.2 ms on the rotated Dell (216x384). The OLD grid-scale request is the
///   control and is no faster: 52.8, 48.7 and 39.3 ms. The cost is the round
///   trip to the compositor, not the pixel count. Reduction goes from 0.06 to
///   0.13 ms up to 0.29 to 0.44 ms, still nothing. The 69.6 ms average this
///   comment used to cite is dropped rather than moved: S3 measured it at the
///   grid-scale request, so it never described this size.
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
    let (requestedWidth, requestedHeight) = LuminanceReduction.requestedSize(
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
    // panels (see `LuminanceReduction.requestedSize`), but nothing documents
    // that it must, and
    // treating a request as an achieved state is this project's most repeated
    // defect. `cols`/`rows` below are read off the image, never assumed.
    let cols = image.width
    let rows = image.height
    guard cols > 0, rows > 0 else { return nil }

    guard let grid = LuminanceReduction.meanLuminance(of: image, cols: cols, rows: rows) else { return nil }
    // `image` dies with this scope. Nothing retains a CGImage past here.
    return Sample(grid: grid, cols: cols, rows: rows)
  }
}
