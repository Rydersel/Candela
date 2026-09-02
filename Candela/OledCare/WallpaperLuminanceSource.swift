import AppKit
import CandelaKit
import CoreGraphics
import Foundation
import ImageIO
import os

/// Per-cell luminance of a display's wallpaper, for the exposure model's
/// uncovered-area backdrop.
///
/// App-target island: `NSWorkspace` and ImageIO stay out of Kit, which only ever
/// receives the reduced grid. Reading the wallpaper needs no permission at
/// all; the file is the user's own setting, not screen content.
///
/// One approximation, deliberate: a dynamic (appearance-aware) wallpaper
/// decodes to its first variant. Appearance still keys the cache, so a flip
/// recomputes and the log below records it.
@MainActor
final class WallpaperLuminanceSource {
  private static let log = Logger(subsystem: "com.rydersel.Candela", category: "oledcare")

  /// How much larger than the exact minimum the thumbnail is asked to be. The
  /// minimum alone makes the crop a boundary interpolation, not an average; see
  /// `thumbnailMaxPixels` for the measurement.
  private static let thumbnailHeadroom = 2.0

  /// Ceiling on the derived thumbnail, so a pathological wallpaper aspect cannot
  /// turn a cache miss into an unbounded decode. A 32:9 panorama on the rotated
  /// Dell already derives 2731.
  private static let thumbnailCeiling = 4096

  /// The ImageIO thumbnail's long edge, in pixels, sized so the crop drawn into
  /// the request is a downscale rather than an upscale.
  ///
  /// **The model and the measurement have to reduce comparably**, or the
  /// comparison scores the model's blur instead of its physics: every term
  /// `ModelComparison` uses (correlation, hottest-decile overlap, peak-to-mean)
  /// is structure-sensitive. The measured side asks for
  /// `LuminanceReduction.captureOversample` pixels per grid-cell edge and
  /// area-averages them down, so the model side has to reach the same request
  /// size with at least as many real pixels behind each cell.
  ///
  /// Derived rather than a constant, for two reasons. The request scales with
  /// `captureOversample`, and a literal goes stale the moment that changes: the
  /// previous value of 64 left the grid drawing a 6x UPSCALE off about 2.67
  /// thumbnail pixels per cell while the capture averaged 143x143 real ones.
  /// And `cropToFill` discards whatever does not match the display's aspect (an
  /// ultrawide wallpaper on the rotated Dell keeps 810 of its 3440 columns), so
  /// the long edge has to exceed the request by the mismatch factor. That factor
  /// comes from the file's own pixel dimensions, read without decoding.
  ///
  /// [MEASURED 2026-08-18] Pearson r of these cells against a full-resolution
  /// decode of the same file through this same path, on a 3840x2160 subject
  /// carrying structure at every scale. A smooth wallpaper cannot separate a
  /// blurred reduction from a sharp one, since any sampling of a near-constant
  /// field returns the constant:
  ///
  /// | thumbnail rule | MAG | Dell at 270 | built-in |
  /// |---|---|---|---|
  /// | 64, the previous value | 0.8667 | 0.9056 | 0.6846 |
  /// | exact minimum | 0.9954 | 0.9959 | 0.9924 |
  /// | **minimum x2, shipped** | 0.9993 | 0.9993 | 0.9993 |
  /// | minimum x4 | 0.9997 | 1.0000 | 0.9994 |
  ///
  /// The bar is the measured side's own fidelity, which
  /// `LuminanceReduction.captureOversample` records as r 0.9839 and mean |delta|
  /// 0.0137. At the exact minimum the model's error (0.0037 to 0.0070) is the
  /// same order as the measurement's, so the model is still a limiting term;
  /// doubled it is 0.0012 to 0.0022, and quadrupling gains at most 0.0007 more r
  /// for four times the pixels. A solid colour is the positive control and comes
  /// back exact at every size on every panel, so the sweep can report no
  /// difference when there is none. Decode cost separated none of the rules, and
  /// the result is cached per display.
  private static func thumbnailMaxPixels(
    sourceWidth: Int, sourceHeight: Int, cols: Int, rows: Int
  ) -> Int {
    let width = Double(sourceWidth)
    let height = Double(sourceHeight)
    let requestAspect = Double(cols) / Double(rows)
    guard width > 0, height > 0, requestAspect.isFinite, requestAspect > 0 else {
      return thumbnailCeiling
    }
    // Whichever edge cropToFill takes the crop from has to reach the request on
    // its own; the other one follows from the aspect.
    let scale =
      width / height > requestAspect ? Double(rows) / height : Double(cols) / width
    let long = (scale * max(width, height) * thumbnailHeadroom).rounded(.up)
    guard long.isFinite else { return thumbnailCeiling }
    return min(thumbnailCeiling, max(max(cols, rows), Int(long)))
  }

  /// Source pixel dimensions in the orientation the thumbnail will arrive in.
  ///
  /// `kCGImageSourceCreateThumbnailWithTransform` applies EXIF orientation, so a
  /// photo shot on its side decodes with its edges swapped relative to the file's
  /// own `PixelWidth`/`PixelHeight`. The unswapped pair would size the thumbnail
  /// for an aspect the crop never sees.
  private static func orientedSourceSize(_ source: CGImageSource) -> (Int, Int)? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return (5...8).contains(orientation) ? (height, width) : (width, height)
  }

  /// Complete over everything `computeGrid` reads, the derived thumbnail size
  /// included: that size is a function of the file's pixel dimensions (`url`)
  /// and of the request (`displaySize`). `captureOversample` also feeds the
  /// request but is a compile-time constant, so it has nothing to key on.
  private struct CacheKey: Equatable {
    var url: URL
    var appearanceIsDark: Bool
    var displaySize: CGSize
    var rotation: DisplayRotation
  }

  /// One entry per display, so a scheduled-rotation wallpaper cannot grow the
  /// cache without bound over a multi-week soak.
  private var cache: [CGDirectDisplayID: (key: CacheKey, cells: [Double])] = [:]

  /// Panel-physical wallpaper luminance for `displayID`, or nil when the
  /// display has no resolvable screen or the wallpaper cannot be read. Nil is
  /// the model's cue to fall back to the appearance prior; a zero grid
  /// would instead assert a black wallpaper that was never observed.
  func panelGrid(
    for displayID: CGDirectDisplayID, appearanceIsDark: Bool,
    through transform: PanelSpaceTransform
  ) -> [Double]? {
    guard let screen = Self.screen(for: displayID),
      let url = NSWorkspace.shared.desktopImageURL(for: screen)
    else {
      Self.reportRecompute(displayID: displayID, readable: false, appearanceIsDark: appearanceIsDark)
      cache.removeValue(forKey: displayID)
      return nil
    }

    let key = CacheKey(
      url: url, appearanceIsDark: appearanceIsDark,
      displaySize: transform.displaySize, rotation: transform.rotation)
    if let cached = cache[displayID], cached.key == key { return cached.cells }

    let cells = Self.computeGrid(url: url, through: transform)
    Self.reportRecompute(
      displayID: displayID, readable: cells != nil, appearanceIsDark: appearanceIsDark)
    if let cells {
      cache[displayID] = (key, cells)
    } else {
      cache.removeValue(forKey: displayID)
    }
    return cells
  }

  private static func computeGrid(url: URL, through transform: PanelSpaceTransform) -> [Double]? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

    // The sampler's own orientation rule and EOTF math, on purpose: the model
    // and the measurement must disagree only about content, never about how
    // pixels become luminance.
    let (cols, rows) = LuminanceReduction.requestedSize(
      displayWidth: Int(transform.displaySize.width),
      displayHeight: Int(transform.displaySize.height))
    // No readable dimensions means nothing to derive from, so ask for the
    // ceiling: too large costs milliseconds, too small silently blurs the model.
    let maxPixels =
      orientedSourceSize(source).map {
        thumbnailMaxPixels(sourceWidth: $0.0, sourceHeight: $0.1, cols: cols, rows: rows)
      } ?? thumbnailCeiling
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
      // EXIF orientation applied at decode, or a rotated photo wallpaper lands
      // in the grid sideways.
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }

    // macOS fills the display with the wallpaper and crops the overflow;
    // `meanLuminance` stretches. Without this the model reads a squashed
    // wallpaper, worst on a rotated panel where the aspects differ most.
    let filled = LuminanceReduction.cropToFill(
      image, aspect: transform.displaySize.width / transform.displaySize.height)
    guard let grid = LuminanceReduction.meanLuminance(of: filled, cols: cols, rows: rows) else {
      return nil
    }
    return transform.panelNativeGrid(fromDisplayGrid: grid, cols: cols, rows: rows)
  }

  /// Logged only on recompute, so a stable wallpaper costs one line rather than
  /// one per sample. The Screen Recording preflight goes in the line itself: the
  /// claim being proved is that these inputs stay readable with the grant
  /// absent, which a line without the grant state cannot show.
  private static func reportRecompute(
    displayID: CGDirectDisplayID, readable: Bool, appearanceIsDark: Bool
  ) {
    log.info("""
    exposure model: wallpaper \(readable ? "readable" : "unreadable", privacy: .public) \
    for display \(displayID, privacy: .public) \
    appearanceDark=\(appearanceIsDark, privacy: .public) \
    screenRecordingPreflight=\(CGPreflightScreenCaptureAccess(), privacy: .public)
    """)
  }

  private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { screen in
      let key = NSDeviceDescriptionKey("NSScreenNumber")
      return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
    }
  }
}
